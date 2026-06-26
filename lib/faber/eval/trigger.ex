defmodule Faber.Eval.Trigger do
  @moduledoc """
  **Behavioral trigger-accuracy eval.** The structural matchers judge whether a skill is
  *well-formed*; this judges whether it *routes correctly* — does its `description` actually fire
  for the requests it should and stay quiet for the ones it shouldn't?

  For each `should_trigger` / `should_not_trigger` phrasing on the proposal, an LLM is asked
  whether the skill activates; accuracy is `correct / total`. The LLM goes through the
  `Faber.LLM` behaviour, so the default backend is the **keyless** `Faber.LLM.ClaudeCLI`
  (`claude -p`, no API key) and tests inject a deterministic stub.

  This is the Faber port of the plugin's `lab/eval/trigger_scorer.py`. It is **not** on the hot
  loop path — it costs one LLM call per fixture — so `Faber.Eval` only runs it when explicitly
  asked (`trigger: true`).

  ## Stochasticity & N-sample averaging

  A single routing call is one Bernoulli draw from a noisy classifier — the *same* skill can score
  0.75 one run and 1.0 the next (observed in dogfooding). One sample is a bad estimate of a noisy
  objective, and a greedy optimizer (`Faber.Loop`) will happily "keep" a candidate that merely got a
  lucky draw. Pass `trigger_samples: N` (default `1`) to repeat the whole eval N times and
  **pool** the results (micro-average): `accuracy = total_correct / total_fixtures` over `N ×
  fixtures`, with `precision`/`recall` from pooled confusion counts. This yields a stable estimate
  and an `accuracy_stdev` that quantifies the noise. `samples: 1` is byte-for-byte the original
  single-pass behavior (no extra keys), so nothing changes unless you opt in (at N× the LLM cost).
  """

  alias Faber.{LLM, Proposal}

  @schema [triggers: [type: :boolean, required: true]]

  @type result ::
          %{
            required(:accuracy) => float(),
            required(:precision) => float(),
            required(:recall) => float(),
            required(:correct) => non_neg_integer(),
            required(:total) => pos_integer(),
            required(:tp) => non_neg_integer(),
            required(:fp) => non_neg_integer(),
            required(:fn) => non_neg_integer(),
            required(:tn) => non_neg_integer(),
            required(:cases) => [map()],
            optional(:samples) => pos_integer(),
            optional(:accuracy_stdev) => float()
          }
          | {:skipped, :no_fixtures}

  @doc """
  Score routing accuracy for `proposal`. Returns an accuracy map, or `{:skipped, :no_fixtures}`
  when the proposal carries no trigger fixtures. `opts` are forwarded to `Faber.LLM`
  (e.g. `:llm` to override the backend, `:model`).

  `opts[:trigger_samples]` (default `1`) repeats the eval N times and pools the results into a stable
  estimate (adds `:samples` + `:accuracy_stdev`); `1` keeps the original single-pass shape.
  """
  @spec score(Proposal.t(), keyword()) :: result()
  def score(%Proposal{} = p, opts \\ []) do
    cases =
      Enum.map(p.should_trigger || [], &{&1, true}) ++
        Enum.map(p.should_not_trigger || [], &{&1, false})

    samples = max(opts[:trigger_samples] || 1, 1)

    case {cases, samples} do
      {[], _} -> {:skipped, :no_fixtures}
      {_, 1} -> evaluate(p, cases, opts)
      {_, n} -> evaluate_samples(p, cases, opts, n)
    end
  end

  # Repeat the eval N times and pool (micro-average) the confusion counts, so `correct / total` stays
  # exactly consistent with `accuracy` and precision/recall are computed over all N × fixtures.
  defp evaluate_samples(p, cases, opts, samples) do
    runs = for _ <- 1..samples, do: evaluate(p, cases, opts)

    correct = runs |> Enum.map(& &1.correct) |> Enum.sum()
    total = runs |> Enum.map(& &1.total) |> Enum.sum()
    tp = runs |> Enum.map(& &1.tp) |> Enum.sum()
    fp = runs |> Enum.map(& &1.fp) |> Enum.sum()
    fn_ = runs |> Enum.map(& &1.fn) |> Enum.sum()
    tn = runs |> Enum.map(& &1.tn) |> Enum.sum()

    %{
      accuracy: correct / total,
      precision: ratio(tp, tp + fp),
      recall: ratio(tp, tp + fn_),
      correct: correct,
      total: total,
      tp: tp,
      fp: fp,
      fn: fn_,
      tn: tn,
      samples: samples,
      accuracy_stdev: stdev(Enum.map(runs, & &1.accuracy)),
      # The per-run fixture-level detail of the first run, as a representative sample.
      cases: hd(runs).cases
    }
  end

  defp stdev(values) do
    n = length(values)
    mean = Enum.sum(values) / n
    variance = Enum.sum(Enum.map(values, fn x -> (x - mean) * (x - mean) end)) / n
    Float.round(:math.sqrt(variance), 4)
  end

  defp evaluate(p, cases, opts) do
    results =
      Enum.map(cases, fn {phrase, expected} ->
        actual = ask(p, phrase, opts)
        %{phrase: phrase, expected: expected, actual: actual, correct: actual == expected}
      end)

    correct = Enum.count(results, & &1.correct)
    total = length(results)

    # A backend error (`actual == :error`) is neither a true nor false positive — it just counts as
    # an incorrect prediction in `accuracy`, and is excluded from precision/recall (which key off
    # boolean `true` predictions only).
    tp = Enum.count(results, &(&1.expected == true and &1.actual == true))
    fp = Enum.count(results, &(&1.expected == false and &1.actual == true))
    fn_ = Enum.count(results, &(&1.expected == true and &1.actual != true))
    tn = Enum.count(results, &(&1.expected == false and &1.actual != true))

    %{
      accuracy: correct / total,
      precision: ratio(tp, tp + fp),
      recall: ratio(tp, tp + fn_),
      correct: correct,
      total: total,
      tp: tp,
      fp: fp,
      fn: fn_,
      tn: tn,
      cases: results
    }
  end

  # No positive predictions / no positive truths → vacuously perfect (matches the reference's 1.0
  # default when the denominator is empty).
  defp ratio(_num, 0), do: 1.0
  defp ratio(num, den), do: num / den

  defp ask(%Proposal{} = p, phrase, opts) do
    prompt = """
    A coding agent has this skill available:

    name: #{p.name}
    description: #{p.description}

    A developer's request: "#{phrase}"

    Should this skill activate for that request? Decide only from the description.
    Return triggers: true if it should activate, triggers: false otherwise.
    """

    case LLM.generate_object(prompt, @schema, opts) do
      {:ok, object} -> truthy(object)
      # A backend error counts as a routing miss rather than crashing the whole eval.
      {:error, _} -> :error
    end
  end

  defp truthy(object) do
    case Map.get(object, :triggers, Map.get(object, "triggers")) do
      true -> true
      _ -> false
    end
  end
end
