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
