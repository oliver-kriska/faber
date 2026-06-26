defmodule Faber.Ingest.Format.GeminiTest do
  use ExUnit.Case, async: true

  alias Faber.Ingest
  alias Faber.Ingest.Event
  alias Faber.Ingest.Format.Gemini
  alias Faber.Scan

  # A Gemini-CLI-shaped fixture tree: <base>/<project-hash>/chats/session-*.json — kept isolated so
  # it never out-ranks the shared Claude fixtures in dir-scans.
  @base Path.expand("../fixtures_gemini", __DIR__)
  @session Path.join(@base, "a1b2c3d4e5/chats/session-test.json")

  # Build a single Gemini message (string keys, as decoded from disk).
  defp msg(role, parts), do: %{"role" => role, "parts" => parts}
  defp text(t), do: %{"text" => t}
  defp call(name, args), do: %{"functionCall" => %{"id" => "fc", "name" => name, "args" => args}}

  defp resp(name, response),
    do: %{"functionResponse" => %{"id" => "fc", "name" => name, "response" => response}}

  describe "format resolution" do
    test ":gemini resolves to the Gemini format module" do
      assert Ingest.Format.resolve(format: :gemini) == Gemini
    end
  end

  describe "normalize/1 — Gemini parts + canonical tool mapping" do
    test "a parts-text user message → a human user turn" do
      e = Gemini.normalize(msg("user", [text("fix the parser")]))
      assert %Event{type: :user, role: "user", text: "fix the parser"} = e
      assert Event.human_turn?(e)
    end

    test "a plain string content is also accepted as text" do
      e = Gemini.normalize(%{"role" => "user", "content" => "fix the parser"})
      assert %Event{type: :user, text: "fix the parser"} = e
    end

    test "model role maps to :assistant; text joined and functionCall extracted" do
      e =
        Gemini.normalize(
          msg("model", [
            text("running tests"),
            call("run_shell_command", %{"command" => "mix test"})
          ])
        )

      assert %Event{type: :assistant, text: "running tests", tool_uses: [tu]} = e
      assert %{name: "Bash", input: %{"command" => "mix test"}} = tu
    end

    test "read_file → Read, write_file → Write, replace → Edit (varied path keys → file_path)" do
      use_of = fn name, args ->
        Gemini.normalize(msg("model", [call(name, args)])).tool_uses
      end

      assert [%{name: "Read", input: %{"file_path" => "lib/p.ex"}}] =
               use_of.("read_file", %{"absolute_path" => "lib/p.ex"})

      assert [%{name: "Write", input: %{"file_path" => "lib/p.ex"}}] =
               use_of.("write_file", %{"file_path" => "lib/p.ex"})

      assert [%{name: "Edit", input: %{"file_path" => "lib/p.ex"}}] =
               use_of.("replace", %{"path" => "lib/p.ex"})
    end

    test "glob → Glob, search_file_content → Grep" do
      assert [%{name: "Glob"}] = Gemini.normalize(msg("model", [call("glob", %{})])).tool_uses

      assert [%{name: "Grep"}] =
               Gemini.normalize(msg("model", [call("search_file_content", %{})])).tool_uses
    end

    test "an unknown tool keeps its name so it still counts" do
      [tu] = Gemini.normalize(msg("model", [call("save_memory", %{})])).tool_uses
      assert %{name: "save_memory"} = tu
    end

    test "a functionResponse with an error key is flagged; a plain output is not" do
      err = Gemini.normalize(msg("user", [resp("run_shell_command", %{"error" => "boom"})]))
      ok = Gemini.normalize(msg("user", [resp("run_shell_command", %{"output" => "done"})]))

      assert %Event{tool_results: [%{is_error: true}]} = err
      assert %Event{tool_results: [%{is_error: false}]} = ok
    end
  end

  describe "discover/1 + stream_file!/1" do
    test "discovers session-*.json under <hash>/chats" do
      assert @session in Gemini.discover(@base)
    end

    test "streams one event per message, stamping the top-level sessionId" do
      events =
        @session
        |> Gemini.stream_file!()
        |> Enum.map(fn {:ok, e} -> e end)

      assert length(events) == 10
      assert Enum.all?(events, &(&1.session_id == "session-gemini-001"))
      # Three `mix test` runs (two failing, one passing) are canonicalized to Bash.
      bash = events |> Enum.flat_map(& &1.tool_uses) |> Enum.filter(&(&1.name == "Bash"))
      assert length(bash) == 3
    end

    test "a malformed file surfaces as a single {:error, _}, not a crash" do
      bad = Path.join(System.tmp_dir!(), "gemini-bad-#{System.unique_integer([:positive])}.json")
      File.write!(bad, "{not json")
      on_exit(fn -> File.rm(bad) end)

      assert [{:error, %{reason: _}}] = Gemini.stream_file!(bad) |> Enum.to_list()
    end

    test "an unexpected top-level shape surfaces as {:error, _}" do
      bad =
        Path.join(System.tmp_dir!(), "gemini-shape-#{System.unique_integer([:positive])}.json")

      File.write!(bad, ~s({"not_messages": 1}))
      on_exit(fn -> File.rm(bad) end)

      assert [{:error, %{reason: {:unexpected_shape, _}}}] = Gemini.stream_file!(bad)
    end
  end

  describe "end-to-end scan" do
    test "a Gemini session scores as friction with canonical signals and file paths" do
      assert [%Scan.Result{} = r | _] = Scan.run(base: @base, format: :gemini, min_messages: 0)

      assert r.session_id == "session-gemini-001"
      assert r.friction > 0.0
      # The replace on lib/parser.ex is canonicalized, so the path is referenced.
      assert "lib/parser.ex" in r.file_paths
      # Two failed `mix test` runs before the fix → a Bash retry loop registers.
      assert r.signals.retry_loops >= 1
    end
  end
end
