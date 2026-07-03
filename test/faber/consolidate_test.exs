defmodule Faber.ConsolidateTest do
  use ExUnit.Case, async: true

  alias Faber.{Adapter, Consolidate, Proposal}

  defmodule FailingLLM do
    @behaviour Faber.LLM
    @impl true
    def generate_object(_prompt, _schema, _opts), do: {:error, :llm_unavailable}
  end

  # Two near-duplicate "investigate before retrying" drafts (the shape real cross-session scans
  # produce) and one unrelated skill.
  defp p1 do
    %Proposal{
      name: "investigate-retry-loops",
      description:
        "Investigate failing shell commands before retrying them blindly. " <>
          "Use when the same command keeps failing.",
      rationale: "r1",
      iron_laws: ["Read the error first.", "Change one variable.", "Escalate after 3."],
      should_trigger: ["the same command keeps failing"],
      source: %{session_id: "sess-1"}
    }
  end

  defp p2 do
    %Proposal{
      name: "investigate-failing-commands",
      description:
        "Investigate failing commands systematically before blindly retrying. " <>
          "Use when a command keeps failing after errors.",
      rationale: "r2",
      iron_laws: ["Read the actual error output.", "Never re-run blind."],
      should_trigger: ["this command errored, trying again"],
      source: %{session_id: "sess-2"}
    }
  end

  defp p3 do
    %Proposal{
      name: "ecto-migration-safety",
      description:
        "Design safe Ecto migrations with rollback plans. Use when writing schema migrations.",
      rationale: "r3",
      iron_laws: ["Always provide down/0.", "Never drop columns in the same deploy."],
      should_trigger: ["write a migration for this table"],
      source: %{session_id: "sess-3"}
    }
  end

  defp sample_adapter do
    %Adapter{name: "faber-elixir", version: "0.1.0", laws: [], playbooks: []}
  end

  describe "cluster/2 (pure, deterministic)" do
    test "groups overlapping proposals and keeps unrelated ones apart" do
      assert [[a, b], [c]] = Consolidate.cluster([p1(), p2(), p3()])
      assert a.name == "investigate-retry-loops"
      assert b.name == "investigate-failing-commands"
      assert c.name == "ecto-migration-safety"
    end

    test "a raised threshold splits everything into singletons" do
      assert [[_], [_], [_]] = Consolidate.cluster([p1(), p2(), p3()], threshold: 0.9)
    end

    test "empty input clusters to nothing" do
      assert Consolidate.cluster([]) == []
    end
  end

  describe "merge/3" do
    test "a singleton passes through without an LLM call" do
      assert {:ok, only} = Consolidate.merge([p1()], sample_adapter(), llm: FailingLLM)
      assert only == p1()
    end

    test "a multi-proposal cluster merges via the LLM and records provenance" do
      assert {:ok, %Proposal{} = merged} =
               Consolidate.merge([p1(), p2()], sample_adapter(), llm: Faber.LLM.Stub)

      assert merged.adapter == "faber-elixir"

      assert merged.source.merged_from == [
               "investigate-retry-loops",
               "investigate-failing-commands"
             ]

      assert merged.source.session_ids == ["sess-1", "sess-2"]
      # The stub's canned proposal shape flows through the same schema the proposer uses.
      assert merged.iron_laws != []
    end
  end

  describe "run/3 (cluster + merge + eval gate)" do
    test "merges the overlapping pair, keeps the unrelated singleton, gates the merge" do
      outcomes =
        Consolidate.run([p1(), p2(), p3()], sample_adapter(),
          llm: Faber.LLM.Stub,
          eval_threshold: 0.5
        )

      assert [{:merged, %Proposal{} = merged, eval, originals}, {:kept, kept}] = outcomes

      assert merged.source.merged_from == [
               "investigate-retry-loops",
               "investigate-failing-commands"
             ]

      assert eval.passed
      assert Enum.map(originals, & &1.name) == Enum.map([p1(), p2()], & &1.name)
      assert kept.name == "ecto-migration-safety"
    end

    test "a merge that fails the gate keeps the originals (never trades quality for tidiness)" do
      weak = %{
        "name" => "weak-merge",
        "description" => "Does stuff.",
        "rationale" => "meh",
        "iron_laws" => []
      }

      assert [{:kept_originals, originals, eval}, {:kept, _}] =
               Consolidate.run([p1(), p2(), p3()], sample_adapter(),
                 llm: Faber.LLM.Stub,
                 stub_response: weak
               )

      refute eval.passed
      assert length(originals) == 2
    end

    test "a failed merge LLM call surfaces as :error with the originals intact" do
      assert [{:error, originals, :llm_unavailable}, {:kept, _}] =
               Consolidate.run([p1(), p2(), p3()], sample_adapter(), llm: FailingLLM)

      assert length(originals) == 2
    end
  end
end
