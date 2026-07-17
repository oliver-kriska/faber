defmodule Faber.LiveProposeTest do
  # The ONE test that runs a real model. It shells out to the local `claude -p` CLI (your Claude
  # Code subscription — no API key), so it's excluded from `mix test` and `mix test.full`; run it
  # explicitly with `mix test.live` (alias for `--include live`). `async: false` + a generous
  # timeout because a real generation takes ~60–90s.
  use ExUnit.Case, async: false

  @moduletag :live
  @moduletag timeout: 240_000

  alias Faber.{Adapter, Eval, Install, Propose, Scan}

  @fixtures [base: "test/fixtures", min_messages: 0]

  describe "live propose via the local claude CLI (keyless, real model)" do
    test "scan → propose(claude -p) → native eval → install yields a well-formed, stack-aware skill" do
      {:ok, adapter} = Adapter.load("adapters/faber-elixir")
      assert [%Scan.Result{} = result | _] = Scan.run(@fixtures ++ [rank_by: :raw])

      assert {:ok, proposal} =
               Propose.propose(result, adapter, llm: Faber.LLM.ClaudeCLI, model: "sonnet")

      # Assert STRUCTURE, not exact content — the model is nondeterministic. The name must be a
      # safe path segment (Install enforces it); the description long enough to trigger well; at
      # least one Iron Law present.
      assert is_binary(proposal.name) and proposal.name =~ ~r/\A[a-z0-9][a-z0-9-]{0,63}\z/
      assert is_binary(proposal.description) and String.length(proposal.description) >= 50
      assert proposal.iron_laws != []

      skill = Propose.render_skill_md(proposal, adapter)
      assert {:ok, score} = Eval.score(skill, engine: :native)

      # A real model drafting against a real adapter clears a sane floor. The mostly-structural
      # dimensions (completeness/conciseness/safety/specificity) alone land near 0.7 when the
      # proposal is well-formed; 0.6 leaves margin for the model-variable dimensions (triggering,
      # clarity) without making the test flaky. The production gate threshold is 0.75.
      assert is_float(score.composite)

      assert score.composite >= 0.6,
             "live composite #{score.composite} below floor — inspect the draft"

      tmp = Path.join(System.tmp_dir!(), "faber-live-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(tmp) end)
      assert {:ok, path} = Install.install(proposal, dir: tmp, adapter: adapter, force: true)
      assert File.exists?(path)
    end

    test "scan → propose_hook(claude -p) → hook eval yields a hook that can actually run" do
      # PE-T1. `Faber.HazardToHookTest` runs the hook spine end to end against a script
      # hand-authored in `Faber.LLM.Stub` — so it proves the pipeline does not MANGLE a correct
      # script, and says nothing about whether it PRODUCES one. That gap is not academic: B1 hid in
      # it for four commits, because a benign stub never sends the vector.
      #
      # This is the other half. A real model drafts against the real adapter, and the hook eval —
      # whose dimensions are necessary conditions, not qualities — decides. It asserts structure,
      # never content: the model is nondeterministic, and pinning its bash would make this a test
      # of one generation rather than of the pipeline.
      {:ok, adapter} = Adapter.load("adapters/faber-elixir")

      result = @fixtures |> Scan.run() |> Enum.find(&(&1.hazards != []))
      assert result, "no fixture carries a hazard — this test has lost its subject"
      hazard = hd(result.hazards)

      assert {:ok, proposal} =
               Propose.propose_hook(result, hazard, adapter,
                 llm: Faber.LLM.ClaudeCLI,
                 model: "sonnet"
               )

      assert proposal.kind == :hook
      assert proposal.name =~ ~r/\A[a-z0-9][a-z0-9-]{0,63}\z/

      # The pointer is what Claude Code actually reads. A hook with a bogus event is not a bad
      # hook, it is a file that never runs.
      assert proposal.event in ~w(PreToolUse PostToolUse SessionStart Stop)
      assert is_binary(proposal.matcher) and proposal.matcher != ""

      assert {:ok, eval} = Eval.score(proposal, adapter: adapter)

      # No floor-with-margin here, unlike the skill above. The hook set has no model-variable
      # dimensions to leave room for — `passed` IS the question, and it is the same gate that now
      # decides whether an install is allowed to happen at all (W2). A real model that cannot clear
      # it is the finding.
      assert eval.passed,
             "live hook scored #{eval.composite} (threshold #{eval.threshold}) — " <>
               "dimensions: #{inspect(eval.dimensions, limit: :infinity)}"
    end
  end
end
