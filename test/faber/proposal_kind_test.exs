defmodule Faber.ProposalKindTest do
  @moduledoc """
  The artifact-kind seam.

  Phase C of the hook-emission plan threads a `kind` through the type system with `:skill` as the
  default. The claim being tested is that `kind: :skill` is a true **identity** — every pre-existing
  path behaves exactly as it did — and that the kind actually forks where it must (filename,
  template selection, clustering, loop checks).

  The identity claim's real proof is the whole existing suite passing with zero fixture changes.
  What is asserted here is the part that proof can't show: that the fork exists at all.
  """
  use ExUnit.Case, async: true

  alias Faber.{Adapter, Consolidate, Loop, Proposal, Propose}

  doctest Faber.Proposal, import: true

  describe "kind defaults to :skill (the identity case)" do
    test "a proposal built with no kind is a skill" do
      assert %Proposal{}.kind == :skill
    end

    test "a skill still writes SKILL.md — the exact path it always did" do
      assert Proposal.filename(%Proposal{}) == "SKILL.md"
      assert Proposal.filename(%Proposal{kind: :skill}) == "SKILL.md"
      assert Proposal.filename(:skill) == "SKILL.md"
    end

    test "a hook writes its script, not a skill-shaped path" do
      assert Proposal.filename(%Proposal{kind: :hook}) == "hook.sh"
      assert Proposal.filename(:hook) == "hook.sh"
    end
  end

  describe "render/2 selects the template by kind" do
    setup do
      %{proposal: %Proposal{name: "verify-gate", description: "d", rationale: "r"}}
    end

    test "a skill renders through the pack's `skill` template", %{proposal: p} do
      adapter = %Adapter{templates: %{"skill" => "SKILL FROM TEMPLATE: {{skill_name}}"}}
      assert Propose.render(p, adapter) == "SKILL FROM TEMPLATE: verify-gate"
    end

    test "a hook renders through the pack's `hook` template — the key that was unreachable", %{
      proposal: p
    } do
      # Before Phase C, `Map.get(templates, "skill")` was the only key fetched repo-wide, so a pack
      # could ship a `produces: hook` template that loaded and could never be rendered.
      adapter = %Adapter{
        templates: %{
          "skill" => "SKILL: {{skill_name}}",
          "hook" => "HOOK FROM TEMPLATE: {{skill_name}}"
        }
      }

      hook = %{p | kind: :hook}
      assert Propose.render(hook, adapter) == "HOOK FROM TEMPLATE: verify-gate"
    end

    test "a skill with no template falls back to the built-in renderer", %{proposal: p} do
      # The fallback is skill-only *because* there is a built-in SKILL.md scaffold to fall back to.
      md = Propose.render(p, %Adapter{templates: %{}})
      assert md =~ "name: verify-gate"
      assert md =~ "---"

      assert Propose.render(p, nil) == md
    end

    test "a hook with no hook template raises rather than rendering a skill", %{proposal: p} do
      # The no-silent-fall-through rule: rendering a hook as a skill (or as "") would hand the eval
      # an artifact of the wrong kind and let it pass on skill criteria.
      hook = %{p | kind: :hook}

      assert_raise ArgumentError, ~r/no hook template/, fn ->
        Propose.render(hook, %Adapter{templates: %{"skill" => "SKILL: {{skill_name}}"}})
      end

      assert_raise ArgumentError, ~r/templates\/manifest\.yaml/, fn ->
        Propose.render(hook, nil)
      end
    end

    test "render_skill_md/2 still delegates, so the 13 callsites are unchanged", %{proposal: p} do
      adapter = %Adapter{templates: %{"skill" => "SKILL: {{skill_name}}"}}
      assert Propose.render_skill_md(p, adapter) == Propose.render(p, adapter)
    end
  end

  describe "Consolidate.cluster/2 never merges across kinds" do
    test "a hook and a skill with near-identical vocabulary stay separate" do
      # The words overlap *because* both address the same friction — which is exactly why
      # similarity alone cannot decide. Merging them would ask one LLM call to fuse a shell script
      # with a markdown skill into an artifact that is neither.
      skill = %Proposal{
        kind: :skill,
        name: "verify-exit-code",
        description: "never read mix verify exit code from a pipe",
        should_trigger: ["running mix verify", "checking the exit code"]
      }

      hook = %{skill | kind: :hook, name: "verify-exit-code-hook"}

      clusters = Consolidate.cluster([skill, hook])

      assert length(clusters) == 2
      assert Enum.all?(clusters, &(length(&1) == 1))
    end

    test "two skills with that same vocabulary DO still cluster (the guard is kind, not caution)" do
      a = %Proposal{
        kind: :skill,
        name: "verify-exit-code",
        description: "never read mix verify exit code from a pipe",
        should_trigger: ["running mix verify", "checking the exit code"]
      }

      b = %{a | name: "verify-exit-status"}

      assert [[_, _]] = Consolidate.cluster([a, b])
    end

    test "two hooks with shared vocabulary cluster with each other" do
      a = %Proposal{
        kind: :hook,
        name: "verify-exit-code",
        description: "never read mix verify exit code from a pipe",
        should_trigger: ["running mix verify", "checking the exit code"]
      }

      b = %{a | name: "verify-exit-status"}

      assert [[_, _]] = Consolidate.cluster([a, b])
    end
  end

  describe "Loop.default_checks — a hook is not judged by skill frontmatter" do
    @hook_script """
    #!/usr/bin/env bash
    set -euo pipefail
    command=$(jq -r '.tool_input.command')
    echo "$command"
    """

    test "the skill checks still behave exactly as before" do
      assert Loop.default_checks("name: x\ndescription: y\n") == :ok
      assert Loop.default_checks("description: y\n") == {:error, :missing_name}
      assert Loop.default_checks("name: x\n") == {:error, :missing_description}

      assert Loop.default_checks("name: x\ndescription: y\n<<<<<<< HEAD") ==
               {:error, :conflict_markers}

      long = "name: x\ndescription: y\n" <> String.duplicate("line\n", 600)
      assert Loop.default_checks(long) == {:error, :too_long}
    end

    test "default_checks/1 is default_checks(content, :skill)" do
      assert Loop.default_checks("description: y\n") ==
               Loop.default_checks("description: y\n", :skill)
    end

    test "a hook script passes despite having no frontmatter at all" do
      # The guard PC-T5 exists for: run the skill checks over a shell script and every hook ever
      # generated is rejected for `:missing_name` — a check bug reported as a hook bug.
      assert Loop.default_checks(@hook_script, :hook) == :ok
      assert Loop.default_checks(@hook_script, :skill) == {:error, :missing_name}
    end

    test "a hook still has a floor: empty and conflict-marked scripts fail" do
      assert Loop.default_checks("", :hook) == {:error, :empty_script}
      assert Loop.default_checks("   \n  ", :hook) == {:error, :empty_script}

      assert Loop.default_checks(@hook_script <> "\n>>>>>>> theirs", :hook) ==
               {:error, :conflict_markers}
    end
  end
end
