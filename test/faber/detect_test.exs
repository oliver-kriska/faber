defmodule Faber.DetectTest do
  use ExUnit.Case, async: true

  alias Faber.{Adapter, Detect, Ingest}

  @fixtures Path.expand("../fixtures", __DIR__)
  @reference_adapter Path.expand("../../adapters/faber-elixir", __DIR__)

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

  # P0-T4: with an adapter, the detection vocab comes from the adapter (contract §4.1), not the
  # engine's built-in Elixir/plugin defaults. The default (arity-1) path is covered above.
  describe "adapter-driven detection vocab (contract §4.1)" do
    test "fingerprint command-bonuses come from the adapter, not the engine default" do
      adapter = %Adapter{
        fingerprint_rules: [%{type: "maintenance", commands: ["pip install"], bonus: 3.0}]
      }

      # `pip install` (python) fires the adapter's maintenance bonus...
      events = [user("proceed"), asst([{"Bash", %{"command" => "pip install requests"}}])]
      assert %{type: "maintenance"} = Detect.fingerprint(events, adapter)

      # ...and the engine's default `mix deps → maintenance` rule is NOT in play under this
      # adapter: adapter-free it classifies as maintenance, but the python adapter has no such
      # rule, so only the generic bash-heavy `bug-fix` bonus remains.
      mix = [user("proceed"), asst([{"Bash", %{"command" => "mix deps.get"}}])]
      assert %{type: "maintenance"} = Detect.fingerprint(mix)
      assert %{type: "bug-fix"} = Detect.fingerprint(mix, adapter)
    end

    test "fingerprint can select an adapter-introduced novel type" do
      adapter = %Adapter{
        fingerprint_rules: [%{type: "data-migration", commands: ["alembic"], bonus: 5.0}]
      }

      events = [user("proceed"), asst([{"Bash", %{"command" => "alembic upgrade head"}}])]
      assert %{type: "data-migration", confidence: c} = Detect.fingerprint(events, adapter)
      assert c > 0.0
    end

    test "opportunity rules come from the adapter, not the engine default" do
      adapter = %Adapter{
        opportunity_rules: [
          %{skill: "py-verify", when: :commands, commands: ["pytest"], threshold: 3}
        ]
      }

      pytest = [asst(List.duplicate({"Bash", %{"command" => "pytest -x"}}, 3))]
      assert %{missed: missed} = Detect.opportunity(pytest, adapter)
      assert "py-verify" in missed

      # The engine's default `mix test → verify` rule does NOT fire under this adapter.
      mix = [asst(List.duplicate({"Bash", %{"command" => "mix test"}}, 3))]
      assert %{missed: []} = Detect.opportunity(mix, adapter)
    end

    test "unless_used guard is honored per-rule" do
      adapter = %Adapter{
        opportunity_rules: [
          %{
            skill: "py-verify",
            when: :commands,
            commands: ["pytest"],
            threshold: 1,
            unless_used: true
          }
        ],
        skill_namespaces: ["py"]
      }

      events = [user("run /py:py-verify first"), asst([{"Bash", %{"command" => "pytest"}}])]
      assert %{missed: missed, used: used} = Detect.opportunity(events, adapter)
      assert "py-verify" in used
      refute "py-verify" in missed
    end

    test "skill namespaces come from the adapter" do
      adapter = %Adapter{skill_namespaces: ["py"]}

      events = [user("let me run /py:lint and also /phx:verify")]
      assert %{used: used} = Detect.opportunity(events, adapter)
      assert "lint" in used
      # `phx:` is the engine default — NOT this adapter's namespace, so it's not extracted.
      refute "verify" in used
    end

    test "an empty skill_namespaces list skips text extraction" do
      adapter = %Adapter{skill_namespaces: []}

      events = [user("let me run /phx:verify and /py:lint")]
      assert %{used: []} = Detect.opportunity(events, adapter)
    end

    test "a junk (non-binary) namespace entry degrades gracefully, never crashes the scan" do
      # An in-memory adapter that bypassed `Adapter.validate/1` — the regex build must not raise:
      # non-binary entries are filtered, valid ones still match.
      adapter = %Adapter{skill_namespaces: ["py", 42]}

      events = [user("ran /py:lint earlier")]
      assert %{used: used} = Detect.opportunity(events, adapter)
      assert "lint" in used
    end
  end

  # P0-T5: the faber-elixir adapter migrates the engine's historical Elixir/plugin defaults into
  # detect/signatures.yaml. Running WITH it must reproduce the adapter-free path byte-for-byte —
  # this is the guard that the migration didn't regress detection.
  describe "faber-elixir adapter parity (P0-T5)" do
    setup do
      assert {:ok, adapter} = Adapter.load(@reference_adapter)
      %{adapter: adapter}
    end

    test "the migrated detection vocab loaded onto the struct", %{adapter: a} do
      assert a.fingerprint_rules == [
               %{type: "maintenance", commands: ["mix deps", "mix hex"], bonus: 3.0},
               %{type: "review", commands: ["gh pr", "gh issue"], bonus: 3.0}
             ]

      assert Enum.map(a.opportunity_rules, & &1.skill) ==
               ["investigate", "plan", "verify", "pr-review", "review"]

      assert a.skill_namespaces == ["phx", "ecto", "lv"]
    end

    test "fingerprint + opportunity match the adapter-free defaults on every probe session",
         %{adapter: a} do
      # One probe per leaked rule, plus the file fixtures — each must score identically with and
      # without the adapter (the adapter restates exactly the engine defaults).
      probes = [
        load("sample_session.jsonl"),
        load("smooth_session.jsonl"),
        [user("update the deps"), asst([{"Bash", %{"command" => "mix deps.get"}}])],
        [user("check the PR"), asst([{"Bash", %{"command" => "gh pr view 42"}}])],
        [
          asst([
            {"Bash", %{"command" => "mix test"}},
            {"Bash", %{"command" => "mix compile"}},
            {"Bash", %{"command" => "mix test"}}
          ])
        ],
        [asst(List.duplicate({"Bash", %{"command" => "gh pr view"}}, 2))],
        [asst(List.duplicate({"Read", %{}}, 51))],
        [asst(for i <- 1..11, do: {"Edit", %{"file_path" => "/f#{i}.ex"}})],
        [
          user("ran /phx:verify already"),
          asst(List.duplicate({"Bash", %{"command" => "git x"}}, 3))
        ]
      ]

      for events <- probes do
        assert Detect.fingerprint(events, a) == Detect.fingerprint(events)
        assert Detect.opportunity(events, a) == Detect.opportunity(events)
      end

      # Absolute snapshots so a JOINT regression (both paths breaking identically) can't pass the
      # equality checks above — anchor at least one probe to its known result.
      mix_deps = Enum.at(probes, 2)
      assert %{type: "maintenance"} = Detect.fingerprint(mix_deps, a)

      verify_loop = Enum.at(probes, 4)
      assert %{missed: ["verify"]} = Detect.opportunity(verify_loop, a)
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

    test "infers the 1M-beta window when peak exceeds the standard window" do
      # Claude Code records the plain model id even on a 1M session, so a 366k peak under the 200k
      # standard window is the tell that the 1M beta was active → 36.7%, not 183%.
      event = usage_event("claude-opus-4-8", 366_745, 0)
      assert %{max_ctx_pct: 36.7} = Detect.context([event])
    end

    test "resolves opus-4-5 (date-suffixed) against the model map" do
      event = usage_event("claude-opus-4-5-20251101", 150_000, 0)

      assert %{max_ctx_pct: 75.0, primary_model: "claude-opus-4-5-20251101"} =
               Detect.context([event])
    end

    test "clamps a pathological fill to 100%" do
      event = usage_event("claude-opus-4-8", 1_500_000, 0)
      assert %{max_ctx_pct: 100.0} = Detect.context([event])
    end
  end

  defp asst_usage(input, cache_read), do: usage_event("claude-opus-4-8", input, cache_read)

  defp usage_event(model, input, cache_read) do
    Faber.Ingest.normalize(%{
      "type" => "assistant",
      "message" => %{
        "role" => "assistant",
        "model" => model,
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
