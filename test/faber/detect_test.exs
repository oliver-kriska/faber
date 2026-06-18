defmodule Faber.DetectTest do
  use ExUnit.Case, async: true

  alias Faber.{Detect, Ingest}

  @fixtures Path.expand("../fixtures", __DIR__)

  defp load(name) do
    {events, []} = Ingest.parse_file(Path.join(@fixtures, name))
    events
  end

  describe "friction/1 on a high-friction session" do
    setup do
      %{f: Detect.friction(load("sample_session.jsonl"))}
    end

    test "counts each signal deterministically", %{f: f} do
      assert f.tool_count == 4
      assert f.error_count == 2
      assert f.message_count == 11

      assert f.signals == %{
               retry_loops: 1,
               user_corrections: 1,
               error_tool_ratio: 0.5,
               approach_changes: 1,
               context_compactions: 1,
               interrupted_requests: 1
             }
    end

    test "combines into the proven sigmoid score", %{f: f} do
      assert_in_delta f.raw, 11.0, 1.0e-9
      assert f.score > 0.95
    end
  end

  describe "friction/1 on a smooth session" do
    setup do
      %{f: Detect.friction(load("smooth_session.jsonl"))}
    end

    test "reports near-zero friction", %{f: f} do
      assert f.signals.retry_loops == 0
      assert f.signals.user_corrections == 0
      assert f.signals.error_tool_ratio == 0.0
      assert f.raw == 0.0
      assert f.score < 0.15
    end
  end

  describe "edge cases" do
    test "empty session is well-defined" do
      f = Detect.friction([])
      assert f.tool_count == 0
      assert f.signals.error_tool_ratio == 0.0
      assert f.message_count == 0
    end

    test "tool_profile/1 categorizes tool usage" do
      profile = Detect.tool_profile(load("sample_session.jsonl"))
      # 3 Bash + 1 Read out of 4 tool calls
      assert_in_delta profile.bash, 0.75, 1.0e-9
      assert_in_delta profile.read, 0.25, 1.0e-9
      assert profile.edit == 0.0
    end
  end
end
