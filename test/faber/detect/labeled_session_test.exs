defmodule Faber.Detect.LabeledSessionTest do
  @moduledoc """
  **Characterization tests over a labeled fixture.** These pin what `Faber.Detect` reports on
  `test/fixtures_labeled/dogfood_session.jsonl` **today** — including the zeros. They are not
  aspirational. Every other detector test asserts that a signal fires when it should; these assert
  what the detector *misses*, which is the part no amount of testing-the-happy-path can surface.

  Why this fixture is worth having: friction in it is **known because it was lived**, not inferred.
  It encodes four things that actually happened while building the CLI UX work and this plan, and
  the ground-truth-vs-detected delta is written up next to the fixture in `README.md`.

  ## Read this before "fixing" a failing assertion here

  A zero in this file is a **finding**, not a bug in the test. If you change the detector and one
  of these fails, you have changed what Faber can see — which may be exactly right, but it is a
  scoring decision, not a test repair. Update the delta table in the fixture README in the same
  commit, so the baseline and the target keep living in one place.

  See `.claude/research/2026-07-16-friction-score-construct-validity.md` for why the score is
  ~60% length-loaded, and why rescoring was deliberately set aside rather than done here.
  """
  use ExUnit.Case, async: true

  alias Faber.{Detect, Ingest}

  # In its own dir (like `fixtures_dedup` / `fixtures_python`) so the shared `test/fixtures`
  # dir-scans in scan_test / cli_test don't pick it up. They rank and count whatever they find, and
  # this fixture is deliberately high-friction — dropped into the shared tree it ranks #2, adds a
  # fourth project, and breaks two unrelated tests.
  @fixture Path.expand("../../fixtures_labeled/dogfood_session.jsonl", __DIR__)

  setup_all do
    {events, []} = Ingest.parse_file(@fixture)
    %{events: events}
  end

  # The false-green exchange carries `fg-` uuids so it can be isolated and removed without a second
  # fixture drifting out of sync with this one.
  defp only_false_green(events), do: Enum.filter(events, &fg?/1)
  defp without_false_green(events), do: Enum.reject(events, &fg?/1)
  defp fg?(event), do: String.starts_with?(event.raw["uuid"] || "", "fg-")

  describe "ground truth row 1 — the false green (NOT detected)" do
    test "a session whose ONLY event is a real verify failure scores zero friction", %{
      events: events
    } do
      # `mix verify | tail -5; echo $?` reports tail's exit status, not verify's. Verify really
      # exited 8; the pipeline printed 0; the agent believed it and committed. This is the exact
      # shape that produced a false green in the session this fixture is labeled from — and it
      # happened AGAIN while implementing this plan (credo failed, `| grep` swallowed the status).
      #
      # THE POINT OF THIS TEST: every number below is zero. A tool call that lies is, to the
      # detector, indistinguishable from a tool call that works. Do not "fix" these zeros.
      f = events |> only_false_green() |> Detect.friction()

      assert f.signals.retry_loops == 0
      assert f.signals.user_corrections == 0
      assert f.signals.error_tool_ratio == 0.0
      assert f.signals.approach_changes == 0
      assert f.signals.context_compactions == 0
      assert f.signals.interrupted_requests == 0

      assert f.raw == 0.0
      assert f.dominant_signal == nil
      assert f.error_count == 0
      assert f.tool_count == 1
    end

    test "the failing command is on the transcript — the detector just has no signal for it", %{
      events: events
    } do
      # Not a parsing gap. The evidence is right there and readable; nothing consumes it.
      fg = only_false_green(events)
      assert [%{input: %{"command" => cmd}}] = Enum.flat_map(fg, & &1.tool_uses)
      assert cmd == "mix verify | tail -5; echo $?"

      assert [result] = Enum.flat_map(fg, & &1.tool_results)
      refute result.is_error
    end

    test "removing the false green RAISES friction — it does not merely go unnoticed", %{
      events: events
    } do
      # A refinement of the plan's own table, which reads "contributes 0 to all six signals".
      # It contributes 0 *directly*, but `error_tool_ratio` is `error_count / tool_count`, and a
      # successful-looking call still lands in the denominator. So the lie does not just evade the
      # score — it DILUTES it. A session that fails silently looks better than one that fails loudly,
      # and better than the same session with the lie removed.
      with_fg = Detect.friction(events)
      without_fg = events |> without_false_green() |> Detect.friction()

      assert with_fg.error_count == without_fg.error_count
      assert without_fg.signals.error_tool_ratio > with_fg.signals.error_tool_ratio
      assert with_fg.signals.error_tool_ratio == 2 / 14
      assert without_fg.signals.error_tool_ratio == 2 / 13
    end
  end

  describe "ground truth row 2 — the same mistake twice (NOT detected)" do
    test "retry_loops is 0 despite `@attribute` used before definition being hit twice", %{
      events: events
    } do
      # Two failed `mix compile --warnings-as-errors` runs, in two different files, each fixed and
      # re-run. `count_retry_loops/2` needs >= 3 CONSECUTIVE Bash calls with the SAME normalized
      # command — so a mistake repeated across files, with an edit and a format between the hits,
      # is structurally invisible to the highest-weighted signal (3.0).
      #
      # THE POINT OF THIS TEST: repeating yourself is friction. The detector only counts one very
      # specific *shape* of repeating yourself. Do not "fix" this zero.
      f = Detect.friction(events)

      assert f.signals.retry_loops == 0
      assert f.error_count == 2
    end

    test "both failures are visible as errors — they just never form a loop", %{events: events} do
      errors =
        events
        |> Enum.flat_map(& &1.tool_results)
        |> Enum.filter(& &1.is_error)

      assert length(errors) == 2

      # The compile command repeats four times, but never three times *in a row*: `mix format` and
      # `mix test` sit between the hits, so `chunk_by` never sees a run of 3.
      compiles =
        events
        |> Enum.flat_map(& &1.tool_uses)
        |> Enum.filter(&(&1.name == "Bash"))
        |> Enum.map(& &1.input["command"])
        |> Enum.filter(&(&1 == "mix compile --warnings-as-errors"))

      assert length(compiles) == 4
    end

    test "the two failures are the SAME mistake, but nothing downstream can know that", %{
      events: events
    } do
      # `extract_tool_results/1` (ingest/format/claude.ex:200) normalizes a tool result to
      # `%{tool_use_id, is_error}` and DISCARDS its content. So "@format used before it was
      # defined" and "@marker used before it was defined" — the same error, twice, which is what
      # makes it a pattern worth a skill — reach the detector as two indistinguishable `true`s.
      #
      # THE POINT OF THIS TEST: this is the ceiling on every content-based friction signal. A
      # detector cannot cluster errors it cannot read. Recorded as the boundary, not fixed here:
      # retaining error text means putting the user's tool output into Faber's memory, which is a
      # privacy decision (see the `path`-stripping in Faber.Install's provenance), not a patch.
      results = events |> Enum.flat_map(& &1.tool_results) |> Enum.filter(& &1.is_error)

      assert Enum.map(results, &Map.keys/1) == [
               [:is_error, :tool_use_id],
               [:is_error, :tool_use_id]
             ]

      # The text exists on the raw transcript line — the ingest is where it stops.
      raw_errors =
        events
        |> Enum.flat_map(fn e -> List.wrap(e.raw["message"]["content"]) end)
        |> Enum.filter(&(is_map(&1) and &1["is_error"] == true))

      assert length(raw_errors) == 2
      assert Enum.all?(raw_errors, &(&1["content"] =~ "was used before it was defined"))
    end
  end

  describe "ground truth rows 3 and 4 — what IS detected" do
    test "both wrong-verb corrections are caught (row 3, partially detected)", %{events: events} do
      # `/phx:full` on an existing plan, and `--codex` on the wrong command. The detector catches
      # that Oliver pushed back — not what he pushed back ON. It is a correction counter, not a
      # correction classifier, which is why the row is "partially".
      f = Detect.friction(events)
      assert f.signals.user_corrections == 2
    end

    test "the context compaction is caught (row 4)", %{events: events} do
      f = Detect.friction(events)
      assert f.signals.context_compactions == 1
    end
  end

  describe "the whole labeled session, as scored today" do
    test "every signal, pinned", %{events: events} do
      f = Detect.friction(events)

      assert f.signals == %{
               retry_loops: 0,
               user_corrections: 2,
               error_tool_ratio: 2 / 14,
               approach_changes: 0,
               context_compactions: 1,
               interrupted_requests: 0
             }

      assert f.tool_count == 14
      assert f.error_count == 2
      assert f.raw == 6.785714285714286
    end

    test "the score is saturated — the sigmoid cannot tell this session from a much worse one", %{
      events: events
    } do
      # raw 6.79 against a midpoint of 1.5 and k of 3.0 pins the score at ~1.0. Two corrections and
      # one compaction are already enough to max it out, so the four rows above cannot move it and
      # neither could four more. Relevant to any future rescoring: the headroom is not where the
      # dynamic range is.
      f = Detect.friction(events)
      assert_in_delta f.score, 1.0, 1.0e-6
    end

    test "human_turns counts the compaction summary as a human turn", %{events: events} do
      # Three messages Oliver actually typed, plus the compaction summary — which arrives as a
      # `type: "user"` event with neither `isMeta` nor a synthetic marker, so `Event.human_turn?/1`
      # cannot tell it from something he wrote. Pinned because it is load-bearing for the research
      # file's claim that friction correlates with human turns (r=0.799): part of that correlation
      # is compaction summaries, i.e. session length, counting themselves as human effort.
      f = Detect.friction(events)
      assert f.human_turns == 4
    end
  end
end
