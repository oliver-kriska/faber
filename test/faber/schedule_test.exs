defmodule Faber.ScheduleTest do
  # Not async: starts named-but-unique GenServers and exercises timers.
  use ExUnit.Case, async: false

  alias Faber.Schedule

  @fixtures [base: "test/fixtures", min_messages: 0]

  # LLM doubles that crash the pipeline run, to exercise the scheduler's isolation guarantees.
  # They run inside the scheduler's async_nolink Task (run_once → Propose → LLM), so they crash
  # the Task, not the scheduler.
  defmodule KillLLM do
    @behaviour Faber.LLM
    @impl true
    # Untrappable kill → bypasses start_job's try/rescue → arrives as a :DOWN at the scheduler.
    def generate_object(_prompt, _schema, _opts), do: Process.exit(self(), :kill)
  end

  defmodule RaiseLLM do
    @behaviour Faber.LLM
    @impl true
    # A plain raise → caught by start_job's try/rescue → folded into a clean error summary.
    def generate_object(_prompt, _schema, _opts), do: raise("boom in the LLM")
  end

  defmodule HangLLM do
    @behaviour Faber.LLM
    @impl true
    # Never returns → the run outlives :max_run_ms and must be killed by the wedge guard.
    def generate_object(_prompt, _schema, _opts), do: Process.sleep(:infinity)
  end

  defmodule GateLLM do
    @behaviour Faber.LLM
    @impl true
    # Parks until the test releases it, then behaves like the Stub — lets a test freeze a run
    # mid-flight to orchestrate message-ordering races deterministically.
    def generate_object(prompt, schema, opts) do
      send(:faber_schedule_gate_test, {:job_running, self()})

      receive do
        :go -> Faber.LLM.Stub.generate_object(prompt, schema, opts)
      end
    end
  end

  describe "run_once/1 (pure pipeline driver)" do
    test "scans, proposes, and evals the top sessions (hermetic: stub LLM, native eval)" do
      summary = Schedule.run_once(top: 1, scan: @fixtures, adapter_dir: "adapters/faber-elixir")

      assert summary.scanned == 1
      assert [proposal] = summary.proposals
      assert is_binary(proposal.name)
      assert is_float(proposal.composite)
      assert is_boolean(proposal.passed)
      # install: false by default — nothing is written.
      assert proposal.installed == false
    end

    test "installs passing skills into :dir when install: true", %{} do
      dir = Path.join(System.tmp_dir!(), "faber-sched-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(dir) end)

      summary =
        Schedule.run_once(
          top: 1,
          scan: @fixtures,
          adapter_dir: "adapters/faber-elixir",
          install: true,
          dir: dir,
          # Force a pass so the install branch is exercised deterministically.
          threshold: 0.0
        )

      assert [proposal] = summary.proposals
      assert proposal.passed
      assert proposal.installed
      assert File.exists?(Path.join([dir, proposal.name, "SKILL.md"]))
    end

    test "reports an adapter load failure without crashing" do
      assert %{scanned: 0, proposals: [], error: _} =
               Schedule.run_once(adapter_dir: "nope/missing")
    end
  end

  describe "GenServer lifecycle" do
    test "starts inert when disabled — no timer, no runs" do
      pid = start_supervised!({Schedule, name: nil, enabled: false})
      assert %{enabled: false, running: false, runs: 0} = Schedule.status(pid)
    end

    test "fires a run on the initial delay and reschedules" do
      pid =
        start_supervised!(
          {Schedule,
           name: nil,
           enabled: true,
           initial_delay_ms: 10,
           every_ms: 3_600_000,
           notify: self(),
           top: 1,
           scan: @fixtures,
           adapter_dir: "adapters/faber-elixir"}
        )

      # Deterministic: the scheduler messages us when a run completes (no polling/sleep).
      assert_receive {:faber_schedule, :run_complete, summary}, 2_000
      assert summary.scanned == 1
      assert Schedule.status(pid).runs == 1
    end

    test "run_now triggers an immediate run even when disabled" do
      pid =
        start_supervised!(
          {Schedule,
           name: nil,
           enabled: false,
           notify: self(),
           top: 1,
           scan: @fixtures,
           adapter_dir: "adapters/faber-elixir"}
        )

      Schedule.run_now(pid)

      assert_receive {:faber_schedule, :run_complete, summary}, 2_000
      assert summary.scanned == 1
      # Disabled: a run_now fires once but does NOT arm a recurring timer.
      assert Schedule.status(pid).runs == 1
    end

    test "exposes last_summary and every_ms in status after a run" do
      pid =
        start_supervised!(
          {Schedule,
           name: nil,
           enabled: false,
           notify: self(),
           every_ms: 123_456,
           top: 1,
           scan: @fixtures,
           adapter_dir: "adapters/faber-elixir"}
        )

      Schedule.run_now(pid)
      assert_receive {:faber_schedule, :run_complete, _summary}, 2_000

      status = Schedule.status(pid)
      assert status.every_ms == 123_456
      assert status.last_summary.scanned == 1
    end
  end

  describe "reliability guarantees" do
    # The scheduler promises "a run never overlaps the previous one". Force the in-flight flag with
    # :sys.replace_state (no real job needed) and prove both trigger paths refuse to start a second.
    test "a tick while a run is in flight is skipped, not overlapped" do
      pid =
        start_supervised!({
          Schedule,
          # Large delays so the only :tick is the one we send by hand.
          name: nil,
          enabled: true,
          initial_delay_ms: 3_600_000,
          every_ms: 3_600_000,
          notify: self(),
          top: 1,
          scan: @fixtures,
          adapter_dir: "adapters/faber-elixir"
        })

      :sys.replace_state(pid, fn s -> %{s | running: true} end)
      send(pid, :tick)

      refute_receive {:faber_schedule, :run_complete, _}, 300
      status = Schedule.status(pid)
      assert status.running == true
      assert status.runs == 0
    end

    test "run_now while a run is in flight is ignored, not overlapped" do
      pid =
        start_supervised!(
          {Schedule,
           name: nil,
           enabled: false,
           notify: self(),
           top: 1,
           scan: @fixtures,
           adapter_dir: "adapters/faber-elixir"}
        )

      :sys.replace_state(pid, fn s -> %{s | running: true} end)
      Schedule.run_now(pid)

      refute_receive {:faber_schedule, :run_complete, _}, 300
      assert Schedule.status(pid).runs == 0
    end

    # Wedge guard: a run that never finishes (hung subprocess) must be killed at :max_run_ms and
    # recorded as a failed run — otherwise `running: true` sticks forever and every future tick is
    # silently skipped (the scheduler stops doing anything, with no crash and no log).
    @tag capture_log: true
    test "a hung run is killed at max_run_ms; the scheduler recovers and can run again" do
      pid =
        start_supervised!(
          {Schedule,
           name: nil,
           enabled: false,
           max_run_ms: 200,
           notify: self(),
           top: 1,
           scan: @fixtures,
           adapter_dir: "adapters/faber-elixir",
           llm: HangLLM}
        )

      Schedule.run_now(pid)

      assert_receive {:faber_schedule, :run_complete, summary}, 2_000
      assert summary.error == :run_timeout
      assert Process.alive?(pid)

      status = Schedule.status(pid)
      assert status.running == false
      assert status.runs == 1

      # Not wedged: a follow-up run starts (and is itself killed at the deadline).
      Schedule.run_now(pid)
      assert_receive {:faber_schedule, :run_complete, _}, 2_000
      assert Schedule.status(pid).runs == 2
    end

    test "a deadline for an already-completed run is ignored (stale ref)" do
      pid =
        start_supervised!(
          {Schedule,
           name: nil,
           enabled: false,
           notify: self(),
           top: 1,
           scan: @fixtures,
           adapter_dir: "adapters/faber-elixir"}
        )

      send(pid, {:run_deadline, make_ref()})

      # The status call is processed after the stale deadline — the scheduler ignored it.
      assert %{running: false, runs: 0} = Schedule.status(pid)
      assert Process.alive?(pid)
    end

    # The deadline can RACE a just-finishing run: the timer message is enqueued, then the task
    # completes, so its {ref, summary} reply sits in the mailbox behind the deadline.
    # Task.shutdown's selective receive must hand back the real summary — the run counts as a
    # normal completion, not a :run_timeout.
    test "a deadline racing a just-finished run records the real summary, not a timeout" do
      Process.register(self(), :faber_schedule_gate_test)

      pid =
        start_supervised!(
          {Schedule,
           name: nil,
           enabled: false,
           notify: self(),
           top: 1,
           scan: @fixtures,
           adapter_dir: "adapters/faber-elixir",
           llm: GateLLM}
        )

      Schedule.run_now(pid)
      assert_receive {:job_running, job}, 2_000

      %{task: %Task{ref: ref, pid: task_pid}} = :sys.get_state(pid)
      mon = Process.monitor(task_pid)

      # Freeze the scheduler, enqueue the deadline FIRST, then let the job finish — its reply
      # lands behind the deadline, reproducing the race.
      :ok = :sys.suspend(pid)
      send(pid, {:run_deadline, ref})
      send(job, :go)
      assert_receive {:DOWN, ^mon, :process, ^task_pid, :normal}, 2_000
      :ok = :sys.resume(pid)

      assert_receive {:faber_schedule, :run_complete, summary}, 2_000
      refute match?(%{error: :run_timeout}, summary)
      assert summary.scanned == 1
      assert %{running: false, runs: 1} = Schedule.status(pid)
    end

    # async_nolink isolation: a job that hard-crashes must NOT take down the scheduler — it lands as
    # a :DOWN, is recorded as a failed run, and the scheduler keeps serving.
    @tag capture_log: true
    test "a hard-crashing job is isolated: recorded as :job_crashed, scheduler survives" do
      pid =
        start_supervised!(
          {Schedule,
           name: nil,
           enabled: false,
           notify: self(),
           top: 1,
           scan: @fixtures,
           adapter_dir: "adapters/faber-elixir",
           llm: KillLLM}
        )

      Schedule.run_now(pid)

      assert_receive {:faber_schedule, :run_complete, summary}, 2_000
      assert match?(%{error: {:job_crashed, _}}, summary)
      assert Process.alive?(pid)
      assert Schedule.status(pid).runs == 1
    end

    test "a raising job is caught and folded into a clean error summary" do
      pid =
        start_supervised!(
          {Schedule,
           name: nil,
           enabled: false,
           notify: self(),
           top: 1,
           scan: @fixtures,
           adapter_dir: "adapters/faber-elixir",
           llm: RaiseLLM}
        )

      Schedule.run_now(pid)

      assert_receive {:faber_schedule, :run_complete, summary}, 2_000
      assert is_binary(summary.error) and summary.error =~ "boom"
      assert Process.alive?(pid)
      assert Schedule.status(pid).runs == 1
    end
  end
end
