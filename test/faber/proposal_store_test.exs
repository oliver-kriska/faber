defmodule Faber.ProposalStoreTest do
  @moduledoc """
  The store's contract is the inverse of the cache's: **never lose a proposal**. Every test here is
  ultimately asking "could this have cost the user tokens twice?" — so the interesting cases are
  the ones where something *else* changed (the session moved on, the same skill was proposed again,
  a neighbouring file got corrupted) and the paid artifact must survive anyway.
  """

  use ExUnit.Case, async: false

  alias Faber.Proposal.Store
  alias Faber.Scan.Result

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    # The suite runs with the store off (see config/test.exs) so async tests that propose stay
    # independent. These tests are the exception, pointed at a per-test dir.
    Application.put_env(:faber, :proposal_store, true)
    Application.put_env(:faber, :proposals_dir, Path.join(tmp_dir, "proposals"))

    on_exit(fn ->
      Application.put_env(:faber, :proposal_store, false)
      Application.delete_env(:faber, :proposals_dir)
    end)

    :ok
  end

  defp result(overrides \\ []) do
    struct(
      %Result{
        path: "/tmp/proj/abc.jsonl",
        session_id: "sess-abc",
        fingerprint: "bug-fix",
        stamp: {1_752_000_000, 4096},
        friction: 0.9,
        raw: 12.0,
        rate: 0.4,
        signals: %{},
        fingerprint_confidence: 0.8,
        opportunity: 0.5,
        message_count: 40
      },
      overrides
    )
  end

  defp proposal(name \\ "phx-debug", md \\ "# phx-debug\n\nDo the thing.\n") do
    %{name: name, md: md, eval: %{composite: 0.82, passed: true}, adapter: "faber-elixir"}
  end

  # The same base attrs with fields overridden — for the put/2 options (`:outcome`,
  # `:source_sessions`, a full `:eval`) that proposal/2's positional name+md can't reach.
  defp attrs(overrides), do: Map.merge(proposal(), overrides)

  describe "durability" do
    test "a stored proposal is readable back — the refresh bug" do
      r = result()
      assert {:ok, record} = Store.put(r, proposal())

      # The dashboard process dying (a browser refresh) changes nothing: this is a fresh read off
      # disk, with no in-memory state carried over.
      assert %{name: "phx-debug", md: md} = Store.latest(r)
      assert md =~ "Do the thing"
      assert record.id == Store.latest(r).id
    end

    test "scores read back in the shape they were written — atoms in, atoms out" do
      r = result()
      assert {:ok, _} = Store.put(r, proposal())

      # Guards the JSON round-trip: `put/2` took `%{composite: _, passed: _}`, so `latest/1` must
      # not hand back `%{"composite" => _}` for a caller to trip over.
      assert %{eval: %{composite: 0.82, passed: true}} = Store.latest(r)
    end

    test "an unrecognized score keeps its key rather than being dropped" do
      r = result()
      assert {:ok, _} = Store.put(r, %{name: "x", md: "# x\n", eval: %{"novel_metric" => 3}})

      assert %{eval: %{"novel_metric" => 3}} = Store.latest(r)
    end

    test "put/2 is durable when it returns, not eventually" do
      r = result()
      assert {:ok, record} = Store.put(r, proposal())

      # No flush, no debounce, no process to stop: the bytes are already there. This is the
      # property that lets a crash immediately after `put/2` still keep what was paid for.
      path = Path.join(Application.get_env(:faber, :proposals_dir), "#{record.id}.json")
      assert File.exists?(path)
      assert File.read!(path) =~ "phx-debug"
    end

    # put/2 and latest/1 must hand back the SAME shape for the same record. They didn't: `put/2`
    # included `:format` (a property of the file, not the proposal) and `read/1` stripped it, so a
    # caller that stored a record and a caller that re-read one disagreed. Dialyzer only caught it
    # once something pattern-matched on put/2's return — the dashboard, the only writer until the
    # CLI, ignores it.
    test "put/2 returns the same shape latest/1 does" do
      r = result()
      assert {:ok, written} = Store.put(r, proposal())

      assert written == Store.latest(r)
      refute Map.has_key?(written, :format)

      # ...and the format is still on disk, where it belongs — that's what the reader gates on.
      path = Path.join(Faber.proposals_dir(), "#{written.id}.json")
      assert %{"format" => 3} = path |> File.read!() |> Jason.decode!()
    end

    test "latest/1 returns nil for a session with no proposals" do
      assert Store.latest(result()) == nil
      assert Store.list_for(result()) == []
    end
  end

  describe "never lose a paid artifact" do
    test "re-proposing different content keeps the earlier proposal too" do
      r = result()
      assert {:ok, first} = Store.put(r, proposal("phx-debug", "# v1\n\nfirst attempt\n"))
      assert {:ok, second} = Store.put(r, proposal("phx-debug", "# v2\n\nsecond attempt\n"))

      refute first.id == second.id

      # Both were paid for, so both survive. The newer one merely wins `latest/1`.
      ids = r |> Store.list_for() |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == Enum.sort([first.id, second.id])
      assert Store.latest(r).md =~ "second attempt"
    end

    test "re-proposing identical content is idempotent, not a duplicate" do
      r = result()
      assert {:ok, a} = Store.put(r, proposal())
      assert {:ok, b} = Store.put(r, proposal())

      assert a.id == b.id
      assert length(Store.list_for(r)) == 1
    end

    test "a session that moved on keeps its proposal, flagged rather than dropped" do
      r = result(stamp: {1_752_000_000, 4096})
      assert {:ok, _} = Store.put(r, proposal())

      # The transcript has grown since the proposal was generated.
      moved_on = result(stamp: {1_752_000_900, 9001})

      record = Store.latest(moved_on)
      assert record, "a changed session must not make its paid proposal disappear"
      assert Store.stale?(record, moved_on), "and it should be reported as stale"
      refute Store.stale?(record, r)
    end

    test "staleness tracks content, not the session-type label" do
      # Regression: this compared `fingerprint`, a six-bucket label read off the first ten human
      # messages. It stays "bug-fix" from a session's 6th message to its 800th, so `stale?/2`
      # answered `false` for nearly every session that had actually moved on. A test that varies
      # `fingerprint` (as this one's predecessor did) passes against that bug; varying the content
      # stamp while holding `fingerprint` fixed is what catches it.
      before = result(fingerprint: "bug-fix", stamp: {1_752_000_000, 4096})
      assert {:ok, _} = Store.put(before, proposal())

      grew = result(fingerprint: "bug-fix", stamp: {1_752_000_900, 60_000})

      assert Store.stale?(Store.latest(grew), grew)
    end

    test "an unknown stamp is reported as not-stale, never as stale" do
      # A source that can't stamp cheaply (or a record written before stamps existed) must not have
      # every proposal permanently accused of being stale.
      r = result(stamp: nil)
      assert {:ok, _} = Store.put(r, proposal())

      refute Store.stale?(Store.latest(r), r)
      refute Store.stale?(Store.latest(r), result(stamp: {1, 2}))
    end

    test "one corrupt file does not hide the rest of a session's proposals" do
      r = result()
      assert {:ok, good} = Store.put(r, proposal("keep-me", "# keep\n"))
      assert {:ok, bad} = Store.put(r, proposal("break-me", "# break\n"))

      dir = Application.get_env(:faber, :proposals_dir)
      File.write!(Path.join(dir, "#{bad.id}.json"), "{ this is not json")

      records = Store.list_for(r)
      assert length(records) == 1
      assert hd(records).id == good.id
      assert hd(records).name == "keep-me"
    end
  end

  describe "scoping" do
    test "proposals are per session, not global" do
      a = result(session_id: "sess-a")
      b = result(session_id: "sess-b")

      assert {:ok, _} = Store.put(a, proposal("skill-a"))
      assert {:ok, _} = Store.put(b, proposal("skill-b"))

      assert Store.latest(a).name == "skill-a"
      assert Store.latest(b).name == "skill-b"
      assert length(Store.list()) == 2
    end

    test "a session without an id falls back to its path" do
      r = result(session_id: nil, path: "/tmp/proj/no-id.jsonl")
      assert {:ok, _} = Store.put(r, proposal())

      assert Store.latest(r).name == "phx-debug"
      assert Store.latest(r).session_key == "/tmp/proj/no-id.jsonl"
    end

    test "the same session reached by a different path still finds its proposal" do
      # session_id is the identity, so the :files and :ccrider sources agree on it even though
      # they label the session differently.
      via_files = result(session_id: "sess-x", path: "/home/me/.claude/projects/p/sess-x.jsonl")
      via_ccrider = result(session_id: "sess-x", path: "/work/proj/sess-x.jsonl")

      assert {:ok, _} = Store.put(via_files, proposal())
      assert Store.latest(via_ccrider).name == "phx-debug"
    end
  end

  describe "disabled" do
    test "with the store off, nothing is written and nothing is found" do
      Application.put_env(:faber, :proposal_store, false)
      r = result()

      assert {:error, :disabled} = Store.put(r, proposal())
      assert Store.latest(r) == nil
      assert Store.list() == []
    end

    test "with the store off, existing files on disk are not served" do
      r = result()
      assert {:ok, _} = Store.put(r, proposal())
      assert Store.latest(r)

      # Guards the read side specifically: a dir left from an earlier run must not leak back in
      # just because the write path is off.
      Application.put_env(:faber, :proposal_store, false)
      assert Store.latest(r) == nil
      assert Store.list_for(r) == []
    end
  end

  describe "deletion is the user's call" do
    test "delete/1 removes exactly one proposal" do
      r = result()
      assert {:ok, a} = Store.put(r, proposal("one", "# one\n"))
      assert {:ok, _b} = Store.put(r, proposal("two", "# two\n"))

      assert :ok = Store.delete(a.id)

      names = r |> Store.list_for() |> Enum.map(& &1.name)
      assert names == ["two"]
    end

    test "deleting something that isn't there is not an error" do
      assert :ok = Store.delete("nope-nope")
    end

    test "delete/1 refuses an id that isn't ours, rather than following it out of the dir" do
      # `read/1` lifts `id` straight from a proposal's JSON, so a hand-edited file can carry a
      # traversal — and `Store.delete(record.id)` is the obvious way to wire a delete button.
      victim =
        Path.join(System.tmp_dir!(), "faber_delete_probe_#{System.unique_integer([:positive])}")

      File.write!(victim, "must survive")

      assert :ok = Store.delete("../../../../../../..#{victim}")
      assert File.exists?(victim), "delete/1 escaped the proposals dir"

      File.rm(victim)
    end
  end

  describe "format 2: outcome + multi-session provenance" do
    test "defaults to a single-session outcome" do
      assert {:ok, record} = Store.put(result(), proposal())
      assert record.outcome == :single
      assert record.source_sessions == ["sess-abc"]
    end

    # The artifact that motivated the whole store: a merge is drawn from several sessions at once,
    # so `session_key` (which the id and read glob are built from) can only name one of them. Without
    # source_sessions the other originals are unrecorded — and a merge is exactly the artifact no
    # `propose --rank N` can reproduce.
    test "a merge records every session that fed it, not just the one in its id" do
      sessions = ["sess-abc", "sess-def", "sess-ghi"]

      assert {:ok, record} =
               Store.put(
                 "sess-abc",
                 attrs(%{outcome: :merged, source_sessions: sessions})
               )

      assert record.outcome == :merged
      assert record.source_sessions == sessions

      # ...and it survives the disk round-trip, which is the only part that matters.
      assert [read_back] = Store.list_for("sess-abc")
      assert read_back.outcome == :merged
      assert read_back.source_sessions == sessions
    end

    test "every outcome kind round-trips" do
      for outcome <- [:single, :merged, :kept, :kept_original] do
        assert {:ok, record} =
                 Store.put("sess-#{outcome}", attrs(%{outcome: outcome, md: "# #{outcome}\n"}))

        assert [read_back] = Store.list_for("sess-#{outcome}")
        assert read_back.outcome == outcome, "#{outcome} did not round-trip"
        assert read_back.id == record.id
      end
    end
  end

  describe "eval round-trip" do
    # :engine went in as an atom and came back as "engine" — so a writer and a reader disagreed
    # about the same map. It matters more than the rest: it separates the adapter's stack-specific
    # verdict from "native:fallback", which only certifies generic markdown structure.
    test "the full eval result keeps its atom keys, engine included" do
      eval = %{
        composite: 0.8016,
        passed: true,
        threshold: 0.75,
        dimensions: %{"clarity" => %{"score" => 0.9}},
        engine: "adapter:exec-in-place",
        schema_version: "1.0",
        weight_total: 1.0
      }

      assert {:ok, _} = Store.put(result(), attrs(%{eval: eval}))
      assert [read_back] = Store.list_for("sess-abc")

      assert read_back.eval[:engine] == "adapter:exec-in-place"
      assert read_back.eval[:composite] == 0.8016
      assert read_back.eval[:schema_version] == "1.0"
      assert read_back.eval[:weight_total] == 1.0
      refute Map.has_key?(read_back.eval, "engine")
    end

    test "a fallback engine stays distinguishable from the adapter's verdict" do
      assert {:ok, _} =
               Store.put(result(), attrs(%{eval: %{composite: 0.8, engine: "native:fallback"}}))

      assert [read_back] = Store.list_for("sess-abc")
      assert read_back.eval[:engine] == "native:fallback"
    end
  end

  describe "format compatibility" do
    # Bumping @format without teaching the reader the old one would make every artifact written
    # before the bump vanish from list/0 — read/1 drops what it cannot match, silently. In THIS
    # module that is the exact failure it exists to prevent.
    test "a format-1 record written before the bump is still readable" do
      File.mkdir_p!(Faber.proposals_dir())

      v1 = %{
        "format" => 1,
        "id" => "aaaaaaaaaaaa-bbbbbbbbbbbb",
        "session_key" => "sess-old",
        "session_path" => "/tmp/proj/old.jsonl",
        "session_stamp" => 12_345,
        "name" => "paid-for-skill",
        "md" => "---\nname: paid-for-skill\n---\n# Paid\n",
        "eval" => %{"composite" => 0.81, "passed" => true},
        "adapter" => "faber-elixir",
        "created_at" => "2026-07-01T00:00:00Z"
      }

      Faber.proposals_dir()
      |> Path.join("aaaaaaaaaaaa-bbbbbbbbbbbb.json")
      |> File.write!(Jason.encode!(v1))

      # list/0, not list_for/1: the read glob is keyed on `hash(session_key)`, which this test
      # cannot reproduce from outside the module — and a filename it can't predict would make the
      # assertion pass on a glob miss rather than on the reader accepting format 1.
      assert [record] = Store.list()
      assert record.name == "paid-for-skill"
      assert record.md == "---\nname: paid-for-skill\n---\n# Paid\n"
      assert record.eval[:composite] == 0.81

      # v1 predates both fields, so they take the defaults its shape implies: it can only have been
      # a single-session draft (the CLI wasn't a writer yet, and the dashboard proposes one session).
      assert record.outcome == :single
      assert record.source_sessions == ["sess-old"]

      # v1 also predates `kind`. It reads as :skill because its BYTES say so (`---` frontmatter),
      # not because :skill is the default — see the hook case below, where that distinction is the
      # whole point.
      assert record.kind == :skill
      assert record.event == nil
    end

    test "a format-2 HOOK still reads as a hook — kind is inferred from its bytes, not defaulted" do
      # The B4 back-compat edge, and the reason `decode_kind/2` sniffs instead of defaulting. Hooks
      # shipped under format 2, which had no `kind` column, so records like this one are already on
      # disk. Defaulting a missing `kind` to `:skill` would be the *same* `nil`-means-not-a-hook
      # reading that caused B4 — it would restore this bash script as a skill card whose Install
      # writes it to `~/.claude/skills/<name>/SKILL.md`. The artifact says what it is: the renderer
      # guarantees `#!` on line 1.
      File.mkdir_p!(Faber.proposals_dir())

      v2 = %{
        "format" => 2,
        "id" => "cccccccccccc-dddddddddddd",
        "session_key" => "sess-hook",
        "session_path" => "/tmp/proj/hook.jsonl",
        "session_stamp" => 999,
        "name" => "no-masked-gate-exit",
        "md" =>
          "#!/usr/bin/env bash\n# no-masked-gate-exit — guards a gate\nset -uo pipefail\nexit 0\n",
        "eval" => %{"composite" => 0.95, "passed" => true},
        "adapter" => "faber-elixir",
        "created_at" => "2026-07-16T00:00:00Z"
      }

      Faber.proposals_dir()
      |> Path.join("cccccccccccc-dddddddddddd.json")
      |> File.write!(Jason.encode!(v2))

      assert [record] = Store.list()

      assert record.kind == :hook,
             "a format-2 hook came back as a skill — B4, for records on disk"

      # But its pointer genuinely wasn't stored, and that cannot be sniffed back out. Absent, not
      # guessed — `Install.Hook.install/2` refuses with `:no_pointer` and the UI says re-propose.
      assert record.event == nil
      assert record.matcher == nil
    end

    test "a record from an unknown FUTURE format is skipped, not crashed on" do
      File.mkdir_p!(Faber.proposals_dir())

      Faber.proposals_dir()
      |> Path.join("cccccccccccc-dddddddddddd.json")
      |> File.write!(Jason.encode!(%{"format" => 99, "session_key" => "sess-future"}))

      # Again list/0 — the point is that the READER rejects format 99, and a hash-keyed glob would
      # return [] without ever opening the file.
      assert Store.list() == []

      # ...and it doesn't blind the reader to a readable neighbour.
      assert {:ok, _} = Store.put(result(), proposal())
      assert [only] = Store.list()
      assert only.name == "phx-debug"
    end
  end

  describe "prune/1 — the only thing that removes a proposal" do
    defp seed(n) do
      for i <- 1..n do
        {:ok, record} = Store.put("sess-#{i}", attrs(%{md: "# skill #{i}\n", name: "skill-#{i}"}))

        # created_at has second-ish resolution; stamp explicit times so newest-first is deterministic
        # rather than dependent on how fast the loop ran.
        path = Path.join(Faber.proposals_dir(), "#{record.id}.json")
        raw = path |> File.read!() |> Jason.decode!()

        File.write!(
          path,
          Jason.encode!(Map.put(raw, "created_at", "2026-07-#{pad(i)}T00:00:00Z"))
        )

        record
      end
    end

    defp pad(i), do: String.pad_leading(to_string(i), 2, "0")

    test "keeps the newest N and returns exactly what it removed" do
      seed(5)

      dropped = Store.prune(2)

      assert length(dropped) == 3
      # The oldest three went...
      assert Enum.map(dropped, & &1.name) |> Enum.sort() == ["skill-1", "skill-2", "skill-3"]
      # ...and the newest two stayed.
      assert Store.list() |> Enum.map(& &1.name) |> Enum.sort() == ["skill-4", "skill-5"]
    end

    test "pruning to more than exists removes nothing" do
      seed(3)
      assert Store.prune(50) == []
      assert length(Store.list()) == 3
    end

    test "the files are actually gone, not just hidden from list/0" do
      seed(3)
      Store.prune(1)

      assert Faber.proposals_dir() |> Path.join("*.json") |> Path.wildcard() |> length() == 1
    end

    # The store's contract (see its moduledoc table): nothing is evicted, expired, or invalidated on
    # Faber's initiative. Reading and writing must never remove anything — only an explicit prune.
    test "ordinary reads and writes never remove a proposal" do
      seed(3)

      _ = Store.list()
      _ = Store.latest("sess-1")
      {:ok, _} = Store.put("sess-4", attrs(%{md: "# new\n"}))

      assert length(Store.list()) == 4
    end
  end

  describe "privacy" do
    test "proposal files and their dir are not world-readable" do
      # Same class of data as f3ea23e: a proposal carries LLM output plus the session's path.
      r = result()
      assert {:ok, record} = Store.put(r, proposal())

      path = Path.join(Faber.proposals_dir(), "#{record.id}.json")
      assert %File.Stat{mode: mode} = File.stat!(path)
      assert Bitwise.band(mode, 0o077) == 0, "proposal is group/other readable"

      assert %File.Stat{mode: dir_mode} = File.stat!(Faber.proposals_dir())
      assert Bitwise.band(dir_mode, 0o077) == 0, "proposals dir is group/other accessible"
    end
  end
end
