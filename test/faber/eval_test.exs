defmodule Faber.EvalTest do
  use ExUnit.Case, async: true

  alias Faber.Eval

  defmodule PassSidecar do
    @behaviour Faber.Sidecar
    @impl true
    def call(_command, _request, _opts) do
      {:ok, %{"status" => "ok", "result" => %{"composite" => 0.92, "dimensions" => %{}}}}
    end
  end

  defmodule FailSidecar do
    @behaviour Faber.Sidecar
    @impl true
    def call(_command, _request, _opts) do
      {:ok, %{"status" => "ok", "result" => %{"composite" => 0.40, "dimensions" => %{}}}}
    end
  end

  defmodule ErrorSidecar do
    @behaviour Faber.Sidecar
    @impl true
    def call(_command, _request, _opts) do
      {:ok, %{"status" => "error", "error" => "missing skill_md"}}
    end
  end

  @skill "---\nname: x\ndescription: y\n---\n# X\n"

  describe "score/2 (stubbed sidecar)" do
    test "passes when composite >= threshold" do
      {:ok, r} = Eval.score(@skill, sidecar: PassSidecar, threshold: 0.75)
      assert r.composite == 0.92
      assert r.threshold == 0.75
      assert r.passed
    end

    test "fails when composite < threshold" do
      {:ok, r} = Eval.score(@skill, sidecar: FailSidecar, threshold: 0.75)
      refute r.passed
    end

    test "threshold is configurable per call" do
      {:ok, r} = Eval.score(@skill, sidecar: FailSidecar, threshold: 0.30)
      assert r.passed
    end

    test "surfaces a sidecar status:error" do
      assert {:error, {:sidecar_error, "missing skill_md"}} =
               Eval.score(@skill, sidecar: ErrorSidecar)
    end

    test "accepts a Proposal and renders it before scoring" do
      {:ok, proposal} =
        Faber.Propose.propose(sample_result(), sample_adapter(), llm: Faber.LLM.Stub)

      {:ok, r} = Eval.score(proposal, sidecar: PassSidecar)
      assert r.passed
    end
  end

  describe "gate/2 (stubbed sidecar)" do
    test "returns :pass / :fail" do
      assert {:pass, _} = Eval.gate(@skill, sidecar: PassSidecar)
      assert {:fail, _} = Eval.gate(@skill, sidecar: FailSidecar)
    end
  end

  describe "score/2 (real python sidecar)" do
    @describetag :sidecar

    test "scores a rendered proposal end to end" do
      {:ok, proposal} =
        Faber.Propose.propose(sample_result(), sample_adapter(), llm: Faber.LLM.Stub)

      assert {:ok, r} = Eval.score(proposal)
      assert is_float(r.composite)
      assert r.composite > 0.5
      assert is_map(r.dimensions)
      assert Map.has_key?(r.dimensions, "completeness")
    end
  end

  defp sample_adapter do
    %Faber.Adapter{name: "faber-elixir", version: "0.1.0", laws: [], playbooks: []}
  end

  defp sample_result do
    %Faber.Scan.Result{
      path: "/x/abc.jsonl",
      session_id: "abc",
      friction: 0.9,
      raw: 12.0,
      dominant_signal: :retry_loops,
      signals: %{
        retry_loops: 2,
        user_corrections: 1,
        error_tool_ratio: 0.3,
        approach_changes: 0,
        context_compactions: 0,
        interrupted_requests: 0
      },
      fingerprint: "bug-fix",
      fingerprint_confidence: 0.6,
      opportunity: 0.4,
      missed: ["investigate"],
      skills_used: [],
      tool_count: 10,
      error_count: 3,
      message_count: 40,
      parse_errors: 0,
      tier2: true
    }
  end
end
