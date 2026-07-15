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

    test "tool_profile/1 buckets MCP tools generically" do
      events = [asst([{"Bash", %{}}, {"mcp__tidewave__project_eval", %{}}])]
      profile = Detect.tool_profile(events)
      assert_in_delta profile.bash, 0.5, 1.0e-9
      assert_in_delta profile.mcp, 0.5, 1.0e-9
    end

    test "retry loop survives duplicate and nil tool_result ids" do
      # Three same-prefix Bash calls; t2 has TWO results (error then success) plus an id-less
      # result. A failed result must win the union — a later success or a nil-id collision
      # must not erase the failure and hide the retry loop.
      calls =
        Ingest.normalize(%{
          "type" => "assistant",
          "message" => %{
            "role" => "assistant",
            "content" =>
              for id <- ~w(t1 t2 t3) do
                %{
                  "type" => "tool_use",
                  "name" => "Bash",
                  "id" => id,
                  "input" => %{"command" => "mix test foo"}
                }
              end
          }
        })

      results =
        Ingest.normalize(%{
          "type" => "user",
          "message" => %{
            "role" => "user",
            "content" => [
              %{"type" => "tool_result", "tool_use_id" => "t2", "is_error" => true},
              %{"type" => "tool_result", "tool_use_id" => "t2", "is_error" => false},
              %{"type" => "tool_result", "tool_use_id" => nil, "is_error" => false}
            ]
          }
        })

      f = Detect.friction([calls, results])
      assert f.signals.retry_loops == 1
    end
  end

  # Regression for the 2026-07-15 audit: `retry_loops` is the highest-weighted signal (3.0) and
  # was 0/7 genuine on `faber/31f10cff`, because a 2-token prefix collides under the
  # `cd /abs/path && …` convention our own agent instructions mandate.
  describe "friction/1 retry_loops keys on the full normalized command" do
    # Bash calls with sequential ids, and the ids that errored.
    defp bash_run(commands, errored_ids) do
      calls =
        Ingest.normalize(%{
          "type" => "assistant",
          "message" => %{
            "role" => "assistant",
            "content" =>
              commands
              |> Enum.with_index()
              |> Enum.map(fn {cmd, i} ->
                %{
                  "type" => "tool_use",
                  "name" => "Bash",
                  "id" => "t#{i}",
                  "input" => if(cmd == :malformed, do: %{}, else: %{"command" => cmd})
                }
              end)
          }
        })

      results =
        Ingest.normalize(%{
          "type" => "user",
          "message" => %{
            "role" => "user",
            "content" =>
              Enum.map(errored_ids, fn id ->
                %{"type" => "tool_result", "tool_use_id" => id, "is_error" => true}
              end)
          }
        })

      Detect.friction([calls, results]).signals.retry_loops
    end

    test "a genuine retry loop still fires" do
      assert bash_run(List.duplicate("mix test test/foo_test.exs", 3), ["t1"]) == 1
    end

    test "the same command under a cd preamble still groups as one loop" do
      # The `cd` hop is boilerplate, so stripping it must not *lose* a real loop.
      cmd = "cd /Users/oliverkriska/Projects/faber && mix test test/foo_test.exs"
      assert bash_run(List.duplicate(cmd, 3), ["t1"]) == 1
    end

    test "stacked cd segments are stripped" do
      cmd = "cd /tmp && cd /Users/oliverkriska/Projects/faber && mix test"
      assert bash_run(List.duplicate(cmd, 3), ["t1"]) == 1
    end

    test "distinct commands behind a shared cd preamble are not a loop" do
      # The audited shape: one detected "loop" grouped 93 different commands behind `cd /Users/…`.
      cd = "cd /Users/oliverkriska/Projects/faber && "
      assert bash_run([cd <> "mix compile", cd <> "mix format", cd <> "git status"], ["t1"]) == 0
    end

    test "git add of different paths is not a loop" do
      commands = ["git add lib/a.ex", "git add lib/b.ex", "git add lib/c.ex"]
      assert bash_run(commands, ["t1"]) == 0
    end

    test "mise exec of different commands is not a loop" do
      commands = ["mise exec -- mix test", "mise exec -- mix credo", "mise exec -- mix dialyzer"]
      assert bash_run(commands, ["t1"]) == 0
    end

    test "a same-command run with no errors is not a loop" do
      assert bash_run(List.duplicate("mix test", 3), []) == 0
    end

    test "non-consecutive repeats of the same command are not a loop" do
      # chunk_by, not group_by: re-running `mix test` across a session is normal work, not a loop.
      commands = ["mix test", "git status", "mix test", "git status", "mix test"]
      assert bash_run(commands, ["t0", "t2", "t4"]) == 0
    end

    test "whitespace-only differences still group" do
      commands = ["mix  test   foo", "mix test foo", "mix\ttest foo"]
      assert bash_run(commands, ["t1"]) == 1
    end

    test "malformed commands never contribute to a run" do
      # Previously `bash_prefix(_) -> ""` collapsed these onto a shared key, so 3 malformed calls
      # plus one error faked a loop.
      assert bash_run([:malformed, :malformed, :malformed], ["t1"]) == 0
    end

    test "malformed calls are dropped from the sequence, not treated as a separator" do
      # "Excluded from runs entirely" means the call leaves the sequence, so the identifiable
      # commands on either side become adjacent. An unparseable Bash call is not evidence that the
      # agent stopped retrying — and it's rare (3 in the whole 16.5k-event audited session).
      commands = ["mix test", "mix test", :malformed, "mix test"]
      assert bash_run(commands, ["t0"]) == 1
    end
  end

  # Regression for the 2026-07-15 audit: Claude Code writes background-task completions and
  # teammate messages as `role: "user"` turns, so the harness talking to itself was scoring as
  # user friction (27 of 30 "corrections" in `faber/31f10cff`). Detect stays agent-agnostic —
  # it just honors `Event.human_turn?/1` — but the *effect* is asserted here, where it matters.
  describe "friction/1 ignores harness-authored user turns" do
    test "a task-notification full of correction words scores zero corrections" do
      events = [
        user("""
        <task-notification>
        <status>completed</status>
        <result>That was wrong, so I reverted it and did it the other way instead.</result>
        </task-notification>
        """)
      ]

      assert Detect.friction(events).signals.user_corrections == 0
    end

    test "a genuine correction alongside a system-reminder still counts" do
      events = [
        user("""
        <system-reminder>Context is running low.</system-reminder>
        no, that's not what I meant — revert it
        """)
      ]

      assert Detect.friction(events).signals.user_corrections == 1
    end

    test "interrupts are still counted on turns carrying the marker" do
      events = [user("[Request interrupted by user]")]

      assert Detect.friction(events).signals.interrupted_requests == 1
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

    test "synthetic user turns don't steer keyword classification" do
      # Fingerprint is the other `human_turn?/1` consumer, so the audit's pollution reached it too:
      # a task-notification reporting a subagent's bug-hunt is dense with "fix"/"bug"/"error" and
      # would classify an exploration session as bug-fix. The read-heavy tool mix is the only
      # honest signal here.
      events = [
        user("""
        <task-notification>
        <result>Found the bug: an error in the crash handler. Fix the broken debug path.</result>
        </task-notification>
        """),
        user("explain how does this work, I want to understand the code"),
        asst([{"Read", %{}}, {"Grep", %{}}, {"Read", %{}}])
      ]

      assert %{type: "exploration"} = Detect.fingerprint(events)
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

    test "command-based rules need an adapter — adapter-free flags nothing here" do
      # `mix test`/`mix compile` alternate (differing 2-token prefixes), so investigate doesn't
      # fire; the historical `verify` :commands rule now lives in the faber-elixir pack, so the
      # stack-neutral defaults report NO missed opportunity for this session.
      events = [
        asst([
          {"Bash", %{"command" => "mix test"}},
          {"Bash", %{"command" => "mix compile"}},
          {"Bash", %{"command" => "mix test"}}
        ])
      ]

      assert %{missed: []} = Detect.opportunity(events)
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

    test "already-used skills are excluded (vocab-supplied namespaces + rules)" do
      adapter = %Adapter{
        opportunity_rules: [
          %{
            skill: "verify",
            when: :commands,
            commands: ["mix test", "mix compile"],
            threshold: 3,
            unless_used: true
          }
        ],
        skill_namespaces: ["phx"]
      }

      events = [
        user("let me run /phx:verify on this"),
        asst([
          {"Bash", %{"command" => "mix test"}},
          {"Bash", %{"command" => "mix compile"}},
          {"Bash", %{"command" => "mix test"}}
        ])
      ]

      assert %{missed: missed, used: used} = Detect.opportunity(events, adapter)
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

      # ...and there is no `mix deps → maintenance` rule anywhere but the faber-elixir pack:
      # with this adapter AND adapter-free (stack-neutral defaults) only the generic bash-heavy
      # `bug-fix` bonus remains.
      mix = [user("proceed"), asst([{"Bash", %{"command" => "mix deps.get"}}])]
      assert %{type: "bug-fix"} = Detect.fingerprint(mix)
      assert %{type: "bug-fix"} = Detect.fingerprint(mix, adapter)
    end

    test "fingerprint tool-prefix bonuses come from the adapter (tools: vocab)" do
      adapter = %Adapter{
        fingerprint_rules: [
          %{type: "bug-fix", commands: [], tools: ["mcp__tidewave"], bonus: 1.5}
        ]
      }

      events = [user("look at this thing"), asst([{"mcp__tidewave__project_eval", %{}}])]

      # "look at" scores exploration 2.0; the tidewave PREFIX rule adds bug-fix 1.5 →
      # exploration wins at 2.0/3.5. Adapter-free the engine knows nothing about tidewave,
      # so exploration is the only signal (confidence 1.0).
      assert %{type: "exploration", confidence: 0.57} = Detect.fingerprint(events, adapter)
      assert %{type: "exploration", confidence: 1.0} = Detect.fingerprint(events)
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

      # No `mix test → verify` rule fires under this adapter (nor adapter-free — that rule
      # lives in the faber-elixir pack). 3x the same `mix test` prefix would trip the neutral
      # `investigate` rule, but THIS adapter's vocab has no such rule either.
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
      # `phx:` is the faber-elixir pack's namespace — NOT this adapter's, so it's not extracted.
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

  # P0-T5, updated for the neutral-defaults change: the faber-elixir adapter carries the
  # engine's historical Elixir/plugin vocabulary (including the Tidewave bonus, now a `tools:`
  # rule). The engine defaults became stack-neutral, so parity is pinned as ABSOLUTE snapshots
  # of the adapter-selected outputs, captured on the pre-change code — the adapter-selected
  # path must never drift.
  describe "faber-elixir adapter detection snapshots (P0-T5)" do
    setup do
      assert {:ok, adapter} = Adapter.load(@reference_adapter)
      %{adapter: adapter}
    end

    test "the migrated detection vocab loaded onto the struct", %{adapter: a} do
      assert a.fingerprint_rules == [
               %{type: "maintenance", commands: ["mix deps", "mix hex"], tools: [], bonus: 3.0},
               %{type: "review", commands: ["gh pr", "gh issue"], tools: [], bonus: 3.0},
               %{type: "bug-fix", commands: [], tools: ["mcp__tidewave"], bonus: 1.5}
             ]

      assert Enum.map(a.opportunity_rules, & &1.skill) ==
               ["investigate", "plan", "verify", "pr-review", "review"]

      assert a.skill_namespaces == ["phx", "ecto", "lv"]
    end

    test "fingerprint + opportunity reproduce the historical outputs on every probe",
         %{adapter: a} do
      # One probe per vocab rule, plus the file fixtures. Expected values are snapshots of the
      # adapter-selected outputs BEFORE the engine defaults were neutralized (when the pack
      # restated them 1:1) — this is the regression guard for the adapter path.
      probes = [
        {load("sample_session.jsonl"), %{type: "bug-fix", confidence: 0.67},
         %{used: [], score: 0.4, missed: ["investigate", "verify"]}},
        {load("smooth_session.jsonl"), %{type: "exploration", confidence: 1.0},
         %{used: [], score: 0.0, missed: []}},
        {[user("update the deps"), asst([{"Bash", %{"command" => "mix deps.get"}}])],
         %{type: "maintenance", confidence: 0.78}, %{used: [], score: 0.0, missed: []}},
        {[user("check the PR"), asst([{"Bash", %{"command" => "gh pr view 42"}}])],
         %{type: "review", confidence: 0.71}, %{used: [], score: 0.0, missed: []}},
        {[
           asst([
             {"Bash", %{"command" => "mix test"}},
             {"Bash", %{"command" => "mix compile"}},
             {"Bash", %{"command" => "mix test"}}
           ])
         ], %{type: "bug-fix", confidence: 1.0}, %{used: [], score: 0.2, missed: ["verify"]}},
        {[asst(List.duplicate({"Bash", %{"command" => "gh pr view"}}, 2))],
         %{type: "review", confidence: 0.6}, %{used: [], score: 0.2, missed: ["pr-review"]}},
        {[asst(List.duplicate({"Read", %{}}, 51))], %{type: "exploration", confidence: 1.0},
         %{used: [], score: 0.2, missed: ["plan"]}},
        {[asst(for i <- 1..11, do: {"Edit", %{"file_path" => "/f#{i}.ex"}})],
         %{type: "feature", confidence: 0.6}, %{used: [], score: 0.2, missed: ["review"]}},
        {[
           user("ran /phx:verify already"),
           asst(List.duplicate({"Bash", %{"command" => "git x"}}, 3))
         ], %{type: "bug-fix", confidence: 1.0},
         %{used: ["verify"], score: 0.2, missed: ["investigate"]}},
        # The Tidewave bonus survives the engine→pack migration as a `tools:` prefix rule.
        {[user("look at this thing"), asst([{"mcp__tidewave__project_eval", %{}}])],
         %{type: "exploration", confidence: 0.57}, %{used: [], score: 0.0, missed: []}}
      ]

      for {events, expected_fp, expected_op} <- probes do
        assert Detect.fingerprint(events, a) == expected_fp
        assert Detect.opportunity(events, a) == expected_op
      end
    end
  end

  # 5.3: the engine carries NO stack vocabulary — everything Elixir/plugin-flavored lives in
  # the faber-elixir pack. Guards against a stack-specific default sneaking back in.
  describe "engine defaults are stack-neutral" do
    test "adapter-free vocab has no commands, tools, or namespaces" do
      assert Detect.fingerprint_rules(nil) == []
      assert Detect.skill_namespaces(nil) == []

      rules = Detect.opportunity_rules(nil)
      assert Enum.map(rules, & &1.skill) == ["investigate", "plan", "review"]
      assert Enum.all?(rules, &(&1.commands == []))
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

    test "skips a non-string message.model instead of crashing" do
      event =
        Ingest.normalize(%{
          "type" => "assistant",
          "message" => %{
            "role" => "assistant",
            "model" => 123,
            "usage" => %{"input_tokens" => 190_000},
            "content" => []
          }
        })

      assert %{max_ctx_pct: nil, primary_model: nil} = Detect.context([event])
    end

    test "tolerates a non-map message in the raw line" do
      event = Ingest.normalize(%{"type" => "assistant", "message" => 42})
      assert %{max_ctx_pct: nil, primary_model: nil} = Detect.context([event])
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
