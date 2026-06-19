defmodule Faber.ScheduleTest do
  # Not async: starts named-but-unique GenServers and exercises timers.
  use ExUnit.Case, async: false

  alias Faber.Schedule

  @fixtures [base: "test/fixtures", min_messages: 0]

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
  end
end
