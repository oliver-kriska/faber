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
  end
end
