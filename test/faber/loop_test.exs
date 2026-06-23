defmodule Faber.LoopTest do
  use ExUnit.Case, async: true

  alias Faber.Loop
  alias Faber.Loop.{Journal, Server}

  # A sidecar double that sequences composites from an Agent passed via `:seq_agent` in opts.
  # `refine/3` forwards its opts to `Faber.Eval.score` → `Faber.Sidecar.call`, so this lets the
  # real Propose+Eval+run wiring be driven through controlled scores (a constant stub can't show
  # keep/revert — see review BL4). Nested module → `Faber.LoopTest.SeqSidecar`, no global collision.
  defmodule SeqSidecar do
    @behaviour Faber.Sidecar

    @impl true
    def call(_command, _request, opts) do
      # Contract: refine/3 forwards its opts verbatim through Eval.score → Sidecar.call, so
      # :seq_agent arrives here. fetch! is deliberate — if that pass-through ever changes, this
      # test should fail loudly rather than silently scoring 0.0.
      composite =
        opts
        |> Keyword.fetch!(:seq_agent)
        |> Agent.get_and_update(fn
          [s | rest] -> {s, rest}
          [] -> {0.0, []}
        end)

      {:ok, %{"status" => "ok", "result" => %{"composite" => composite, "dimensions" => %{}}}}
    end
  end

  defmodule FailingLLM do
    @behaviour Faber.LLM
    @impl true
    def generate_object(_prompt, _schema, _opts), do: {:error, :llm_unavailable}
  end

  # Reflective double: returns a deliberately weak skill on the first (feedback-free) call, and a
  # strong one once the prompt carries reflective feedback ("REVISION TASK"). Proves the :reflect
  # strategy threads the eval's weakness back into the next proposal — scored by the REAL native
  # deterministic eval, so a strictly better candidate is genuinely produced and kept.
  defmodule ReflectiveLLM do
    @behaviour Faber.LLM
    @impl true
    def generate_object(prompt, _schema, _opts) do
      if String.contains?(prompt, "REVISION TASK") do
        {:ok,
         %{
           name: "investigate-retry-loops",
           description:
             "Investigate failing shell commands by reading the error before retrying. " <>
               "Use when a command is retried after an error. NOT for first failures.",
           effort: "low",
           rationale:
             "Stop blind retries: read the error, form one hypothesis, change one variable, re-run.",
           iron_laws: [
             "Read the actual error output before retrying — never re-run blind.",
             "Change exactly one variable per attempt so the result is attributable.",
             "After 3 failed attempts, stop and escalate with what was tried."
           ],
           usage: "Load when a command like mix test is re-run after an errored result.",
           example: "mix test --failed",
           should_trigger: ["the same command keeps failing"],
           should_not_trigger: ["first time running this"]
         }}
      else
        {:ok,
         %{
           name: "investigate-retry-loops",
           description: "Does general things sometimes.",
           effort: "low",
           rationale: "help",
           iron_laws: ["try again", "maybe read"],
           usage: nil,
           example: nil,
           should_trigger: [],
           should_not_trigger: []
         }}
      end
    end
  end

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

    test "an eval_fn error mid-iteration discards without keeping" do
      state =
        Loop.run(
          content: "seed",
          composite: 0.4,
          patience: 1,
          checks_fn: &ok_checks/1,
          propose_fn: &always_propose/1,
          eval_fn: fn _ -> {:error, :timeout} end
        )

      assert state.status == :stuck
      assert state.best_composite == 0.4
      assert [%{kept: false, reason: reason}] = state.history
      assert reason =~ "eval failed"
    end

    test "a propose_fn error mid-iteration discards without keeping" do
      state =
        Loop.run(
          content: "seed",
          composite: 0.4,
          patience: 1,
          checks_fn: &ok_checks/1,
          propose_fn: fn _ -> {:error, :llm_unavailable} end,
          eval_fn: scorer([0.9])
        )

      assert state.status == :stuck
      assert state.best_composite == 0.4
      assert [%{kept: false, description: desc}] = state.history
      assert desc =~ "proposal failed"
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

  describe "refine/3 (real Propose + Eval wiring)" do
    test "keeps strict improvements, reverts regressions, and reports the best" do
      # seed 0.5 → keep 0.6 → revert 0.55 ×3 → stuck (patience 3). Drives the real pipeline
      # (Propose + Eval + run) with sequenced eval scores, so a broken keep/revert would fail here.
      scores = cell([0.5, 0.6, 0.55, 0.55, 0.55])

      state =
        Loop.refine(sample_result(), sample_adapter(),
          llm: Faber.LLM.Stub,
          sidecar: SeqSidecar,
          seq_agent: scores,
          target: 0.95,
          patience: 3
        )

      assert state.status == :stuck
      assert state.best_composite == 0.6
      assert Enum.count(state.history, & &1.kept) == 1
      assert Enum.count(state.history, &(not &1.kept)) == 3
    end

    test "returns {:error, reason} when the seed proposal fails, instead of crashing" do
      assert {:error, :llm_unavailable} =
               Loop.refine(sample_result(), sample_adapter(), llm: FailingLLM)
    end
  end

  describe "refine/3 :reflect strategy (keyless reflective evolution)" do
    test "feeds eval weaknesses back to produce a strictly better candidate and keeps it" do
      # Seed (no feedback) is weak; the reflective re-proposal sees the weakness feedback and
      # returns a strong skill. The native deterministic eval scores both, so the gain is real.
      state =
        Loop.refine(sample_result(), sample_adapter(),
          llm: ReflectiveLLM,
          strategy: :reflect,
          max_iterations: 1,
          target: 0.99
        )

      assert state.status == :complete
      kept = Enum.filter(state.history, & &1.kept)
      assert length(kept) == 1
      [entry] = kept
      # Reflective edit improved on the seed, and the entry records which dimension it targeted.
      assert entry.new_composite > entry.old_composite
      assert entry.description =~ "reflect:"
      assert state.best_composite == entry.new_composite
    end

    test "Faber.Optimize.reflect/3 delegates to the reflective loop" do
      state =
        Faber.Optimize.reflect(sample_result(), sample_adapter(),
          llm: ReflectiveLLM,
          max_iterations: 1,
          target: 0.99
        )

      assert %Loop.State{status: :complete} = state
      assert Enum.any?(state.history, &(&1.kept and &1.description =~ "reflect:"))
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

      assert {:ok, state} = Server.await(pid, 5_000)
      assert state.status == :complete
      assert Server.status(pid) == :complete
    end

    test "runs a multi-iteration loop in the background and await returns the final state" do
      pid =
        start_supervised!(
          {Server,
           [
             content: "seed",
             composite: 0.4,
             target: 0.95,
             max_iterations: 3,
             patience: 100,
             checks_fn: &ok_checks/1,
             propose_fn: &always_propose/1,
             eval_fn: scorer([0.5, 0.6, 0.7])
           ]}
        )

      # The loop runs in a Task (not in handle_continue), so await is replied to on completion
      # rather than blocking the server — and it survives a run longer than one iteration. A
      # bounded timeout means a broken loop fails fast instead of hanging the test.
      assert {:ok, state} = Server.await(pid, 5_000)
      assert state.status == :complete
      assert state.iteration == 3
      assert state.best_composite == 0.7
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
