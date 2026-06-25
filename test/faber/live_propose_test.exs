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
      assert is_list(proposal.iron_laws) and proposal.iron_laws != []

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
  end
end
