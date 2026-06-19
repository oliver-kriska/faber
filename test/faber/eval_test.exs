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

  describe "score/2 (adapter-aware — the stack-specific eval bar)" do
    test "a vendored adapter's eval dimensions drive scoring" do
      adapter = %Faber.Adapter{
        name: "x",
        version: "0.1.0",
        eval: %{
          "mode" => "vendored",
          "dimensions" => [
            %{
              "name" => "completeness",
              "weight" => 1.0,
              "checks" => [%{"type" => "frontmatter_field", "params" => %{"field" => "name"}}]
            }
          ]
        }
      }

      {:ok, r} = Eval.score(@skill, adapter: adapter)
      assert Map.keys(r.dimensions) == ["completeness"]
      assert r.composite == 1.0
      # Only the adapter's dimensions — NOT the generic default set.
      refute Map.has_key?(r.dimensions, "safety")
    end

    test "an exec-in-place adapter falls back to the default native eval (never blocks the gate)" do
      adapter = %Faber.Adapter{
        name: "x",
        version: "0.1.0",
        eval: %{"mode" => "exec-in-place", "root" => "/nonexistent"}
      }

      {:ok, r} = Eval.score(@skill, adapter: adapter)
      # The full default dimension set is used as the fallback.
      assert Map.has_key?(r.dimensions, "completeness")
      assert Map.has_key?(r.dimensions, "safety")
    end

    test "an explicit :eval definition overrides the adapter" do
      adapter = %Faber.Adapter{name: "x", version: "0.1.0", eval: %{"mode" => "vendored"}}
      custom = [{"only", 1.0, [{"frontmatter_field", %{field: "description"}}]}]

      {:ok, r} = Eval.score(@skill, adapter: adapter, eval: custom)
      assert Map.keys(r.dimensions) == ["only"]
    end
  end

  describe "gate/2 (stubbed sidecar)" do
    test "returns :pass / :fail" do
      assert {:pass, _} = Eval.gate(@skill, sidecar: PassSidecar)
      assert {:fail, _} = Eval.gate(@skill, sidecar: FailSidecar)
    end
  end

  describe "score/2 (native engine, default)" do
    test "scores a rendered proposal in-process with no sidecar" do
      {:ok, proposal} =
        Faber.Propose.propose(sample_result(), sample_adapter(), llm: Faber.LLM.Stub)

      assert {:ok, r} = Eval.score(proposal)
      assert is_float(r.composite)
      assert r.composite > 0.5
      assert Map.has_key?(r.dimensions, "completeness")
    end
  end

  describe "score/2 (real python sidecar)" do
    @describetag :sidecar

    test "the python engine agrees with native within tolerance, on good and bad inputs" do
      {:ok, proposal} =
        Faber.Propose.propose(sample_result(), sample_adapter(), llm: Faber.LLM.Stub)

      good = Faber.Propose.render_skill_md(proposal)
      bad = "---\nname: stuff\n---\n\n# Stuff\n\nVague prose, no laws, no examples.\n"

      # Parity must hold across the score range, not just on a passing fixture — a single-input
      # check could mask a systematic native/sidecar bias (review testing W5).
      for input <- [good, bad] do
        assert {:ok, native} = Eval.score(input, engine: :native)
        assert {:ok, sidecar} = Eval.score(input, engine: :sidecar)
        assert_in_delta native.composite, sidecar.composite, 0.05
      end
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
