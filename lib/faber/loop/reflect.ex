defmodule Faber.Loop.Reflect do
  @moduledoc """
  The `:reflect` strategy's **credit-assignment + prompt-shaping** step: turn the current best's
  eval — its weakest dimension and failed checks — into a targeted-edit instruction for
  `Faber.Propose` (the `:feedback` opt). Eval dimensions are the "named factors"
  (KB: bounded-factor-level-prompt-optimization).

  Extracted from `Faber.Loop` so the prompt fragment lives beside the reflection logic that
  owns it, matching the codebase convention that every prompt sits next to the LLM call it
  feeds (`Faber.Propose`, `Faber.Consolidate`) — the loop engine keeps only the keep/reject
  mechanics and pipeline wiring.
  """

  alias Faber.Eval

  @doc """
  Derive `{weakest_dimension_name, feedback_prompt}` for the current best draft.

  `best_eval` is the cached eval `Faber.Loop` stores on a keep (`%{composite:, dimensions:}`) —
  the best only changes on a keep, so no re-scoring is needed (re-scoring it every iteration
  roughly doubled the loop's LLM routing spend in trigger mode). Intentional consequence: the
  fixed best is not RE-SAMPLED per iteration — candidates still score fresh and pooled
  (`trigger_samples`), which is where the anti-noise sampling belongs. When `best_eval` is `nil`
  (a custom `eval_fn` that returns no meta), `subject` is scored live via `Eval.score/2` as a
  fallback; `content` is the draft embedded in the prompt.
  """
  @spec feedback(map() | nil, Faber.Proposal.t() | String.t(), String.t(), keyword()) ::
          {String.t(), String.t()}
  def feedback(%{} = best_eval, _subject, content, _eval_opts) do
    derive(best_eval, content)
  end

  def feedback(nil, subject, content, eval_opts) do
    case Eval.score(subject, eval_opts) do
      {:ok, %{dimensions: dims, composite: comp}} ->
        derive(%{composite: comp, dimensions: dims}, content)

      _ ->
        derive(%{composite: nil, dimensions: %{}}, content)
    end
  end

  defp derive(%{dimensions: dims, composite: comp}, content) when map_size(dims) > 0 do
    {name, dim} = Enum.min_by(dims, fn {_n, d} -> d["score"] end)
    failed = for a <- dim["assertions"] || [], a["passed"] == false, do: a["evidence"]
    {name, feedback_string(content, comp, name, dim["score"], failed)}
  end

  defp derive(%{composite: comp}, content) do
    {"overall", feedback_string(content, comp, "overall", nil, [])}
  end

  defp feedback_string(content, composite, target, score, failed) do
    weaknesses =
      case failed do
        [] -> "  - (no specific failing checks — tighten this dimension without weakening others)"
        list -> Enum.map_join(list, "\n", &"  - #{&1}")
      end

    """
    REVISION TASK — improve the EXISTING skill below; do not start over.
    Current composite score: #{fmt_score(composite)}. Weakest dimension: "#{target}" (#{fmt_score(score)}).
    Fix ONLY these weaknesses while keeping every existing strength intact:
    #{weaknesses}

    Return the full improved skill as the structured object. Preserve the skill's intent, name, and
    any parts that already work; change only what addresses the weaknesses above.

    --- CURRENT SKILL.md ---
    #{content}
    """
  end

  defp fmt_score(nil), do: "n/a"
  defp fmt_score(n) when is_number(n), do: :erlang.float_to_binary(n * 1.0, decimals: 3)
end
