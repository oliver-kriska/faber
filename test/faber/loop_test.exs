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

  # A sidecar that fails every call — drives Eval.score down its {:error, _} path wherever the
  # loop consumes it (candidate scoring, seed scoring, the final holdout validation).
  defmodule FailSidecar do
    @behaviour Faber.Sidecar
    @impl true
    def call(_command, _request, _opts), do: {:error, :sidecar_down}
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

  # Serves BOTH LLM roles of a trigger-mode refine. As the trigger ROUTER (schema carries
  # :triggers) it answers mechanically — activate iff the request phrase contains "XYZZY". As the
  # PROPOSER it returns a candidate identical to the seed's content but with GAMED fixtures its
  # own routing trivially aces. If the loop ever scored candidates on their own fixtures, every
  # candidate would jump to a perfect behavioral score and be kept; with seed-pinning they tie
  # the baseline and are all rejected.
  defmodule GamingLLM do
    @behaviour Faber.LLM

    @impl true
    def generate_object(prompt, schema, _opts) do
      if Keyword.keyword?(schema) and Keyword.has_key?(schema, :triggers) do
        {:ok, %{triggers: String.contains?(prompt, "XYZZY")}}
      else
        gamed =
          Map.merge(Faber.LLM.Stub.default_proposal(), %{
            "should_trigger" => ["XYZZY please do the thing"],
            "should_not_trigger" => ["a plain unrelated question"]
          })

        {:ok, gamed}
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

    # The ratchet invariant is "HEAD always holds the current best" — so a keep whose commit
    # FAILS must become a reject (restore to HEAD, count the discard), or in-memory best and the
    # committed tree silently diverge and the next revert discards the "kept" content.
    @tag :tmp_dir
    test "a failed git commit turns the keep into a reject", %{tmp_dir: dir} do
      skill = "---\nname: demo\ndescription: a demo skill for the loop\n---\n# Demo\n"
      c1 = skill <> "\nversion 1\n"
      file = Path.join(dir, "SKILL.md")
      File.write!(file, skill)

      {:ok, _} = Loop.Git.git(dir, ["init", "-q"])
      {:ok, _} = Loop.Git.git(dir, ["config", "user.email", "t@example.com"])
      {:ok, _} = Loop.Git.git(dir, ["config", "user.name", "t"])
      {:ok, _} = Loop.Git.git(dir, ["add", "SKILL.md"])
      {:ok, _} = Loop.Git.git(dir, ["commit", "-q", "-m", "baseline"])

      # Make every `git commit` fail (add still succeeds): a rejecting pre-commit hook.
      hooks = Path.join(dir, "hooks")
      File.mkdir_p!(hooks)
      hook = Path.join(hooks, "pre-commit")
      File.write!(hook, "#!/bin/sh\nexit 1\n")
      File.chmod!(hook, 0o755)
      {:ok, _} = Loop.Git.git(dir, ["config", "core.hooksPath", "hooks"])

      state =
        Loop.run(
          content: skill,
          composite: 0.4,
          target: 0.99,
          max_iterations: 1,
          patience: 100,
          path: file,
          dir: dir,
          git: true,
          git_paths: ["SKILL.md"],
          skill: "demo",
          propose_fn: fn _state -> {:ok, %{content: c1, description: "candidate"}} end,
          eval_fn: scorer([0.9])
        )

      # The improvement could not be banked: best is unchanged and nothing was kept.
      assert state.best_composite == 0.4
      assert state.best_content == skill
      assert [%{kept: false} = entry] = state.history
      assert entry.reason =~ "commit failed"
      # The working tree was restored to HEAD, not left holding the un-committed candidate.
      assert File.read!(file) == skill
      {:ok, log} = Loop.Git.git(dir, ["log", "--oneline"])
      assert length(String.split(log, "\n", trim: true)) == 1
    end

    # The flip side: a candidate byte-identical to HEAD (eval noise re-scores the same draft
    # higher) is a SUCCESSFUL no-op keep — HEAD already holds it. `git commit` alone would exit
    # non-zero ("nothing to commit"); that must not be reported as a failure.
    @tag :tmp_dir
    test "a candidate identical to HEAD keeps without a new commit", %{tmp_dir: dir} do
      skill = "---\nname: demo\ndescription: a demo skill for the loop\n---\n# Demo\n"
      file = Path.join(dir, "SKILL.md")
      File.write!(file, skill)

      {:ok, _} = Loop.Git.git(dir, ["init", "-q"])
      {:ok, _} = Loop.Git.git(dir, ["config", "user.email", "t@example.com"])
      {:ok, _} = Loop.Git.git(dir, ["config", "user.name", "t"])
      {:ok, _} = Loop.Git.git(dir, ["add", "SKILL.md"])
      {:ok, _} = Loop.Git.git(dir, ["commit", "-q", "-m", "baseline"])

      state =
        Loop.run(
          content: skill,
          composite: 0.4,
          target: 0.99,
          max_iterations: 1,
          patience: 100,
          path: file,
          dir: dir,
          git: true,
          git_paths: ["SKILL.md"],
          skill: "demo",
          propose_fn: fn _state -> {:ok, %{content: skill, description: "same draft"}} end,
          eval_fn: scorer([0.9])
        )

      assert state.best_composite == 0.9
      assert [%{kept: true}] = state.history
      # No new commit — HEAD already held the content.
      {:ok, log} = Loop.Git.git(dir, ["log", "--oneline"])
      assert length(String.split(log, "\n", trim: true)) == 1
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

  describe "refine/3 :reflect eval economy" do
    test "the unchanged best is NOT re-scored every iteration — reflection reads the cached eval" do
      # Every Eval.score consumes exactly one sequenced sidecar score, so the agent's remaining
      # length counts the evals. Expected: seed (1) + one per candidate (3 iterations, all ties →
      # rejected) = 4. The pre-fix behavior ALSO re-scored the unchanged best inside
      # reflection_feedback each iteration (= 7 here) — in trigger mode each of those re-scores
      # is trigger_samples × fixtures real LLM routing calls, roughly doubling a run's spend.
      scores = cell(List.duplicate(0.5, 20))

      state =
        Loop.refine(sample_result(), sample_adapter(),
          llm: Faber.LLM.Stub,
          sidecar: SeqSidecar,
          seq_agent: scores,
          strategy: :reflect,
          patience: 3,
          target: 0.99
        )

      assert state.status == :stuck
      consumed = 20 - length(Agent.get(scores, & &1))
      assert consumed == 4
    end
  end

  describe "run/1 :min_improvement margin" do
    test "a sub-margin gain is rejected; a gain clearing the margin is kept" do
      state =
        Loop.run(
          content: "seed",
          composite: 0.5,
          min_improvement: 0.1,
          patience: 2,
          max_iterations: 2,
          target: 0.99,
          checks_fn: &ok_checks/1,
          propose_fn: &always_propose/1,
          eval_fn: scorer([0.55, 0.65])
        )

      # 0.55 is a real gain but inside the noise margin (0.5 + 0.1) → rejected; 0.65 clears it.
      assert [%{kept: false, reason: "no improvement"}, %{kept: true}] = state.history
      assert state.best_composite == 0.65
    end
  end

  describe "refine/3 :seed (start from an existing proposal)" do
    test "bypasses the initial propose — a dead LLM no longer aborts the run" do
      # Without :seed this exact call is the {:error, :llm_unavailable} case above. With a seed
      # the loop starts anyway; each iteration's re-propose still fails and is discarded.
      state =
        Loop.refine(sample_result(), sample_adapter(),
          seed: honest_seed(),
          llm: FailingLLM,
          patience: 1
        )

      assert %Loop.State{status: :stuck} = state
      assert state.skill == "investigate-retry-loops"
      assert state.best_proposal == honest_seed()
      assert [%{kept: false, description: desc}] = state.history
      assert desc =~ "proposal failed"
    end
  end

  describe "refine/3 trigger: true (behavioral recall in the loop, fixtures pinned)" do
    test "candidates cannot game the objective by rewriting their own fixtures" do
      seed = honest_seed()

      state =
        Loop.refine(sample_result(), sample_adapter(),
          seed: seed,
          llm: GamingLLM,
          trigger: true,
          max_iterations: 3,
          patience: 100,
          target: 0.99
        )

      # The router activates only on "XYZZY". The seed's honest fixtures score behavioral
      # mean(acc 0.5, prec 0.0, rec 0.0) ≈ 0.167; every candidate is content-identical but
      # carries gamed XYZZY fixtures that would score a perfect 1.0 — IF the loop scored
      # candidates on their own fixtures. Pinning grades them on the seed's instead, so they tie
      # the baseline and all are rejected. A single keep here means the guard is broken.
      assert %Loop.State{} = state
      assert Enum.count(state.history, & &1.kept) == 0
      assert Enum.all?(state.history, &(&1.reason == "no improvement"))
      assert state.best_proposal == seed
    end

    test "pin_fixtures/2 grafts the seed's fixtures onto the candidate" do
      seed = honest_seed()
      gamed = %{seed | should_trigger: ["XYZZY"], should_not_trigger: ["nope"]}

      pinned = Loop.pin_fixtures(gamed, seed)
      assert pinned.should_trigger == seed.should_trigger
      assert pinned.should_not_trigger == seed.should_not_trigger
    end

    test "trigger_holdout: true reports the never-optimized validation half (overfit visible)" do
      # Alternating split: index 0 → train, index 1 → validate. The GamingLLM router activates
      # iff the phrase contains XYZZY, so this seed is a PERFECT overfit setup — the train half
      # routes flawlessly (behavioral 1.0), the validation half routes perfectly WRONG (0.0):
      #   train:    should_trigger "XYZZY alpha" (→ true, tp), should_not "gamma plain" (→ false, tn)
      #   validate: should_trigger "beta plain" (→ false, fn), should_not "XYZZY delta" (→ true, fp)
      seed = %{
        honest_seed()
        | should_trigger: ["XYZZY alpha", "beta plain"],
          should_not_trigger: ["gamma plain", "XYZZY delta"]
      }

      state =
        Loop.refine(sample_result(), sample_adapter(),
          seed: seed,
          llm: GamingLLM,
          trigger: true,
          trigger_holdout: true,
          max_iterations: 1,
          patience: 100,
          target: 0.99
        )

      assert %Loop.State{holdout: %{composite: hold, behavioral: behavioral, fixtures: 2}} =
               state

      assert behavioral == 0.0
      # Train-optimized composite (behavioral 1.0 folded) strictly beats the holdout score.
      assert hold < state.best_composite
    end

    test "trigger_holdout with fewer than 2 fixtures per list fails loudly" do
      # honest_seed has 1+1 fixtures — an alternating split would leave a side empty.
      assert {:error, :insufficient_fixtures_for_holdout} =
               Loop.refine(sample_result(), sample_adapter(),
                 seed: honest_seed(),
                 llm: GamingLLM,
                 trigger: true,
                 trigger_holdout: true
               )
    end

    test "a failing holdout eval lands as holdout: %{error: _}, not a crash" do
      seed = %{
        honest_seed()
        | should_trigger: ["XYZZY alpha", "beta plain"],
          should_not_trigger: ["gamma plain", "XYZZY delta"]
      }

      # FailSidecar sinks every Eval.score (candidates reject as "eval failed", and the final
      # holdout validation errors too) — the run must still return a State with the failure
      # recorded on :holdout rather than raising out of attach_holdout.
      state =
        Loop.refine(sample_result(), sample_adapter(),
          seed: seed,
          llm: GamingLLM,
          trigger: true,
          trigger_holdout: true,
          sidecar: FailSidecar,
          max_iterations: 1,
          patience: 100,
          target: 0.99
        )

      assert %Loop.State{holdout: %{error: _}} = state
      assert Enum.all?(state.history, &(&1.reason =~ "eval failed"))
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

    # async_nolink: the run task is crash-isolated, so a loop that raises reaches the server as
    # a DOWN — waiters get {:error, {:crashed, _}} and the server stays queryable instead of
    # dying with the task.
    @tag capture_log: true
    test "a crashing loop settles as :crashed instead of killing the server" do
      pid =
        start_supervised!(
          {Server,
           [
             content: "seed",
             composite: 0.4,
             target: 0.95,
             checks_fn: &ok_checks/1,
             propose_fn: fn _state -> raise "loop body blew up" end,
             eval_fn: scorer([])
           ]}
        )

      assert {:error, {:crashed, {%RuntimeError{message: "loop body blew up"}, _stack}}} =
               Server.await(pid, 5_000)

      assert Server.status(pid) == :crashed
      assert Process.alive?(pid)
    end

    # The wedge guard (mirrors Faber.Schedule): a hung loop is killed at :max_run_ms and
    # recorded, so await/2 callers aren't parked forever behind a wedged subprocess.
    test "a hung loop is killed at :max_run_ms and settles as :timeout" do
      pid =
        start_supervised!(
          {Server,
           [
             content: "seed",
             composite: 0.4,
             target: 0.95,
             max_run_ms: 50,
             checks_fn: &ok_checks/1,
             propose_fn: fn _state -> Process.sleep(:infinity) end,
             eval_fn: scorer([])
           ]}
        )

      assert {:error, :run_timeout} = Server.await(pid, 5_000)
      assert Server.status(pid) == :timeout
      assert Process.alive?(pid)
    end
  end

  defp sample_adapter do
    %Faber.Adapter{name: "faber-elixir", version: "0.1.0", laws: [], playbooks: []}
  end

  # A well-formed seed proposal with HONEST fixtures (none contain the GamingLLM's "XYZZY"
  # activation token), content-identical to the Stub/GamingLLM proposal otherwise.
  defp honest_seed do
    base = Faber.LLM.Stub.default_proposal()

    %Faber.Proposal{
      name: base["name"],
      description: base["description"],
      effort: base["effort"],
      rationale: base["rationale"],
      iron_laws: base["iron_laws"],
      usage: base["usage"],
      example: base["example"],
      should_trigger: ["the same mix command keeps failing"],
      should_not_trigger: ["run the test suite once"]
    }
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
