defmodule Faber.LoopTest do
  use ExUnit.Case, async: true

  alias Faber.Loop
  alias Faber.Loop.{Journal, Server}

  # A supervised, per-test mutable cell (auto-cleaned by ExUnit).
  defp cell(initial) do
    start_supervised!({Agent, fn -> initial end}, id: {:cell, System.unique_integer([:positive])})
  end

  # A score sequencer: eval_fn pops the next score from a list; exhausted → error.
  defp scorer(scores) do
    agent = cell(scores)

    fn _content ->
      Agent.get_and_update(agent, fn
        [s | rest] -> {{:ok, s}, rest}
        [] -> {{:error, :exhausted}, []}
      end)
    end
  end

  defp always_propose(_state), do: {:ok, %{content: "candidate", description: "change"}}
  defp ok_checks(_content), do: :ok

  describe "run/1 keep/revert/plateau" do
    test "keeps strict improvements and stops (stuck) on plateau" do
      state =
        Loop.run(
          content: "seed",
          composite: 0.4,
          target: 0.95,
          patience: 2,
          checks_fn: &ok_checks/1,
          propose_fn: &always_propose/1,
          eval_fn: scorer([0.5, 0.6, 0.7, 0.7, 0.7])
        )

      assert state.status == :stuck
      assert state.best_composite == 0.7

      kept = Enum.count(state.history, & &1.kept)
      reverted = Enum.count(state.history, &(not &1.kept))
      assert kept == 3
      assert reverted == 2
    end

    test "stops (complete) when the target is reached" do
      state =
        Loop.run(
          content: "seed",
          composite: 0.4,
          target: 0.95,
          checks_fn: &ok_checks/1,
          propose_fn: &always_propose/1,
          eval_fn: scorer([0.96])
        )

      assert state.status == :complete
      assert state.best_composite == 0.96
      assert Enum.count(state.history, & &1.kept) == 1
    end

    test "stops (complete) at max_iterations" do
      state =
        Loop.run(
          content: "seed",
          composite: 0.40,
          target: 0.99,
          patience: 100,
          max_iterations: 5,
          checks_fn: &ok_checks/1,
          propose_fn: &always_propose/1,
          eval_fn: scorer([0.41, 0.42, 0.43, 0.44, 0.45])
        )

      assert state.status == :complete
      assert state.iteration == 5
      assert state.best_composite == 0.45
    end

    test "a failed structural check discards without keeping" do
      state =
        Loop.run(
          content: "seed",
          composite: 0.4,
          patience: 1,
          checks_fn: fn _ -> {:error, :missing_name} end,
          propose_fn: &always_propose/1,
          eval_fn: scorer([0.9])
        )

      assert state.status == :stuck
      assert state.best_composite == 0.4
      assert [%{kept: false, reason: reason}] = state.history
      assert reason =~ "checks failed"
    end
  end

  describe "default_checks/1" do
    test "passes a well-formed skill and flags problems" do
      good = "---\nname: x\ndescription: y\n---\n# X\n"
      assert Loop.default_checks(good) == :ok
      assert Loop.default_checks("# no frontmatter") == {:error, :missing_name}
      assert Loop.default_checks("---\nname: x\n---\n") == {:error, :missing_description}
    end
  end

  describe "journaling" do
    @tag :tmp_dir
    test "appends one JSONL entry per iteration", %{tmp_dir: dir} do
      path = Path.join(dir, "results.jsonl")

      Loop.run(
        content: "seed",
        composite: 0.4,
        patience: 2,
        skill: "demo",
        journal_path: path,
        checks_fn: &ok_checks/1,
        propose_fn: &always_propose/1,
        eval_fn: scorer([0.5, 0.5, 0.5])
      )

      entries = Journal.read(path)
      assert length(entries) == 3
      assert hd(entries)["skill"] == "demo"
      assert hd(entries)["kept"] == true
      assert Enum.at(entries, 1)["kept"] == false
      assert Enum.all?(entries, &is_binary(&1["timestamp"]))
    end
  end

  describe "git ratchet" do
    @tag :tmp_dir
    test "commits on keep and restores the file on revert", %{tmp_dir: dir} do
      skill = "---\nname: demo\ndescription: a demo skill for the loop\n---\n# Demo\n"
      c1 = skill <> "\nversion 1\n"
      c2 = skill <> "\nversion 2 (worse)\n"
      file = Path.join(dir, "SKILL.md")
      File.write!(file, skill)

      {:ok, _} = Loop.Git.git(dir, ["init", "-q"])
      {:ok, _} = Loop.Git.git(dir, ["config", "user.email", "t@example.com"])
      {:ok, _} = Loop.Git.git(dir, ["config", "user.name", "t"])
      {:ok, _} = Loop.Git.git(dir, ["add", "SKILL.md"])
      {:ok, _} = Loop.Git.git(dir, ["commit", "-q", "-m", "baseline"])

      candidates = scorer([0.5, 0.45])
      agent = cell([c1, c2])

      propose_fn = fn _state ->
        content = Agent.get_and_update(agent, fn [h | t] -> {h, t} end)
        {:ok, %{content: content, description: "candidate"}}
      end

      state =
        Loop.run(
          content: skill,
          composite: 0.4,
          target: 0.99,
          max_iterations: 2,
          patience: 100,
          path: file,
          dir: dir,
          git: true,
          git_paths: ["SKILL.md"],
          skill: "demo",
          propose_fn: propose_fn,
          eval_fn: candidates
        )

      # One keep (c1 @ 0.5) then one revert (c2 @ 0.45 < 0.5).
      assert state.best_composite == 0.5
      # The file is restored to the best (c1), not the rejected c2.
      assert File.read!(file) == c1
      # Baseline + one autoresearch keep commit.
      {:ok, log} = Loop.Git.git(dir, ["log", "--oneline"])
      assert length(String.split(log, "\n", trim: true)) == 2
      assert log =~ "autoresearch: demo"
    end
  end

  describe "refine/3 (real pipeline, stubbed LLM + sidecar)" do
    test "terminates deterministically when it cannot beat the seed" do
      state =
        Loop.refine(sample_result(), sample_adapter(),
          llm: Faber.LLM.Stub,
          sidecar: Faber.Sidecar.Stub,
          target: 0.95,
          patience: 3
        )

      assert state.status == :stuck
      assert state.best_composite == 0.9
      assert length(state.history) >= 3
    end
  end

  describe "Loop.Server" do
    test "runs under supervision and exposes the final state" do
      pid =
        start_supervised!(
          {Server,
           [
             content: "seed",
             composite: 0.96,
             target: 0.95,
             checks_fn: &ok_checks/1,
             propose_fn: &always_propose/1,
             eval_fn: scorer([])
           ]}
        )

      assert {:ok, state} = Server.await(pid)
      assert state.status == :complete
      assert Server.status(pid) == :complete
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
