defmodule Faber.ScanTest do
  use ExUnit.Case, async: true

  alias Faber.Scan
  alias Faber.Scan.Result

  @fixtures Path.expand("../fixtures", __DIR__)

  describe "run/1" do
    test "ranks sessions by friction, highest first" do
      results = Scan.run(base: @fixtures, min_messages: 0)

      assert Enum.all?(results, &match?(%Result{}, &1))
      assert [top | _] = results
      assert top.path =~ "sample_session"

      frictions = Enum.map(results, & &1.friction)
      assert frictions == Enum.sort(frictions, :desc)

      sample = Enum.find(results, &(&1.path =~ "sample_session"))
      smooth = Enum.find(results, &(&1.path =~ "smooth_session"))
      assert sample.friction > smooth.friction
      assert sample.tier2
      refute smooth.tier2
      assert sample.dominant_signal == :retry_loops
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
