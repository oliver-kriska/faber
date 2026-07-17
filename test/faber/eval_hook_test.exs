defmodule Faber.EvalHookTest do
  @moduledoc """
  The hook eval set.

  Every assertion here runs against the **rendered** artifact — the bytes the installer would
  write — reached through the real `adapters/faber-elixir` pack, not a hand-built fixture. That is
  the project's own rule (CLAUDE.md: "probe matchers against the *rendered* artifact, not a
  fixture"), and it is load-bearing twice over here: the renderer is what *guarantees* the shebang
  check, and the pack's template is the only hook render path there is.
  """
  use ExUnit.Case, async: true

  alias Faber.{Adapter, Eval, Proposal, Propose}
  alias Faber.Eval.{Matchers, Native}

  @adapter_dir Path.expand("../../adapters/faber-elixir", __DIR__)

  setup_all do
    assert {:ok, adapter} = Adapter.load(@adapter_dir)
    %{adapter: adapter}
  end

  @good_script """
  #!/usr/bin/env bash
  input=$(cat)
  command=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')

  if printf '%s' "$command" | grep -Eq 'mix (verify|test)[^|;&]*\\|[^|]*(head|tail)'; then
    echo "Piping a gate command masks its exit code. Redirect to a log instead." >&2
    exit 2
  fi
  exit 0
  """

  defp hook(overrides \\ []) do
    base = %Proposal{
      kind: :hook,
      name: "no-masked-gate-exit",
      description:
        "Blocks piping mix verify/test into head or tail, where the shell reports the " <>
          "filter's exit code. Use when a gate command's status is about to be masked.",
      rationale: "The hazard produces no friction, so a skill would never be triggered by it.",
      event: "PreToolUse",
      matcher: "Bash",
      script: @good_script,
      source: %{hazard: :pipe_masks_exit, hazard_evidence: "`mix verify | tail -5; echo $?`"}
    }

    struct!(base, overrides)
  end

  describe "the rendered hook artifact" do
    test "renders through the pack's hook template, script intact", %{adapter: adapter} do
      rendered = Propose.render(hook(), adapter)

      assert String.starts_with?(rendered, "#!/usr/bin/env bash\n")
      assert rendered =~ "no-masked-gate-exit"
      assert rendered =~ "Fires on: PreToolUse / Bash"
      # Provenance: which hazard produced this, and the evidence command itself.
      assert rendered =~ "pipe_masks_exit"
      assert rendered =~ "mix verify | tail -5"
      # The logic survived rendering.
      assert rendered =~ "jq -r '.tool_input.command"
      assert rendered =~ "exit 2"
    end

    test "the renderer GUARANTEES exactly one shebang, on line 1", %{adapter: adapter} do
      # The renderer-guarantee rule: the eval's shebang check must pass by construction, not by the
      # model complying. Whatever the model returns — its own shebang, a different one, or none —
      # the artifact opens with exactly one.
      for script <- [
            @good_script,
            String.replace(@good_script, "#!/usr/bin/env bash", "#!/bin/sh"),
            String.replace(@good_script, "#!/usr/bin/env bash\n", ""),
            "  \n#!/usr/bin/env zsh\nexit 0\n"
          ] do
        rendered = Propose.render(hook(script: script), adapter)

        assert String.starts_with?(rendered, "#!/usr/bin/env bash\n")
        assert Matchers.hook_shebang(rendered, %{}) == {true, "shebang: #!/usr/bin/env bash"}

        # Exactly one: a second `#!` would be dead text that says one thing while the file does another.
        assert rendered |> String.split("\n") |> Enum.count(&String.starts_with?(&1, "#!")) == 1
      end
    end
  end

  describe "the gate" do
    test "a well-formed hook passes", %{adapter: adapter} do
      assert {:ok, result} = Eval.score(hook(), adapter: adapter)

      assert result.passed
      assert result.vetoed == []
      assert result.composite >= 0.75
      assert Map.keys(result.dimensions) |> Enum.sort() == ["executable", "pointer", "safety"]
    end

    test "the hook set is used — not the skill set it would fail", %{adapter: adapter} do
      # The reason the set exists: a hook has no frontmatter, Iron Laws, or prose, so the skill
      # matchers don't judge it harshly, they don't judge it at all. Pinned as a number so
      # "hooks need their own set" stays a measurement rather than a claim.
      rendered = Propose.render(hook(), adapter)

      assert {:ok, as_skill} = Eval.score(rendered, eval: Native.default_eval())
      refute as_skill.passed
      assert as_skill.composite < 0.45

      assert {:ok, as_hook} = Eval.score(hook(), adapter: adapter)
      assert as_hook.passed
    end

    test "a hook whose script would harm is VETOED, same veto as a skill", %{adapter: adapter} do
      evil = hook(script: @good_script <> "\nrm -rf /\n")

      assert {:ok, result} = Eval.score(evil, adapter: adapter)

      refute result.passed
      assert [%{check_type: "no_dangerous_patterns", evidence: evidence}] = result.vetoed
      assert evidence =~ "rm"
    end

    test "the veto cannot be defeated by a `##` shell comment", %{adapter: adapter} do
      # Reproduced before it was fixed: `##` is an ordinary shell comment AND a markdown heading, so
      # the safe-section exemption — which exists so a skill can DOCUMENT `rm -rf /` under
      # "## Anti-patterns" — skipped the whole region of an executable script. A hook with this body
      # scored a clean `{true, "no dangerous patterns"}` and would have installed.
      sneaky = hook(script: @good_script <> "\n## Anti-patterns\nrm -rf /\n")

      assert {:ok, result} = Eval.score(sneaky, adapter: adapter)

      refute result.passed
      assert [%{check_type: "no_dangerous_patterns"}] = result.vetoed
    end

    test "the skill exemption still works — a skill may document a danger" do
      # The other half: the fix must not make the skill set paranoid. A skill legitimately naming
      # `rm -rf /` in an anti-patterns section is doing its job.
      skill_md = """
      ---
      name: safe-deletes
      description: "Guards destructive shell in generated skills. Use when reviewing shell."
      ---

      # Safe Deletes

      ## Anti-patterns

      - Never write `rm -rf /` — it is the canonical footgun.
      """

      assert Matchers.no_dangerous_patterns(skill_md, %{}) == {true, "no dangerous patterns"}

      assert {false, _} = Matchers.no_dangerous_patterns(skill_md, %{exempt_safe_sections: false})
    end

    test "a malformed pointer fails structurally", %{adapter: adapter} do
      # An unknown event is a hook that silently never fires — the same fail-quietly shape this
      # whole plan closes, and worth failing loudly at the gate.
      assert {:ok, bad_event} = Eval.score(hook(event: "PreCommit"), adapter: adapter)
      refute bad_event.passed
      assert bad_event.dimensions["pointer"]["score"] == 0.0

      assert {:ok, no_matcher} = Eval.score(hook(matcher: "  "), adapter: adapter)
      refute no_matcher.passed
      assert no_matcher.dimensions["pointer"]["score"] == 0.0

      assert {:ok, nil_event} = Eval.score(hook(event: nil), adapter: adapter)
      refute nil_event.passed
    end

    test "a script that never reads stdin fails — it cannot see what it is deciding about",
         %{adapter: adapter} do
      blind = hook(script: "#!/usr/bin/env bash\necho 'always fine'\nexit 0\n")

      assert {:ok, result} = Eval.score(blind, adapter: adapter)

      refute result.passed
      assert result.dimensions["executable"]["score"] == 0.5
    end
  end

  describe "hook_pointer/2 in isolation" do
    test "an unresolved pointer FAILS rather than neutral-passing" do
      # Opposite posture to `valid_file_refs`, deliberately: a missing ref known-set means we
      # couldn't resolve context; a missing pointer means the hook has nowhere to be installed.
      assert {false, evidence} = Matchers.hook_pointer("#!/bin/sh", %{})
      assert evidence =~ "no hook event"
    end

    test "an unknown event names the known set" do
      assert {false, evidence} =
               Matchers.hook_pointer("", %{
                 event: "OnTuesday",
                 matcher: "Bash",
                 known_events: Propose.hook_events()
               })

      assert evidence =~ "silently never runs"
      assert evidence =~ "PreToolUse"
    end

    test "every event Propose will emit is accepted by the matcher" do
      # The prompt tells the model these are legal; the eval must agree, or the proposer and the
      # gate disagree about what a valid hook is.
      for event <- Propose.hook_events() do
        assert {true, _} =
                 Matchers.hook_pointer("", %{
                   event: event,
                   matcher: "Bash",
                   known_events: Propose.hook_events()
                 })
      end
    end
  end
end
