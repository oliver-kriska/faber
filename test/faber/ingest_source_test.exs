defmodule Faber.Ingest.SourceTest do
  use ExUnit.Case, async: true

  alias Faber.Ingest.Source
  alias Faber.Scan
  alias Faber.Scan.Result

  @fixtures Path.expand("../fixtures", __DIR__)

  describe "resolve/1" do
    test "defaults to the filesystem source" do
      assert Source.resolve([]) == Source.Files
    end

    test "resolves the :ccrider alias and a module directly" do
      assert Source.resolve(source: :ccrider) == Source.Ccrider
      assert Source.resolve(source: Source.Files) == Source.Files
    end

    test "raises on an unknown source alias" do
      assert_raise ArgumentError, ~r/unknown ingest source/, fn ->
        Source.resolve(source: :nope)
      end
    end
  end

  describe "Source.Files (the default) is unchanged behavior" do
    test "discover + parse + label go through Faber.Ingest" do
      handles = Source.Files.discover(base: @fixtures)
      assert Enum.any?(handles, &(&1 =~ "sample_session.jsonl"))

      path = Enum.find(handles, &(&1 =~ "sample_session.jsonl"))
      assert Source.Files.label(path) == path
      assert {events, []} = Source.Files.parse(path, [])
      assert length(events) > 0
    end

    test "Scan.run with the default source matches an explicit source: :files" do
      default = Scan.run(base: @fixtures, min_messages: 0)
      explicit = Scan.run(base: @fixtures, min_messages: 0, source: :files)
      assert Enum.map(default, & &1.path) == Enum.map(explicit, & &1.path)
    end
  end

  # Shells out to the sqlite3 CLI against a fixture ccrider DB — excluded from the hermetic run.
  describe "Source.Ccrider (reads ccrider's SQLite index)" do
    @describetag :ccrider
    @describetag :tmp_dir
    setup %{tmp_dir: dir} do
      db = Path.join(dir, "sessions.db")
      script = Path.join(dir, "seed.sql")
      File.write!(script, seed_sql())
      {out, code} = System.cmd("sqlite3", [db, ".read #{script}"], stderr_to_stdout: true)
      assert code == 0, out
      %{db: db}
    end

    test "scans a claude session from the DB at full fidelity (usage, tools, errors)", %{db: db} do
      results = Scan.run(source: :ccrider, db: db, min_messages: 0)

      # The codex session is filtered out (its content is empty in ccrider) — only claude remains.
      assert [%Result{} = r] = results
      assert r.session_id == "sess-ccrider-1"
      # label/1 derives a path-like id from the session's project_path.
      assert r.path =~ "demo"
      assert r.message_count == 5
      # tool_result is_error blocks survived the envelope round-trip.
      assert r.error_count == 2
      assert r.tool_count == 2
      # `usage` survived too → context-pressure computed (190k / 200k window = 95%).
      assert r.max_ctx_pct == 95.0
      assert r.tier2
    end

    test "score_session/2 parses one handle directly via the source", %{db: db} do
      [handle] = Source.Ccrider.discover(db: db)

      assert %Result{session_id: "sess-ccrider-1", error_count: 2} =
               Scan.score_session(handle, source: :ccrider, db: db)
    end
  end

  defp seed_sql do
    """
    CREATE TABLE sessions (id INTEGER PRIMARY KEY, session_id TEXT, project_path TEXT, provider TEXT);
    CREATE TABLE messages (id INTEGER PRIMARY KEY, session_id INTEGER, type TEXT, content TEXT,
      uuid TEXT, parent_uuid TEXT, timestamp TEXT, is_sidechain INTEGER, sequence INTEGER);

    INSERT INTO sessions VALUES (1,'sess-ccrider-1','/Users/x/Projects/demo','claude');
    INSERT INTO sessions VALUES (2,'sess-codex','/Users/x/Projects/other','codex');

    INSERT INTO messages (session_id,type,content,uuid,sequence,is_sidechain) VALUES
      (1,'user','{"role":"user","content":"please fix the failing build"}','u1',1,0),
      (1,'assistant','{"role":"assistant","model":"claude-opus-4-8","content":[{"type":"tool_use","name":"Bash","input":{"command":"mix test"},"id":"t1"}],"usage":{"input_tokens":190000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}','a1',2,0),
      (1,'user','{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","is_error":true}]}','u2',3,0),
      (1,'assistant','{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"mix test"},"id":"t2"}]}','a2',4,0),
      (1,'user','{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","is_error":true}]}','u3',5,0);

    -- codex row with empty content (as the real DB stores it) — must be filtered out by provider.
    INSERT INTO messages (session_id,type,content,uuid,sequence,is_sidechain) VALUES
      (2,'user','','c1',1,0);
    """
  end
end
