defmodule Faber.Ingest.Format.OpenCodeTest do
  use ExUnit.Case, async: true

  alias Faber.Ingest
  alias Faber.Ingest.Event
  alias Faber.Ingest.Format.OpenCode
  alias Faber.Scan

  # Build a logical OpenCode message (string keys) — a message row's role + its decoded parts.
  defp m(role, parts), do: %{"role" => role, "parts" => parts}
  defp text(t), do: %{"type" => "text", "text" => t}

  defp tool(name, input, status),
    do: %{
      "type" => "tool",
      "tool" => name,
      "callID" => "call-#{name}",
      "state" => %{"status" => status, "input" => input}
    }

  defp patch(files), do: %{"type" => "patch", "hash" => "h", "files" => files}

  describe "format resolution" do
    test ":opencode resolves to the OpenCode format module" do
      assert Ingest.Format.resolve(format: :opencode) == OpenCode
    end
  end

  describe "normalize/1 — OpenCode parts + canonical tool mapping (pure, no DB)" do
    test "a text part on a user message → a human user turn" do
      e = OpenCode.normalize(m("user", [text("fix the parser")]))
      assert %Event{type: :user, role: "user", text: "fix the parser"} = e
      assert Event.human_turn?(e)
    end

    test "a tool part is call+result combined: a Bash use AND an error tool_result" do
      e =
        OpenCode.normalize(
          m("assistant", [
            text("running tests"),
            tool("bash", %{"command" => "mix test"}, "error")
          ])
        )

      assert %Event{type: :assistant, text: "running tests", tool_uses: [tu], tool_results: [tr]} =
               e

      assert %{name: "Bash", input: %{"command" => "mix test"}} = tu
      assert %{is_error: true} = tr
    end

    test "a completed tool part is not an error" do
      e = OpenCode.normalize(m("assistant", [tool("bash", %{"command" => "ls"}, "completed")]))
      assert %Event{tool_results: [%{is_error: false}]} = e
    end

    test "read → Read, write → Write, edit → Edit (filePath → file_path); grep/glob" do
      uses = fn part -> OpenCode.normalize(m("assistant", [part])).tool_uses end

      assert [%{name: "Read", input: %{"file_path" => "lib/p.ex"}}] =
               uses.(tool("read", %{"filePath" => "lib/p.ex"}, "completed"))

      assert [%{name: "Write", input: %{"file_path" => "lib/p.ex"}}] =
               uses.(tool("write", %{"filePath" => "lib/p.ex"}, "completed"))

      assert [%{name: "Edit", input: %{"file_path" => "lib/p.ex"}}] =
               uses.(tool("edit", %{"filePath" => "lib/p.ex"}, "completed"))

      assert [%{name: "Grep"}] = uses.(tool("grep", %{"pattern" => "x"}, "completed"))
      assert [%{name: "Glob"}] = uses.(tool("glob", %{"pattern" => "**"}, "completed"))
    end

    test "a patch part becomes one canonical Edit per file (so path signals fire)" do
      uses = OpenCode.normalize(m("assistant", [patch(["lib/a.ex", "lib/b.ex"])])).tool_uses
      assert [%{name: "Edit", input: %{"file_path" => "lib/a.ex"}}, %{name: "Edit"}] = uses
    end

    test "an unknown tool keeps its name so it still counts" do
      [tu] = OpenCode.normalize(m("assistant", [tool("webfetch", %{}, "completed")])).tool_uses
      assert %{name: "webfetch"} = tu
    end

    test "a non-binary tool name (corrupt record) coerces to UnknownTool, not a non-string name" do
      # The `tool` field should be a string; a corrupt record could carry a number. The canonical
      # name must stay a String.t() (the tool_use contract) rather than passing the raw value through.
      [tu] = OpenCode.normalize(m("assistant", [tool(123, %{}, "completed")])).tool_uses
      assert %{name: "UnknownTool"} = tu
    end

    test "a record without a role/parts degrades to an inert event (raw preserved)" do
      assert %Event{raw: %{"foo" => 1}} = OpenCode.normalize(%{"foo" => 1})
    end
  end

  # Handle disambiguation is pure filesystem logic — hermetic, no sqlite3 needed.
  describe "split_handle/1 (pure, no DB)" do
    @describetag :tmp_dir

    test "a session handle splits on the last '#'", %{tmp_dir: dir} do
      db = Path.join(dir, "opencode.db")
      File.write!(db, "")
      assert OpenCode.split_handle(db <> "#ses_abc") == {db, "ses_abc"}
    end

    test "an existing path wins outright, even when it contains '#'", %{tmp_dir: dir} do
      weird = Path.join(dir, "open#code.db")
      File.write!(weird, "")
      assert OpenCode.split_handle(weird) == {weird, nil}
    end

    test "a bare (missing) path without '#' passes through" do
      assert OpenCode.split_handle("/nope/opencode.db") == {"/nope/opencode.db", nil}
    end
  end

  # Shells out to the sqlite3 CLI against a fixture opencode.db — excluded from the hermetic run.
  describe "discover/1 + stream_file!/1 (reads the SQLite DB)" do
    @describetag :opencode
    @describetag :tmp_dir
    setup %{tmp_dir: dir} do
      db = Path.join(dir, "opencode.db")
      script = Path.join(dir, "seed.sql")
      File.write!(script, seed_sql())
      {out, code} = System.cmd("sqlite3", [db, ".read #{script}"], stderr_to_stdout: true)
      assert code == 0, out
      %{dir: dir, db: db}
    end

    test "discover yields ONE HANDLE PER SESSION, not the whole DB", %{dir: dir, db: db} do
      assert OpenCode.discover(dir) == [db <> "#ses_aux", db <> "#ses_demo"]
    end

    test "a session handle streams ONLY that session's messages", %{db: db} do
      events =
        (db <> "#ses_demo")
        |> OpenCode.stream_file!()
        |> Enum.map(fn {:ok, e} -> e end)

      assert length(events) == 6
      assert Enum.all?(events, &(&1.session_id == "ses_demo"))
      bash = events |> Enum.flat_map(& &1.tool_uses) |> Enum.filter(&(&1.name == "Bash"))
      assert length(bash) == 3

      aux = (db <> "#ses_aux") |> OpenCode.stream_file!() |> Enum.map(fn {:ok, e} -> e end)
      assert length(aux) == 2
      assert Enum.all?(aux, &(&1.session_id == "ses_aux"))
    end

    test "the degraded bare-DB handle still streams the whole history", %{db: db} do
      events = db |> OpenCode.stream_file!() |> Enum.map(fn {:ok, e} -> e end)
      assert length(events) == 8

      assert events |> Enum.map(& &1.session_id) |> Enum.uniq() |> Enum.sort() ==
               ["ses_aux", "ses_demo"]
    end

    test "a non-database file surfaces as a single {:error, _}, not a crash", %{dir: dir} do
      bogus = Path.join(dir, "not-a.db")
      File.write!(bogus, "definitely not sqlite")
      assert [{:error, %{reason: _}}] = OpenCode.stream_file!(bogus)
    end
  end

  describe "end-to-end scan (reads the SQLite DB)" do
    @describetag :opencode
    @describetag :tmp_dir
    setup %{tmp_dir: dir} do
      db = Path.join(dir, "opencode.db")
      script = Path.join(dir, "seed.sql")
      File.write!(script, seed_sql())
      {out, code} = System.cmd("sqlite3", [db, ".read #{script}"], stderr_to_stdout: true)
      assert code == 0, out
      %{dir: dir}
    end

    test "an OpenCode session scores as friction with canonical signals and file paths", %{
      dir: dir
    } do
      results = Scan.run(base: dir, format: :opencode, min_messages: 0)

      # One Result PER SESSION (the whole-DB read collapsed the history into a single row).
      assert length(results) == 2
      assert [%Scan.Result{} = r | _] = results

      assert r.session_id == "ses_demo"
      assert r.friction > 0.0
      # The patch on lib/parser.ex is canonicalized to an Edit, so the path is referenced.
      assert "lib/parser.ex" in r.file_paths
      # Two failed `mix test` runs before the fix → a Bash retry loop registers.
      assert r.signals.retry_loops >= 1
    end
  end

  # A minimal real-shaped OpenCode DB: `session`/`message`/`part` tables with JSON `data` blobs.
  # ses_demo models a retry loop (two failing `mix test`) then a patch fixing lib/parser.ex, then
  # a passing run; ses_aux is a second tiny session proving per-session handle isolation.
  defp seed_sql do
    """
    CREATE TABLE session (id TEXT PRIMARY KEY, data TEXT);
    CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT);
    CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, session_id TEXT, time_created INTEGER, data TEXT);

    INSERT INTO session VALUES ('ses_demo','{}'), ('ses_aux','{}');

    INSERT INTO message VALUES
      ('m1','ses_demo',1,'{"role":"user"}'),
      ('m2','ses_demo',2,'{"role":"assistant"}'),
      ('m3','ses_demo',3,'{"role":"assistant"}'),
      ('m4','ses_demo',4,'{"role":"assistant"}'),
      ('m5','ses_demo',5,'{"role":"assistant"}'),
      ('m6','ses_demo',6,'{"role":"assistant"}'),
      ('n1','ses_aux',7,'{"role":"user"}'),
      ('n2','ses_aux',8,'{"role":"assistant"}');

    INSERT INTO part VALUES
      ('q1','n1','ses_aux',9,'{"type":"text","text":"hello there"}'),
      ('q2','n2','ses_aux',10,'{"type":"text","text":"hi"}'),
      ('p1','m1','ses_demo',1,'{"type":"text","text":"fix the failing parser test in lib/parser.ex"}'),
      ('p2','m2','ses_demo',2,'{"type":"text","text":"I''ll run the tests."}'),
      ('p3','m2','ses_demo',3,'{"type":"tool","tool":"bash","callID":"c1","state":{"status":"error","input":{"command":"mix test test/parser_test.exs"},"error":"FunctionClauseError"}}'),
      ('p4','m3','ses_demo',4,'{"type":"tool","tool":"bash","callID":"c2","state":{"status":"error","input":{"command":"mix test test/parser_test.exs"},"error":"same FunctionClauseError"}}'),
      ('p5','m4','ses_demo',5,'{"type":"text","text":"The parser needs a guard. Patching."}'),
      ('p6','m4','ses_demo',6,'{"type":"patch","hash":"abc123","files":["lib/parser.ex"]}'),
      ('p7','m5','ses_demo',7,'{"type":"tool","tool":"bash","callID":"c3","state":{"status":"completed","input":{"command":"mix test test/parser_test.exs"},"output":"1 test, 0 failures"}}'),
      ('p8','m6','ses_demo',8,'{"type":"text","text":"Fixed — the parser now guards empty input."}');
    """
  end
end
