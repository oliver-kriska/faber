defmodule Faber.Eval.Native do
  @moduledoc """
  Native Elixir structural scorer — composes `Faber.Eval.Matchers` into weighted dimensions and a
  composite, mirroring `python/faber_eval/scorer.py`'s `DEFAULT_EVAL` and formulas:

    * `dimension.score = Σ(weight | passed) / Σ(weight)`
    * `composite      = Σ(dim.weight · dim.score) / Σ(dim.weight)`

  Returns the same string-keyed result shape as the Python sidecar, so `Faber.Eval` is
  engine-agnostic. This is the default eval path (no `python3` spawn).
  """

  alias Faber.Eval.Matchers

  # Version of the score *result contract* (dimensions/assertions shape), decoupled from the app
  # release version. Bump only when the result shape changes; the sidecar carries the same constant
  # (`python/faber_eval/scorer.py SCHEMA_VERSION`) and the parity test asserts they match.
  @schema_version "1.0"

  @doc "The score-result contract version (see `@schema_version`)."
  @spec schema_version() :: String.t()
  def schema_version, do: @schema_version

  @default_eval [
    {"completeness", 0.25,
     [
       {"frontmatter_field", %{field: "name"}},
       {"frontmatter_field", %{field: "description"}},
       {"has_iron_laws", %{min_count: 3}},
       {"section_exists", %{section: "Usage"}},
       {"section_exists", %{section: "References"}}
     ]},
    {"conciseness", 0.15,
     [
       {"line_count", %{target: 100, tolerance: 85}},
       {"max_section_lines", %{max: 40}},
       {"token_estimate", %{max_tokens: 2000}}
     ]},
    {"triggering", 0.20,
     [
       {"description_length", %{min: 50, max: 250}},
       {"description_no_vague", %{}},
       {"description_structure", %{}}
     ]},
    {"safety", 0.15,
     [
       {"has_iron_laws", %{min_count: 1}},
       {"no_dangerous_patterns", %{}}
     ]},
    {"clarity", 0.10,
     [
       {"action_density", %{min_ratio: 0.25}},
       {"has_examples", %{min_blocks: 1}}
     ]},
    {"specificity", 0.15,
     [
       {"specificity_ratio", %{min_ratio: 0.15}}
     ]}
  ]

  # The full 8-dimension eval — the plugin's `lab/eval` shape. Adds `accuracy` (cross-reference
  # resolution) as a 7th structural dimension; `behavioral` (trigger accuracy) is the 8th but is
  # folded in by `Faber.Eval` at the eval layer (it needs an LLM, not the pure structural scorer).
  # Weights mirror the reference's defaults. `accuracy` neutral-passes unless ref known-sets are
  # threaded in (via `Faber.Eval`'s `:refs` option or a vendored adapter), so it never inflates the
  # gate for a proposal scored without filesystem context.
  @full_eval [
    {"completeness", 0.20,
     [
       {"frontmatter_field", %{field: "name"}},
       {"frontmatter_field", %{field: "description"}},
       {"has_iron_laws", %{min_count: 3}},
       {"section_exists", %{section: "Usage"}},
       {"section_exists", %{section: "References"}}
     ]},
    {"accuracy", 0.15,
     [
       {"valid_file_refs", %{}},
       {"valid_skill_refs", %{}},
       {"valid_agent_refs", %{}}
     ]},
    {"conciseness", 0.15,
     [
       {"line_count", %{target: 100, tolerance: 85}},
       {"max_section_lines", %{max: 40}},
       {"token_estimate", %{max_tokens: 2000}}
     ]},
    {"triggering", 0.15,
     [
       {"description_length", %{min: 50, max: 250}},
       {"description_no_vague", %{}},
       {"description_structure", %{}}
     ]},
    {"safety", 0.10,
     [
       {"has_iron_laws", %{min_count: 1}},
       {"no_dangerous_patterns", %{}}
     ]},
    {"clarity", 0.10,
     [
       {"action_density", %{min_ratio: 0.25}},
       {"has_examples", %{min_blocks: 1}}
     ]},
    {"specificity", 0.10,
     [
       {"specificity_ratio", %{min_ratio: 0.15}}
     ]}
  ]

  # The hook eval set — a third eval_def beside `@default_eval`/`@full_eval`, selected by
  # `kind: :hook` (`Faber.Eval`).
  #
  # It shares exactly ONE check with the skill sets: `no_dangerous_patterns`, the safety veto. That
  # is the point — a hook is the artifact most able to do harm (it runs automatically, on every
  # matching tool call, without the user in the loop), so the veto matters most here. It is the same
  # check type, which is what keeps `Faber.Eval`'s `@veto_checks` wiring automatic rather than
  # something a new artifact kind has to remember to opt into.
  #
  # It reuses NO skill matcher. `specificity_ratio`, `action_density`, `has_iron_laws`,
  # `section_exists` and the `description_*` family all read prose and frontmatter; a shell script
  # has neither, so they don't measure a hook badly — they don't measure it at all, scoring a
  # perfectly good hook ~0.15–0.30 against the same 0.75 gate. The threshold is NOT lowered to
  # compensate: the questions are replaced with ones a hook can answer.
  #
  # `exempt_safe_sections: false` is the one parameter difference on the shared veto, and it is a
  # correctness fix rather than a preference: the exemption lets a "## Anti-patterns" section carry
  # `rm -rf /` because a skill documenting a danger is doing its job. `##` is also an ordinary shell
  # comment, so on a script that exemption is a hole — reproduced as a clean `{true, "no dangerous
  # patterns"}` on a script that would delete the disk.
  # ## Why three dimensions and a 0.90 threshold
  #
  # A hook's criteria are **necessary conditions**, not qualities to average: a hook that can't run,
  # can't see its input, or points nowhere isn't a mediocre hook, it's not a hook. A skill degrades
  # (thin Iron Laws, vague description); a hook mostly doesn't.
  #
  # That collides with a weighted average, and the arithmetic is not negotiable: a dimension of
  # weight `w` failing scores `1 - w`, so it only fails a gate of `t` when `w > 1 - t`. At the
  # skill gate's `t = 0.75` every dimension would need `w > 0.25` — impossible for four dimensions
  # summing to 1.0. Four dimensions at the default threshold cannot all be necessary; the fourth is
  # decorative by construction. This is the same shape as `@veto_checks`' finding (a `rm -rf /` skill
  # landing on exactly 0.75 and passing), met a second time.
  #
  # So: three dimensions, each weighted > 0.10 above the fail line, and the threshold RAISED to 0.90
  # (`Faber.Eval`'s `@hook_threshold`). Raising is the honest direction — the plan forbids *lowering*
  # the bar to let hooks through, and this does the reverse: every dimension is individually fatal,
  # and even a half-failed `executable` (0.85) does not pass. A hook runs automatically, on every
  # matching tool call, with the user not in the loop; it should be held higher than prose, not lower.
  @hook_eval [
    {"executable", 0.30,
     [
       {"hook_shebang", %{}},
       {"hook_reads_stdin", %{}}
     ]},
    {"pointer", 0.30,
     [
       {"hook_pointer", %{}}
     ]},
    {"safety", 0.40,
     [
       {"no_dangerous_patterns", %{exempt_safe_sections: false}}
     ]}
  ]

  @doc "The built-in eval definition (used when no adapter/custom definition is supplied)."
  @spec default_eval() :: [{String.t(), float(), [{String.t(), map()}]}]
  def default_eval, do: @default_eval

  @doc """
  The hook eval definition — `executable` · `pointer` · `safety`, selected for `kind: :hook`.
  See `@hook_eval` for why it reuses the safety veto and nothing else.
  """
  @spec hook_eval() :: [{String.t(), float(), [{String.t(), map()}]}]
  def hook_eval, do: @hook_eval

  @doc "The full 8-dimension eval shape (`accuracy` structural + `behavioral` folded by Faber.Eval)."
  @spec full_eval() :: [{String.t(), float(), [{String.t(), map()}]}]
  def full_eval, do: @full_eval

  @doc """
  Score `content` (a SKILL.md string) against an eval definition.

  `eval_def` is the internal `[{dimension, weight, [{check_type, params}]}]` form (e.g. from
  `Faber.Eval` after translating a vendored adapter's `eval.yaml`). `nil` → `default_eval/0`.
  Returns `%{"composite" => f, "dimensions" => %{}}`.
  """
  @spec score(String.t(), term()) :: map()
  def score(content, eval_def \\ nil) do
    {dimensions, num, den} =
      eval_def
      |> normalize_def()
      |> Enum.reduce({%{}, 0.0, 0.0}, fn {name, weight, checks}, {acc, num, den} ->
        dim = score_dimension(name, checks, content)
        {Map.put(acc, name, dim), num + weight * dim["score"], den + weight}
      end)

    composite = if den > 0, do: num / den, else: 0.0

    %{
      "schema_version" => @schema_version,
      "composite" => Float.round(composite, 4),
      "dimensions" => dimensions,
      "weight_total" => Float.round(den, 4)
    }
  end

  defp normalize_def(nil), do: @default_eval
  defp normalize_def([]), do: @default_eval
  defp normalize_def(def) when is_list(def), do: def

  defp score_dimension(name, checks, content) do
    {assertions, passed_w, total_w, passed, failed} =
      checks
      |> Enum.with_index()
      |> Enum.reduce({[], 0.0, 0.0, 0, 0}, fn {{type, params}, i}, {a, pw, tw, p, f} ->
        {ok, evidence} = Matchers.run_check(type, content, params)
        weight = Map.get(params, :weight, 1.0)

        assertion = %{
          "id" => "#{name}-#{i}",
          "check_type" => type,
          "passed" => ok,
          "evidence" => evidence
        }

        if ok,
          do: {[assertion | a], pw + weight, tw + weight, p + 1, f},
          else: {[assertion | a], pw, tw + weight, p, f + 1}
      end)

    score = if total_w > 0, do: passed_w / total_w, else: 1.0

    %{
      "dimension" => name,
      "score" => Float.round(score, 4),
      "passed" => passed,
      "failed" => failed,
      "total" => passed + failed,
      "assertions" => Enum.reverse(assertions)
    }
  end
end
