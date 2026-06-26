defmodule Faber.Ingest.Format.ClineTest do
  use ExUnit.Case, async: true

  alias Faber.Ingest
  alias Faber.Ingest.Event
  alias Faber.Ingest.Format.Cline
  alias Faber.Scan

  # A globalStorage-shaped fixture tree: <base>/<Variant>/User/globalStorage/saoudrizwan.claude-dev/
  # tasks/<task-id>/api_conversation_history.json — kept isolated so it never out-ranks the shared
  # Claude fixtures in dir-scans.
  @base Path.expand("../fixtures_cline", __DIR__)
  @session Path.join(
             @base,
             "Code/User/globalStorage/saoudrizwan.claude-dev/tasks/task-abc123/api_conversation_history.json"
           )

  # Build a single Anthropic-format message (string keys, as decoded from disk).
  defp msg(role, content), do: %{"role" => role, "content" => content}

  defp block(type, fields), do: Map.put(fields, "type", type)

  describe "format resolution" do
    test ":cline resolves to the Cline format module" do
      assert Ingest.Format.resolve(format: :cline) == Cline
    end
  end

  describe "normalize/1 — Anthropic content blocks + canonical tool mapping" do
    test "a string-content user message → a human user turn" do
      e = Cline.normalize(msg("user", "fix the parser"))
      assert %Event{type: :user, role: "user", text: "fix the parser"} = e
      assert Event.human_turn?(e)
    end

    test "assistant text blocks are joined; tool_use is extracted" do
      e =
        Cline.normalize(
          msg("assistant", [
            block("text", %{"text" => "running tests"}),
            block("tool_use", %{
              "id" => "t1",
              "name" => "execute_command",
              "input" => %{"command" => "mix test"}
            })
          ])
        )

      assert %Event{type: :assistant, text: "running tests", tool_uses: [tu]} = e
      assert %{name: "Bash", input: %{"command" => "mix test"}, id: "t1"} = tu
    end

    test "read_file → Read, write_to_file → Write, replace_in_file → Edit (path → file_path)" do
      uses = fn name ->
        Cline.normalize(
          msg("assistant", [
            block("tool_use", %{"id" => "x", "name" => name, "input" => %{"path" => "lib/p.ex"}})
          ])
        ).tool_uses
      end

      assert [%{name: "Read", input: %{"file_path" => "lib/p.ex"}}] = uses.("read_file")
      assert [%{name: "Write", input: %{"file_path" => "lib/p.ex"}}] = uses.("write_to_file")
      assert [%{name: "Edit", input: %{"file_path" => "lib/p.ex"}}] = uses.("replace_in_file")
    end

    test "an unknown tool keeps its name so it still counts" do
      [tu] =
        Cline.normalize(
          msg("assistant", [
            block("tool_use", %{"id" => "z", "name" => "ask_followup_question", "input" => %{}})
          ])
        ).tool_uses

      assert %{name: "ask_followup_question"} = tu
    end

    test "tool_result errors are flagged" do
      e =
        Cline.normalize(
          msg("user", [block("tool_result", %{"tool_use_id" => "t1", "is_error" => true})])
        )

      assert %Event{type: :user, tool_results: [%{tool_use_id: "t1", is_error: true}]} = e
    end
  end

  describe "discover/1 + stream_file!/1" do
    test "discovers the api_conversation_history.json across VS Code variants" do
      assert @session in Cline.discover(@base)
    end

    test "streams one event per message, stamping the task-id as session_id" do
      events =
        @session
        |> Cline.stream_file!()
        |> Enum.map(fn {:ok, e} -> e end)

      assert length(events) == 10
      assert Enum.all?(events, &(&1.session_id == "task-abc123"))
      # The Bash retries are present (two `mix test` runs before the fix).
      bash = events |> Enum.flat_map(& &1.tool_uses) |> Enum.filter(&(&1.name == "Bash"))
      assert length(bash) >= 2
    end

    test "a malformed file surfaces as a single {:error, _}, not a crash" do
      bad = Path.join(System.tmp_dir!(), "cline-bad-#{System.unique_integer([:positive])}.json")
      File.write!(bad, "{not json")
      on_exit(fn -> File.rm(bad) end)

      assert [{:error, %{reason: _}}] = Cline.stream_file!(bad) |> Enum.to_list()
    end
  end

  describe "end-to-end scan" do
    test "a Cline session scores as friction with canonical signals and file paths" do
      assert [%Scan.Result{} = r | _] = Scan.run(base: @base, format: :cline, min_messages: 0)

      assert r.session_id == "task-abc123"
      assert r.friction > 0.0
      # The Edit on lib/parser.ex is canonicalized, so the path is referenced.
      assert "lib/parser.ex" in r.file_paths
      # Two failed `mix test` runs before the fix → a Bash retry loop registers.
      assert r.signals.retry_loops >= 1
    end
  end
end
