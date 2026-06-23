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

      # approach_changes is 0: only 4 tool calls, below the proven scorer's 10-call floor.
      assert f.signals == %{
               retry_loops: 1,
               user_corrections: 1,
               error_tool_ratio: 0.5,
               approach_changes: 0,
               context_compactions: 1,
               interrupted_requests: 1
             }
    end

    test "combines into the proven sigmoid score", %{f: f} do
      # raw = 1*3.0 + 1*2.5 + 0.5*2.0 + 0*2.0 + 1*1.5 + 1*1.0
      assert_in_delta f.raw, 9.0, 1.0e-9
      assert f.score > 0.95
      assert f.dominant_signal == :retry_loops
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

    test "tool_profile/1 counts tidewave tools" do
      events = [asst([{"Bash", %{}}, {"mcp__tidewave__project_eval", %{}}])]
      profile = Detect.tool_profile(events)
      assert_in_delta profile.bash, 0.5, 1.0e-9
      assert_in_delta profile.tidewave, 0.5, 1.0e-9
    end
  end

  describe "fingerprint/1" do
    test "classifies a feature session" do
      events = [
        user("please add and implement a new feature and build it"),
        asst([{"Edit", %{"file_path" => "/a.ex"}}, {"Write", %{"file_path" => "/b.ex"}}])
      ]

      assert %{type: "feature", confidence: c} = Detect.fingerprint(events)
      assert c > 0.0
    end

    test "classifies a bug-fix session (keywords + bash-heavy)" do
      events = [
        user("fix the bug, it has an error and will fail"),
        asst([{"Bash", %{"command" => "mix test"}}, {"Bash", %{"command" => "mix test"}}])
      ]

      assert %{type: "bug-fix"} = Detect.fingerprint(events)
    end

    test "classifies an exploration session (read-heavy, no edits)" do
      events = [
        user("explain how does this work, I want to understand the code"),
        asst([{"Read", %{}}, {"Grep", %{}}, {"Read", %{}}])
      ]

      assert %{type: "exploration"} = Detect.fingerprint(events)
    end

    test "unknown when there are no signals" do
      assert %{type: "unknown", confidence: confidence} = Detect.fingerprint([])
      assert confidence == 0.0
    end

    test "breaks fingerprint ties deterministically by reference type order" do
      # edit_pct and bash_pct both > 0.3 → feature(+2) and bug-fix(+2) tie, with no keywords in
      # the user text. The tie resolves to the earliest type in @fingerprint_order (bug-fix before
      # feature) — deterministic and matching compute-metrics.py, not (unstable) map order.
      events = [
        user("please proceed with the task at hand"),
        asst([{"Edit", %{"file_path" => "/a.ex"}}, {"Bash", %{"command" => "ls"}}]),
        asst([{"Edit", %{"file_path" => "/b.ex"}}, {"Bash", %{"command" => "pwd"}}])
      ]

      assert %{type: "bug-fix", confidence: 0.5} = Detect.fingerprint(events)
    end
  end

  describe "opportunity/1" do
    test "retry loop flags an investigate opportunity" do
      events = [asst(List.duplicate({"Bash", %{"command" => "git status"}}, 3))]
      assert %{missed: missed, score: score} = Detect.opportunity(events)
      assert "investigate" in missed
      assert score >= 0.2
    end

    test "repeated test/compile flags verify (without firing investigate)" do
      events = [
        asst([
          {"Bash", %{"command" => "mix test"}},
          {"Bash", %{"command" => "mix compile"}},
          {"Bash", %{"command" => "mix test"}}
        ])
      ]

      assert %{missed: missed} = Detect.opportunity(events)
      assert "verify" in missed
      refute "investigate" in missed
    end

    test "many edits flag review" do
      tools = for i <- 1..11, do: {"Edit", %{"file_path" => "/f#{i}.ex"}}
      assert %{missed: missed} = Detect.opportunity([asst(tools)])
      assert "review" in missed
    end

    test "many tools flag plan" do
      assert %{missed: missed} = Detect.opportunity([asst(List.duplicate({"Read", %{}}, 51))])
      assert "plan" in missed
    end

    test "already-used skills are excluded" do
      events = [
        user("let me run /phx:verify on this"),
        asst([
          {"Bash", %{"command" => "mix test"}},
          {"Bash", %{"command" => "mix compile"}},
          {"Bash", %{"command" => "mix test"}}
        ])
      ]

      assert %{missed: missed, used: used} = Detect.opportunity(events)
      assert "verify" in used
      refute "verify" in missed
    end

    test "no opportunities yields zero" do
      assert %{score: score, missed: []} = Detect.opportunity([])
      assert score == 0.0
    end
  end

  describe "context/1" do
    test "computes peak context fill from message.usage" do
      events = [
        asst_usage(10_000, 0),
        # prompt = 50_000 + 140_000 = 190_000 → 95% of opus-4-8's 200k window
        asst_usage(50_000, 140_000)
      ]

      assert %{max_ctx_pct: 95.0, primary_model: "claude-opus-4-8"} = Detect.context(events)
    end

    test "nil when there is no usage data" do
      assert %{max_ctx_pct: nil} = Detect.context([user("hello there")])
    end

    test "nil for an unknown model window" do
      event =
        Faber.Ingest.normalize(%{
          "type" => "assistant",
          "message" => %{
            "role" => "assistant",
            "model" => "some-future-model-v9",
            "usage" => %{"input_tokens" => 190_000}
          }
        })

      assert %{max_ctx_pct: nil} = Detect.context([event])
    end
  end

  defp asst_usage(input, cache_read) do
    Faber.Ingest.normalize(%{
      "type" => "assistant",
      "message" => %{
        "role" => "assistant",
        "model" => "claude-opus-4-8",
        "usage" => %{
          "input_tokens" => input,
          "cache_creation_input_tokens" => 0,
          "cache_read_input_tokens" => cache_read
        },
        "content" => []
      }
    })
  end

  defp user(text) do
    Faber.Ingest.normalize(%{
      "type" => "user",
      "message" => %{"role" => "user", "content" => text}
    })
  end

  defp asst(tools) do
    content =
      Enum.map(tools, fn {name, input} ->
        %{"type" => "tool_use", "name" => name, "input" => input, "id" => name}
      end)

    Faber.Ingest.normalize(%{
      "type" => "assistant",
      "message" => %{"role" => "assistant", "content" => content}
    })
  end
end
