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
          %{accuracy: float(), correct: non_neg_integer(), total: pos_integer(), cases: [map()]}
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
    %{accuracy: correct / total, correct: correct, total: total, cases: results}
  end

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
