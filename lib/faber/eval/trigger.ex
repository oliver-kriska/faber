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
  """

  alias Faber.{LLM, Proposal}

  @schema [triggers: [type: :boolean, required: true]]

  @type result ::
          %{
            accuracy: float(),
            precision: float(),
            recall: float(),
            correct: non_neg_integer(),
            total: pos_integer(),
            tp: non_neg_integer(),
            fp: non_neg_integer(),
            fn: non_neg_integer(),
            tn: non_neg_integer(),
            cases: [map()]
          }
          | {:skipped, :no_fixtures}

  @doc """
  Score routing accuracy for `proposal`. Returns an accuracy map, or `{:skipped, :no_fixtures}`
  when the proposal carries no trigger fixtures. `opts` are forwarded to `Faber.LLM`
  (e.g. `:llm` to override the backend, `:model`).
  """
  @spec score(Proposal.t(), keyword()) :: result()
  def score(%Proposal{} = p, opts \\ []) do
    cases =
      Enum.map(p.should_trigger || [], &{&1, true}) ++
        Enum.map(p.should_not_trigger || [], &{&1, false})

    case cases do
      [] -> {:skipped, :no_fixtures}
      _ -> evaluate(p, cases, opts)
    end
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
