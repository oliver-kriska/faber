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
  end

  describe "score_session/1" do
    test "is resilient to malformed lines" do
      result = Scan.score_session(Path.join(@fixtures, "malformed_session.jsonl"))
      assert %Result{} = result
      assert result.parse_errors == 1
    end
  end
end
