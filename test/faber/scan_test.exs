defmodule Faber.ScanTest do
  use ExUnit.Case, async: true

  alias Faber.Scan
  alias Faber.Scan.Result

  @fixtures Path.expand("../fixtures", __DIR__)
  @dedup_fixtures Path.expand("../fixtures_dedup", __DIR__)

  describe "run/1" do
    test "ranks sessions by friction, highest first" do
      results = Scan.run(base: @fixtures, min_messages: 0)

      assert Enum.all?(results, &match?(%Result{}, &1))
      assert [top | _] = results
      assert top.path =~ "sample_session"

      # Ranking is by raw weighted friction (the score saturates on long sessions).
      raws = Enum.map(results, & &1.raw)
      assert raws == Enum.sort(raws, :desc)

      sample = Enum.find(results, &(&1.path =~ "sample_session"))
      smooth = Enum.find(results, &(&1.path =~ "smooth_session"))
      assert sample.friction > smooth.friction
      assert sample.tier2
      refute smooth.tier2
      assert sample.dominant_signal == :retry_loops
    end

    test "results carry fingerprint and opportunity fields" do
      results = Scan.run(base: @fixtures, min_messages: 0)
      sample = Enum.find(results, &(&1.path =~ "sample_session"))

      assert is_binary(sample.fingerprint)
      assert is_float(sample.fingerprint_confidence)
      assert is_float(sample.opportunity)
      assert is_list(sample.missed)
      assert is_list(sample.skills_used)
    end

    test "carries a friction rate and can rank by it" do
      results = Scan.run(base: @fixtures, min_messages: 0)
      sample = Enum.find(results, &(&1.path =~ "sample_session"))
      assert sample.rate == sample.raw / sample.message_count

      by_rate = Scan.run(base: @fixtures, min_messages: 0, rank_by: :rate)
      rates = Enum.map(by_rate, & &1.rate)
      assert rates == Enum.sort(rates, :desc)
    end

    test "tier2 fires when opportunity is high even if friction is low" do
      smooth = Enum.find(Scan.run(base: @fixtures, min_messages: 0), &(&1.path =~ "smooth"))
      # A smooth session is tier-2 iff one of the non-friction gates trips.
      assert smooth.tier2 == (smooth.opportunity > 0.5 or smooth.skills_used != [])
    end

    test "dedupe collapses sidechain rows sharing a session_id (default on)" do
      results = Scan.run(base: @dedup_fixtures, min_messages: 0)

      assert length(results) == 1
      [row] = results
      assert row.session_id == "dup"
      # The richest member (the parent, more messages) wins.
      assert row.path =~ "parent"
      assert row.message_count == 4
    end

    test "dedupe: false keeps every sidechain row" do
      results = Scan.run(base: @dedup_fixtures, min_messages: 0, dedupe: false)

      assert length(results) == 2
      assert Enum.all?(results, &(&1.session_id == "dup"))
    end

    test "min_messages drops trivial sessions" do
      results = Scan.run(base: @fixtures, min_messages: 5)
      paths = Enum.map(results, & &1.path)

      assert Enum.any?(paths, &(&1 =~ "sample_session"))
      refute Enum.any?(paths, &(&1 =~ "smooth_session"))
    end

    test "limit caps how many sessions are scored" do
      assert length(Scan.run(base: @fixtures, min_messages: 0, limit: 1)) == 1
    end

    test "tier2 fires on high context pressure alone" do
      dir = Path.join(System.tmp_dir!(), "faber_ctx_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      # One low-friction assistant turn whose prompt fills 95% of the opus-4-8 window.
      File.write!(
        Path.join(dir, "ctx.jsonl"),
        ~s({"type":"assistant","sessionId":"ctx","message":{"role":"assistant","model":"claude-opus-4-8","usage":{"input_tokens":190000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"content":[]}}\n)
      )

      assert [%Result{max_ctx_pct: 95.0, tier2: true}] = Scan.run(base: dir, min_messages: 0)
    end

    test "limit samples an even spread, not the alphabetical prefix" do
      dir = Path.join(System.tmp_dir!(), "faber_spread_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      # Six sorted sessions aa..ff, each a single valid user turn so it scores.
      for name <- ~w(aa bb cc dd ee ff) do
        File.write!(
          Path.join(dir, "#{name}.jsonl"),
          ~s({"type":"user","sessionId":"#{name}","message":{"role":"user","content":"hi #{name}"}}\n)
        )
      end

      basenames =
        [base: dir, min_messages: 0, limit: 3]
        |> Scan.run()
        |> Enum.map(&Path.basename(&1.path))

      assert length(basenames) == 3
      # A prefix-take would yield aa,bb,cc — assert a later-sorted session made the cut instead.
      assert Enum.any?(basenames, &(&1 in ["dd.jsonl", "ee.jsonl", "ff.jsonl"]))
    end

    @tag :tmp_dir
    test "the spread holds for a limit larger than half the corpus", %{tmp_dir: dir} do
      # The half of the domain the step-based sampler quietly abandoned. With `take_every(step)`,
      # `step = div(count, limit)` floors to 1 for every `limit > count / 2` — so `take_every(1)`
      # keeps everything and `take(limit)` returns the alphabetical prefix the spread exists to
      # avoid. Ten sessions and `--limit 6` sits in that half; the real-world shape is the GUIDE's
      # own `faber scan --limit 200` over a ~250-session corpus, silently dropping the last 50.
      names = ~w(aa bb cc dd ee ff gg hh ii jj)

      for name <- names do
        File.write!(
          Path.join(dir, "#{name}.jsonl"),
          ~s({"type":"user","sessionId":"#{name}","message":{"role":"user","content":"hi #{name}"}}\n)
        )
      end

      basenames =
        [base: dir, min_messages: 0, limit: 6, cache: false]
        |> Scan.run()
        |> Enum.map(&Path.basename(&1.path))

      assert length(basenames) == 6

      refute basenames |> Enum.sort() == Enum.map(~w(aa bb cc dd ee ff), &"#{&1}.jsonl"),
             "--limit 6 of 10 returned the alphabetical prefix, not a spread"

      # The point of a spread: it must reach the far end of the corpus, not stop two-thirds in.
      assert Enum.any?(basenames, &(&1 in ["ii.jsonl", "jj.jsonl"])),
             "the sample never reached the last-sorted sessions"
    end

    @tag :tmp_dir
    test "a limit at or above the corpus size keeps every session", %{tmp_dir: dir} do
      for name <- ~w(aa bb cc) do
        File.write!(
          Path.join(dir, "#{name}.jsonl"),
          ~s({"type":"user","sessionId":"#{name}","message":{"role":"user","content":"hi"}}\n)
        )
      end

      for limit <- [3, 4, 99] do
        assert [base: dir, min_messages: 0, limit: limit, cache: false] |> Scan.run() |> length() ==
                 3,
               "limit #{limit} over 3 sessions must keep all 3"
      end
    end
  end

  describe "score_session/1" do
    test "is resilient to malformed lines" do
      result = Scan.score_session(Path.join(@fixtures, "malformed_session.jsonl"))
      assert %Result{} = result
      assert result.parse_errors == 1
    end

    @tag :tmp_dir
    test "handles an empty (0-byte) transcript", %{tmp_dir: dir} do
      path = Path.join(dir, "empty.jsonl")
      File.write!(path, "")

      result = Scan.score_session(path)
      assert %Result{} = result
      assert result.message_count == 0
      assert result.parse_errors == 0
      assert result.hazards == []
    end

    test "surfaces frictionless hazards, deduped by class, without touching the ranking" do
      # The labeled fixture carries the lived `mix verify | tail -5; echo $?` false green. It is
      # selectable for a hook proposal from here (`faber propose --hazard pipe_masks_exit`) while
      # contributing nothing to `friction`/`raw` — the two halves of the Phase B contract.
      labeled = Path.expand("../fixtures_labeled/dogfood_session.jsonl", __DIR__)

      result = Scan.score_session(labeled, cache: false)

      assert [%{kind: :pipe_masks_exit, count: 1} = hazard] = result.hazards
      assert hazard.suggested_event == "PreToolUse"
      assert hazard.evidence =~ "mix verify | tail -5; echo $?"

      # Unchanged by the hazard's presence — the numbers labeled_session_test pins.
      assert result.raw == 6.785714285714286
      assert result.dominant_signal == :user_corrections
    end
  end
end
