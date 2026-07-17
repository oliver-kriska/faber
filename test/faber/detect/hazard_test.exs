defmodule Faber.Detect.HazardTest do
  @moduledoc """
  Tests for the frictionless-hazard detector.

  The centerpiece is the labeled fixture: `test/fixtures_labeled/dogfood_session.jsonl` carries the
  real `mix verify | tail -5; echo $?` false green that
  `Faber.Detect.LabeledSessionTest` pins at **zero friction on every signal**. That zero is the
  reason this detector exists, so the test that matters most asserts both halves at once — the
  hazard is now seen, and seeing it did not move the friction score by even a float's width.
  """
  use ExUnit.Case, async: true

  alias Faber.Detect
  alias Faber.Detect.Hazard
  alias Faber.Ingest

  @fixture Path.expand("../../fixtures_labeled/dogfood_session.jsonl", __DIR__)

  # The minimum shape `Hazard.hazards/2` reads off a tool call.
  defp bash(command), do: %{name: "Bash", input: %{"command" => command}, id: "t1"}

  defp hazards_for(command), do: Hazard.hazards([], [bash(command)])

  describe "the labeled fixture — the false green this detector exists for" do
    setup do
      {events, []} = Ingest.parse_file(@fixture)
      %{events: events}
    end

    test "the exact lived false-green command is detected as a pipe_masks_exit hazard", %{
      events: events
    } do
      # `mix verify | tail -5; echo $?` printed 0 while verify really exited 8. Every friction
      # signal reads zero on it (labeled_session_test.exs, "ground truth row 1"). This is the
      # assertion that row 1 of the fixture README's delta table is no longer "Detected? No".
      assert [hazard] = Detect.hazards(events)

      assert hazard.kind == :pipe_masks_exit
      assert hazard.tool_use.input["command"] == "mix verify | tail -5; echo $?"
      assert hazard.evidence =~ "mix verify | tail -5; echo $?"
      assert hazard.evidence =~ "reports the filter's exit code"
      # The aggravator fired: this command doesn't just mask the status, it then reads it.
      assert hazard.evidence =~ "belongs to the filter, not the gate"

      # The hook this hazard implies — the settings.json pointer shape (PreToolUse, because a
      # PostToolUse hook cannot see a successful command's exit code).
      assert hazard.suggested_event == "PreToolUse"
      assert hazard.matcher == "Bash"
    end

    test "detecting the hazard contributes NOTHING to the friction score", %{events: events} do
      # The separation the plan's self-check demands. These are the exact numbers
      # labeled_session_test.exs pins; if a hazard ever leaks into the score, they move.
      analysis = Detect.analyze(events)

      assert length(analysis.hazards) == 1

      assert analysis.friction.signals == %{
               retry_loops: 0,
               user_corrections: 2,
               error_tool_ratio: 2 / 14,
               approach_changes: 0,
               context_compactions: 1,
               interrupted_requests: 0
             }

      assert analysis.friction.raw == 6.785714285714286
      assert analysis.friction.dominant_signal == :user_corrections
      refute Map.has_key?(analysis.friction, :hazards)
      refute Map.has_key?(analysis.friction.signals, :pipe_masks_exit)
    end

    test "a zero-friction session with one hazard still surfaces it", %{events: events} do
      # The load-bearing case: isolate JUST the false-green exchange (the `fg-` uuids). Friction is
      # 0.0 across the board — a session Faber's ranking cannot see at all — and the hazard is
      # still reported. If hazards were a friction signal, this session would have had to score
      # >0 to be visible, which would have made the lie *raise* the score it currently dilutes.
      fg = Enum.filter(events, &String.starts_with?(&1.raw["uuid"] || "", "fg-"))

      analysis = Detect.analyze(fg)

      assert analysis.friction.raw == 0.0
      assert analysis.friction.dominant_signal == nil
      assert [%{kind: :pipe_masks_exit}] = analysis.hazards
    end
  end

  describe "pipe_masks_exit — what fires" do
    test "the gate commands whose exit code is the point" do
      for cmd <- [
            "mix verify | tail -5; echo $?",
            "mix test | grep -c test",
            "mix test.full | tail -20",
            "mix credo --strict | head",
            "make verify | tee /tmp/log",
            "npm test | tail",
            "pytest | grep FAILED",
            "cargo test | tail -3",
            "go test ./... | grep -v ok",
            "bundle exec rspec | tail -5"
          ] do
        assert [%{kind: :pipe_masks_exit}] = hazards_for(cmd), "expected a hazard for: #{cmd}"
      end
    end

    test "a bare masked pipeline fires even without a status read" do
      # The pipeline itself is the lie: Bash reports tail's exit, so the transcript records
      # `is_error: false` and the whole detector chain downstream believes it. Reading `$?` is an
      # aggravator, not the trigger.
      assert [hazard] = hazards_for("mix verify | tail -5")
      assert hazard.kind == :pipe_masks_exit
      refute hazard.evidence =~ "belongs to the filter, not the gate"
    end

    test "PIPESTATUS counts as a status read, not as a fix" do
      # Deliberate: PIPESTATUS is bash-only and Oliver's shell is zsh (lowercase `pipestatus`), so
      # `${PIPESTATUS[0]}` expands to nothing and the check silently passes. This is documented in
      # the faber-verify-exit-code-false-green memory as a lived failure, not a theory.
      assert [hazard] = hazards_for("mix verify | tail -5; echo ${PIPESTATUS[0]}")
      assert hazard.evidence =~ "belongs to the filter, not the gate"
    end

    test "evidence quotes the command and stays bounded" do
      long = "mix test " <> String.duplicate("--include foo ", 40) <> "| tail"
      assert [hazard] = hazards_for(long)
      assert String.length(hazard.evidence) < 400
      assert hazard.evidence =~ "…"
    end
  end

  describe "pipe_masks_exit — what does NOT fire (precision)" do
    test "the correct form — redirect to a log, then read the real status — is not a hazard" do
      # This is the fix the project mandates. If the detector flagged it, the hook it proposes
      # would fire on the very command that avoids the bug.
      assert hazards_for("mix verify > /tmp/verify.log 2>&1; echo $?") == []

      assert hazards_for("mix verify > /tmp/verify.log 2>&1; echo $?; grep -c error /tmp/v.log") ==
               []
    end

    test "pipefail makes the pipeline honest, so it is not a hazard" do
      assert hazards_for("set -o pipefail; mix verify | tail -5; echo $?") == []
      assert hazards_for("set -eo pipefail && mix test | grep -v skip") == []
    end

    test "piping a non-gate command is normal work, not a hazard" do
      # Nobody runs `git log` for its exit code. Firing here would make the detector noise —
      # the precision lesson `count_retry_loops/2` already paid for.
      for cmd <- [
            "git log --oneline | head -5",
            "ls -la | grep faber",
            "cat mix.exs | head -20",
            "ps aux | grep beam",
            "git status --short | wc -l"
          ] do
        assert hazards_for(cmd) == [], "expected NO hazard for: #{cmd}"
      end
    end

    test "a gate command whose status is not piped away is not a hazard" do
      assert hazards_for("mix verify") == []
      assert hazards_for("mix test --include sidecar") == []
    end

    test "a gate in one command and an unrelated pipe in another do not combine" do
      # The `[^|;&\n]*` fence: without it the regex would leap the `;` and call this a hazard,
      # which is exactly the redirect-then-inspect form the project recommends.
      assert hazards_for("mix verify > /tmp/log 2>&1; echo $?; git log | head") == []
    end

    test "non-Bash tools and malformed inputs are ignored, not crashed on" do
      assert Hazard.hazards([], [%{name: "Read", input: %{"command" => "mix verify | tail"}}]) ==
               []

      assert Hazard.hazards([], [%{name: "Bash", input: %{}}]) == []
      assert Hazard.hazards([], [%{name: "Bash", input: %{"command" => nil}}]) == []
      assert Hazard.hazards([], [%{name: "Bash", input: %{"command" => 42}}]) == []
      assert Hazard.hazards([], [%{name: "Bash"}]) == []
    end
  end

  describe "summarize/1 — the shape a scan result carries" do
    test "N occurrences of one class collapse to ONE entry, because they imply ONE hook" do
      # The 1:1 hazard→hook mapping taken literally: five masked pipelines do not want five hooks.
      hazards =
        Hazard.hazards([], [
          bash("mix verify | tail -5; echo $?"),
          bash("mix test | grep -c ok"),
          bash("mix credo --strict | head -3")
        ])

      assert length(hazards) == 3

      assert [summary] = Hazard.summarize(hazards)
      assert summary.kind == :pipe_masks_exit
      assert summary.count == 3
      assert summary.suggested_event == "PreToolUse"
      assert summary.matcher == "Bash"
      # Evidence comes from the first occurrence — a concrete command, not a generic label.
      assert summary.evidence =~ "mix verify | tail -5; echo $?"
    end

    test "the raw tool_use is dropped — Result is persisted to disk" do
      # `Faber.Scan.Cache` snapshots Results with `term_to_binary`. A raw Bash input map is the
      # user's own shell history; `evidence` already carries what a hook proposal needs.
      assert [summary] = Hazard.summarize(Hazard.hazards([], [bash("mix verify | tail")]))
      refute Map.has_key?(summary, :tool_use)

      assert summary |> Map.keys() |> Enum.sort() ==
               [:count, :evidence, :kind, :matcher, :suggested_event]
    end

    test "an empty list summarizes to an empty list" do
      assert Hazard.summarize([]) == []
    end
  end

  describe "honest coverage" do
    test "known_kinds/0 names exactly what this detector can see" do
      # Guards the over-claim the plan warns about: "we detect false greens" must not outrun
      # "we detect one shape of one false green". A new class here is a deliberate act.
      assert Hazard.known_kinds() == [:pipe_masks_exit]
    end
  end
end
