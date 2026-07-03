defmodule Faber.Eval.NativeTest do
  use ExUnit.Case, async: true

  alias Faber.Eval.{Matchers, Native}

  @good """
  ---
  name: investigate-retry-loops
  description: "Investigate failing shell commands systematically — read the error, hypothesize, change one thing. Use when the same command is retried after an error. NOT for first failures."
  effort: low
  ---

  # Investigate Retry Loops

  Stop blind retries: read the actual error (`mix test` output), form one hypothesis, change one
  variable, then re-run.

  ## Usage

  Load when a command like `mix test` or `git push` is re-run after an errored result.

  ## Iron Laws — Never Violate These

  1. Read the actual error output before retrying — never re-run blind.
  2. Change exactly one variable per attempt so the result is attributable.
  3. After 3 failed attempts, stop and escalate with what was tried.

  ## Detection

  | Signal | Meaning |
  | --- | --- |
  | same `cmd` 3+ times | retry loop with `is_error` results |
  | no edit between runs | nothing changed; the re-run is blind |

  ## Examples

  ```bash
  # re-run only what broke, after reading the error
  mix test --failed
  ```

  ## References

  - `${CLAUDE_SKILL_DIR}/references/investigate-retry-loops.md` — supporting detail
  """

  @bad """
  ---
  name: stuff
  ---

  # Stuff

  This skill does various general things and might possibly help sometimes etc.

  ## Notes

  Some prose with no structure and no examples and no laws.
  """

  describe "matchers" do
    test "frontmatter splits and fields resolve" do
      {fm, body} = Matchers.split_frontmatter(@good)
      assert fm["name"] == "investigate-retry-loops"
      assert String.starts_with?(body, "# Investigate")
    end

    test "has_iron_laws counts numbered items" do
      assert {true, _} = Matchers.has_iron_laws(@good, %{min_count: 3})
      assert {false, _} = Matchers.has_iron_laws(@bad, %{min_count: 1})
    end

    test "description_structure needs what + when" do
      assert {true, _} = Matchers.description_structure(@good, %{})
      assert {false, _} = Matchers.description_structure(@bad, %{})
    end

    test "no_dangerous_patterns ignores documented warnings but flags live commands" do
      documented =
        "---\nname: x\ndescription: y\n---\n\n## Iron Laws\n\n1. Never run rm -rf / here.\n"

      assert {true, _} = Matchers.no_dangerous_patterns(documented, %{})
      live = "---\nname: x\ndescription: y\n---\n\n## Steps\n\nrun rm -rf / now\n"
      assert {false, _} = Matchers.no_dangerous_patterns(live, %{})
    end

    test "description_keywords neutral-passes without a list, counts case-insensitive hits" do
      skill = "---\nname: x\ndescription: GenServer worker with Phoenix PubSub\n---\n# X\n"

      assert {true, "no keyword list configured (skipped)"} =
               Matchers.description_keywords(skill, %{})

      assert {true, _} =
               Matchers.description_keywords(skill, %{keywords: ["genserver", "phoenix"], min: 2})

      assert {false, _} =
               Matchers.description_keywords(skill, %{keywords: ["django", "flask"], min: 1})
    end

    test "content_present / content_absent match, and fail closed on a bad pattern" do
      skill = "---\nname: x\ndescription: y\n---\n# X\n\nuse GenServer\n"

      assert {true, _} = Matchers.content_present(skill, %{pattern: "GenServer"})
      assert {false, _} = Matchers.content_present(skill, %{pattern: "Ecto"})
      assert {true, _} = Matchers.content_absent(skill, %{pattern: "Ecto"})
      assert {false, _} = Matchers.content_absent(skill, %{pattern: "GenServer"})

      # untrusted adapter pattern: an invalid regex fails the check, never raises
      assert {false, "invalid pattern: " <> _} = Matchers.content_present(skill, %{pattern: "("})
      assert {false, "invalid pattern: " <> _} = Matchers.content_absent(skill, %{pattern: nil})
    end
  end

  describe "accuracy matchers (pure, known-set membership)" do
    test "valid_file_refs validates own-skill reference paths against the known set" do
      # @good references `${CLAUDE_SKILL_DIR}/references/investigate-retry-loops.md`.
      assert {true, _} =
               Matchers.valid_file_refs(@good, %{known_files: ["investigate-retry-loops.md"]})

      assert {false, evidence} = Matchers.valid_file_refs(@good, %{known_files: ["other.md"]})
      assert evidence =~ "investigate-retry-loops.md"
    end

    test "valid_file_refs neutral-passes without a known set, and when there are no refs" do
      assert {true, "no reference file index supplied — skipping"} =
               Matchers.valid_file_refs(@good, %{})

      assert {true, "no reference file references found"} =
               Matchers.valid_file_refs("no refs here", %{known_files: ["x.md"]})
    end

    test "valid_file_refs ignores cross-skill references (not this skill's to validate)" do
      content = "see `compound-docs/references/schema.md` for details"

      assert {true, "no reference file references found"} =
               Matchers.valid_file_refs(content, %{known_files: []})
    end

    test "valid_skill_refs resolves /ns:name, [[wikilink]] and `name` skill forms" do
      content = "run /phx:plan then the [[investigate]] step and the `verify` skill"

      assert {true, _} =
               Matchers.valid_skill_refs(content, %{known_skills: ~w(plan investigate verify)})

      assert {false, ev} = Matchers.valid_skill_refs(content, %{known_skills: ~w(plan)})
      assert ev =~ "investigate"
    end

    test "valid_agent_refs honors built-ins and the known set" do
      content = ~s(subagent_type: "elixir-reviewer" and the `security-analyzer`)

      assert {true, _} =
               Matchers.valid_agent_refs(content, %{
                 known_agents: ~w(elixir-reviewer security-analyzer)
               })

      # Built-in agents never count as missing even when absent from the known set.
      builtin = ~s(use subagent_type: "general-purpose" here)
      assert {true, _} = Matchers.valid_agent_refs(builtin, %{known_agents: []})
    end
  end

  describe "score/2" do
    test "a well-formed skill scores high" do
      result = Native.score(@good)
      assert result["composite"] >= 0.9
      assert result["dimensions"]["completeness"]["score"] == 1.0
    end

    test "a malformed skill scores low" do
      assert Native.score(@bad)["composite"] < 0.5
    end

    test "honors a custom eval definition instead of the default" do
      custom = [{"only-name", 1.0, [{"frontmatter_field", %{field: "name"}}]}]
      result = Native.score(@good, custom)

      assert Map.keys(result["dimensions"]) == ["only-name"]
      assert result["dimensions"]["only-name"]["score"] == 1.0
      refute Map.has_key?(result["dimensions"], "safety")
    end

    test "nil/empty definition falls back to the default eval" do
      assert Native.score(@good, nil)["dimensions"] == Native.score(@good)["dimensions"]
      assert Map.has_key?(Native.score(@good, [])["dimensions"], "completeness")
    end

    test "reports the total dimension weight (for exact behavioral folding)" do
      assert Native.score(@good)["weight_total"] == 1.0

      # full_eval's 7 structural weights sum to 0.95 (the remaining 0.10 is behavioral, folded later).
      assert Native.score(@good, Native.full_eval())["weight_total"] == 0.95
    end
  end

  describe "full_eval (8-dimension shape)" do
    test "adds an accuracy dimension that neutral-passes without ref known-sets" do
      result = Native.score(@good, Native.full_eval())
      assert Map.has_key?(result["dimensions"], "accuracy")
      assert result["dimensions"]["accuracy"]["score"] == 1.0

      # Behavioral is NOT a structural dimension — it is folded in by Faber.Eval when trigger runs.
      refute Map.has_key?(result["dimensions"], "behavioral")
      assert result["composite"] >= 0.9
    end

    test "accuracy bites when a ref known-set is injected and a ref is broken" do
      # @good references investigate-retry-loops.md; tell accuracy only other.md exists.
      def_ =
        Enum.map(Native.full_eval(), fn
          {"accuracy", w, checks} ->
            {"accuracy", w,
             Enum.map(checks, fn {t, p} -> {t, Map.put(p, :known_files, ["other.md"])} end)}

          dim ->
            dim
        end)

      result = Native.score(@good, def_)
      # valid_file_refs now fails → accuracy drops below 1.0 → composite below the clean run.
      assert result["dimensions"]["accuracy"]["score"] < 1.0
      assert result["composite"] < Native.score(@good, Native.full_eval())["composite"]
    end
  end
end
