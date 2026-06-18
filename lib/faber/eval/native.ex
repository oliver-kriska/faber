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

  @doc "Score `content` (a SKILL.md string). Returns `%{\"composite\" => f, \"dimensions\" => %{}}`."
  @spec score(String.t(), term()) :: map()
  def score(content, _eval_def \\ nil) do
    {dimensions, num, den} =
      Enum.reduce(@default_eval, {%{}, 0.0, 0.0}, fn {name, weight, checks}, {acc, num, den} ->
        dim = score_dimension(name, checks, content)
        {Map.put(acc, name, dim), num + weight * dim["score"], den + weight}
      end)

    composite = if den > 0, do: num / den, else: 0.0
    %{"composite" => Float.round(composite, 4), "dimensions" => dimensions}
  end

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
