defmodule Faber.Ingest.Format.CodexTest do
  use ExUnit.Case, async: true

  alias Faber.Ingest
  alias Faber.Ingest.Event
  alias Faber.Ingest.Format.Codex
  alias Faber.Scan
  alias Faber.Scan.Result

  @fixtures Path.expand("../fixtures/codex", __DIR__)
  @session Path.join(@fixtures, "codex_session.jsonl")

  describe "format resolution" do
    test ":codex resolves to the Codex format module" do
      assert Ingest.Format.resolve(format: :codex) == Codex
    end
  end

  describe "normalize/1 — canonical mapping" do
    test "user_message → a human user turn" do
      e =
        Codex.normalize(
          msg("event_msg", %{"type" => "user_message", "message" => "do the thing"})
        )

      assert %Event{type: :user, text: "do the thing"} = e
      assert Event.human_turn?(e)
    end

    test "agent_message → an assistant text turn" do
      e = Codex.normalize(msg("event_msg", %{"type" => "agent_message", "message" => "on it"}))
      assert %Event{type: :assistant, text: "on it"} = e
      refute Event.human_turn?(e)
    end

    test "exec_command → a canonical Bash tool_use with the command" do
      e =
        Codex.normalize(
          msg("response_item", %{
            "type" => "function_call",
            "name" => "exec_command",
            "arguments" => ~s({"cmd":"git status","workdir":"/x"}),
            "call_id" => "c1"
          })
        )

      assert %Event{type: :assistant, tool_uses: [tu]} = e
      assert %{name: "Bash", input: %{"command" => "git status"}, id: "c1"} = tu
    end

    test "view_image → Read, write_stdin → WriteStdin" do
      read =
        Codex.normalize(
          msg("response_item", %{
            "type" => "function_call",
            "name" => "view_image",
            "arguments" => ~s({"path":"/tmp/a.png"}),
            "call_id" => "c2"
          })
        )

      assert [%{name: "Read", input: %{"file_path" => "/tmp/a.png"}}] = read.tool_uses

      stdin =
        Codex.normalize(
          msg("response_item", %{
            "type" => "function_call",
            "name" => "write_stdin",
            "arguments" => ~s({"chars":"y"}),
            "call_id" => "c3"
          })
        )

      assert [%{name: "WriteStdin"}] = stdin.tool_uses
    end

    test "apply_patch → one Edit per file in the patch envelope" do
      patch =
        "*** Begin Patch\n*** Update File: lib/a.ex\n+x\n*** Add File: lib/b.ex\n+y\n*** End Patch"

      e =
        Codex.normalize(
          msg("response_item", %{
            "type" => "custom_tool_call",
            "name" => "apply_patch",
            "input" => patch,
            "call_id" => "c4"
          })
        )

      assert [
               %{name: "Edit", input: %{"file_path" => "lib/a.ex"}},
               %{name: "Edit", input: %{"file_path" => "lib/b.ex"}}
             ] =
               e.tool_uses
    end

    test "function_call_output error detection (exit code / sandbox / list)" do
      err = output_result("Process exited with code 1\nboom")
      assert [%{is_error: true}] = err.tool_results

      ok = output_result("Process exited with code 0\nfine")
      assert [%{is_error: false}] = ok.tool_results

      denied = output_result("exec_command failed: SandboxDenied { message: \"nope\" }")
      assert [%{is_error: true}] = denied.tool_results

      # A list output (image payload) is never an error.
      image = output_result([%{"type" => "input_image", "image_url" => "data:..."}])
      assert [%{is_error: false}] = image.tool_results
    end

    test "custom_tool_call_output uses metadata.exit_code" do
      bad =
        Codex.normalize(
          msg("response_item", %{
            "type" => "custom_tool_call_output",
            "call_id" => "c4",
            "output" => ~s({"output":"nope","metadata":{"exit_code":2}})
          })
        )

      assert [%{tool_use_id: "c4", is_error: true}] = bad.tool_results
    end

    test "token_count → normalized usage; null info → nil" do
      e =
        Codex.normalize(
          msg("event_msg", %{
            "type" => "token_count",
            "info" => %{
              "last_token_usage" => %{"input_tokens" => 50_000},
              "model_context_window" => 200_000
            }
          })
        )

      assert %Event{is_meta: true, usage: %{prompt_tokens: 50_000, context_window: 200_000}} = e

      nilled = Codex.normalize(msg("event_msg", %{"type" => "token_count", "info" => nil}))
      assert nilled.usage == nil
    end

    test "session_meta seeds the session id and cwd; preamble messages are inert" do
      meta =
        Codex.normalize(
          msg("session_meta", %{"session_id" => "s-1", "cwd" => "/Users/x/Projects/demo"})
        )

      assert %Event{type: :other, is_meta: true, session_id: "s-1", cwd: "/Users/x/Projects/demo"} =
               meta

      # response_item/message (the AGENTS.md/role=user preamble) must NOT count as a user turn.
      pre =
        Codex.normalize(
          msg("response_item", %{
            "type" => "message",
            "role" => "user",
            "content" => [%{"type" => "input_text", "text" => "# AGENTS.md"}]
          })
        )

      assert %Event{type: :other} = pre
      refute Event.human_turn?(pre)
    end
  end

  describe "stream_file!/1" do
    test "threads the session id from session_meta onto every event" do
      {events, errors} = Ingest.parse_file(@session, format: :codex)
      assert errors == []
      assert Enum.all?(events, &(&1.session_id == "codex-sess-1"))
    end
  end

  describe "Scan.run over a codex session (hermetic — files source)" do
    test "derives friction signals from the codex event streams" do
      assert [%Result{} = r] =
               Scan.run(base: @fixtures, format: :codex, min_messages: 0)

      assert r.session_id == "codex-sess-1"
      assert r.parse_errors == 0
      # cwd from session_meta drives a clean project label, not the rollout date dir.
      assert r.cwd == "/Users/x/Projects/demo"

      # 6 tool calls: 3 Bash (exec_command) + 1 Edit (apply_patch) + 1 Read (view_image) + 1 WriteStdin.
      assert r.tool_count == 6
      # Two exec failures (code 1); the apply_patch / image / stdin outputs are clean.
      assert r.error_count == 2

      # user_message ×2 + agent_message + function/custom calls + their outputs (tool turns count).
      assert r.message_count == 15

      # 3 consecutive `mix test` runs with failures among them → one retry loop.
      assert r.signals.retry_loops == 1
      # "no, that's wrong — revert" matches the correction regex.
      assert r.signals.user_corrections == 1
      assert r.dominant_signal == :retry_loops

      # Context pressure comes from token_count's inline window: 180k / 200k = 90%.
      assert r.max_ctx_pct == 90.0
      assert r.tier2

      # file_paths (stack signal) captures apply_patch's file + the viewed image.
      assert "lib/demo.ex" in r.file_paths
      assert "/tmp/shot.png" in r.file_paths
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp msg(type, payload),
    do: %{"type" => type, "timestamp" => "2026-06-23T06:00:00.000Z", "payload" => payload}

  defp output_result(output) do
    Codex.normalize(
      msg("response_item", %{
        "type" => "function_call_output",
        "call_id" => "c",
        "output" => output
      })
    )
  end
end
