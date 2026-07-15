defmodule Faber.DetectCalibrationTest do
  @moduledoc """
  Calibration proof for the 2026-07-15 friction audit, against the **real** session it audited.

  Excluded by default and machine-local: it reads Oliver's own `~/.claude` transcript, which no
  other machine (and no CI runner) has. Run it with:

      mix test --include calibration test/faber/detect_calibration_test.exs

  Why it exists: `test/faber/detect_test.exs` proves the *mechanism* on synthesized fixtures we
  chose. That's necessary but self-confirming — fixtures can encode the same wrong assumption the
  code does. This asserts the *outcome* on 16.5k events of real transcript, against counts a
  3-agent audit established independently by hand. See
  `.claude/research/2026-07-15-faber-scan-propose-verification.md`.
  """
  use ExUnit.Case, async: true

  alias Faber.Detect
  alias Faber.Ingest.Event
  alias Faber.Ingest.Format.Claude

  @moduletag :calibration

  @session Path.expand(
             "~/.claude/projects/-Users-oliverkriska-Projects-faber/" <>
               "31f10cff-3667-4231-9615-a9ac8dc38c05.jsonl"
           )

  setup_all do
    unless File.exists?(@session) do
      raise """
      Calibration transcript not found:

          #{@session}

      This test is opt-in (`--include calibration`) and reads a real local transcript, so it can
      only run on a machine that still has that session. Nothing is wrong with the code — there is
      just no data here to calibrate against.
      """
    end

    events =
      @session
      |> Claude.stream_file!()
      |> Stream.filter(&match?({:ok, _}, &1))
      |> Stream.map(fn {:ok, e} -> e end)
      |> Enum.to_list()

    {:ok, events: events, friction: Detect.friction(events)}
  end

  describe "faber/31f10cff — the audited session" do
    test "user_corrections drops from 30 to the 2 genuine ones", %{friction: f} do
      # The audit hand-classified all 30 regex hits: 27 task-notifications, 1 teammate-message,
      # 2 genuine. Landing exactly on 2 means the stripper is neither under- nor over-firing.
      assert f.signals.user_corrections == 2
    end

    test "retry_loops drops from 7 to 0 — none were genuine", %{friction: f} do
      # All 7 were prefix collisions (`cd …`, `git add …`, `mise exec …`, `echo …`); one grouped
      # 93 distinct commands. This is the highest-weighted signal (3.0).
      assert f.signals.retry_loops == 0
    end

    test "signals the audit verified as real are untouched", %{friction: f} do
      # Guard against over-correction: 37 compactions were confirmed genuine, and the interrupt
      # marker must survive wrapper stripping.
      assert f.signals.context_compactions == 37
      assert f.signals.interrupted_requests == 1
    end

    test "events vs human turns — the 20-70x inflation the msgs column was hiding", %{
      events: events,
      friction: f
    } do
      human_turns = Enum.count(events, &Event.human_turn?/1)

      assert length(events) == 16_572
      # message_count keeps counting events: its gate semantics (t2 > 50, --min-messages, dedupe)
      # are deliberately NOT recalibrated in this plan — only the display gets honest.
      assert f.message_count == 9161
      assert human_turns < 150
      assert f.human_turns == human_turns
    end
  end
end
