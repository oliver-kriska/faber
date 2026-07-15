defmodule Faber.ScanCacheTest do
  @moduledoc """
  The cache's contract is "faster, never different". These tests are mostly about the *never
  different* half — a cache that serves one stale score is worse than no cache at all, because the
  dashboard would rank a session on evidence that no longer exists and nothing would look wrong.
  """

  # async: false throughout — the table is a VM-global named ETS table, and these tests own it.
  use ExUnit.Case, async: false

  alias Faber.Ingest.Source
  alias Faber.Scan
  alias Faber.Scan.Cache

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    # The suite runs with `:scan_cache` off (see config/test.exs) so the rest of it scores from
    # source. These tests are the exception and turn it on, pointed at a per-test dir.
    Application.put_env(:faber, :scan_cache, true)
    Application.put_env(:faber, :cache_dir, Path.join(tmp_dir, "cache"))
    Cache.clear()

    on_exit(fn ->
      Application.put_env(:faber, :scan_cache, false)
      Application.delete_env(:faber, :cache_dir)
    end)

    corpus = Path.join(tmp_dir, "corpus")
    File.mkdir_p!(Path.join(corpus, "proj"))
    {:ok, corpus: corpus}
  end

  # A transcript with enough shape for Detect to produce a non-trivial score.
  defp write_transcript(corpus, name, turns) do
    path = Path.join([corpus, "proj", name])

    lines =
      for i <- 1..turns do
        [
          %{
            "type" => "user",
            "uuid" => "u#{i}-#{name}",
            "sessionId" => name,
            "cwd" => "/tmp/proj",
            "message" => %{"role" => "user", "content" => "do the thing #{i}"}
          },
          %{
            "type" => "assistant",
            "uuid" => "a#{i}-#{name}",
            "sessionId" => name,
            "cwd" => "/tmp/proj",
            "message" => %{
              "role" => "assistant",
              "content" => [%{"type" => "text", "text" => "error: it failed #{i}"}]
            }
          }
        ]
      end

    File.write!(path, lines |> List.flatten() |> Enum.map_join("\n", &Jason.encode!/1))
    path
  end

  defp scan(corpus, extra \\ []) do
    Scan.run(Keyword.merge([base: corpus, min_messages: 0, dedupe: false], extra))
  end

  describe "transparency" do
    test "a warm scan returns exactly what a cold scan did", %{corpus: corpus} do
      for i <- 1..5, do: write_transcript(corpus, "s#{i}.jsonl", i * 2)

      cold = scan(corpus)
      assert Cache.size() == 5

      warm = scan(corpus)

      # Not "equivalent" — identical. The cache has no license to reorder, round, or drop anything.
      assert warm == cold
    end

    test "a cached scan agrees with one that bypasses the cache entirely", %{corpus: corpus} do
      for i <- 1..5, do: write_transcript(corpus, "s#{i}.jsonl", i * 2)

      cached = scan(corpus)
      bypassed = scan(corpus, cache: false)

      assert cached == bypassed
    end

    test "cache: false neither reads nor writes the table", %{corpus: corpus} do
      write_transcript(corpus, "s1.jsonl", 4)

      scan(corpus, cache: false)

      assert Cache.size() == 0
    end
  end

  describe "invalidation" do
    test "appending to a transcript rescores it", %{corpus: corpus} do
      path = write_transcript(corpus, "s1.jsonl", 3)
      [before] = scan(corpus)

      # Append more friction. `File.touch!` with a future mtime because the append may land inside
      # the filesystem's mtime granularity — the point here is to prove the *rescore* happens, and
      # the size half of the stamp is what catches this case in the wild.
      File.write!(
        path,
        "\n" <>
          Jason.encode!(%{
            "type" => "user",
            "uuid" => "u99",
            "sessionId" => "s1.jsonl",
            "cwd" => "/tmp/proj",
            "message" => %{"role" => "user", "content" => "still broken, error again"}
          }),
        [:append]
      )

      [rescored] = scan(corpus)

      assert rescored.message_count > before.message_count,
             "an appended transcript must not serve its pre-append score"
    end

    test "an in-place rewrite that preserves size is still caught", %{corpus: corpus} do
      path = write_transcript(corpus, "s1.jsonl", 3)
      scan(corpus)
      assert {:ok, _} = Cache.fetch(Source.Files, path, Cache.version())

      # Same byte count, different content: only the mtime half of the stamp can catch this, which
      # is why the stamp is {mtime, size} and not size alone.
      original = File.read!(path)
      swapped = String.replace(original, "do the thing 1", "do the thing 9")
      assert byte_size(swapped) == byte_size(original)

      File.write!(path, swapped)
      File.touch!(path, System.os_time(:second) + 10)

      # Probed *before* rescanning — a fetch after the scan would hit no matter what, because the
      # scan itself refreshes the entry. This is the assertion that would actually catch a stamp
      # that ignored mtime.
      assert {:miss, _} = Cache.fetch(Source.Files, path, Cache.version())
    end

    test "a changed scorer version invalidates every entry", %{corpus: corpus} do
      path = write_transcript(corpus, "s1.jsonl", 3)
      scan(corpus)

      # Simulate a Detect edit: same file, different version.
      assert {:ok, _} = Cache.fetch(Source.Files, path, Cache.version())
      assert {:miss, _} = Cache.fetch(Source.Files, path, Cache.version() + 1)
    end

    test "version tracks the adapter, since it feeds the Result", %{corpus: _corpus} do
      base = Cache.version()
      with_adapter = Cache.version(adapter: %Faber.Adapter{name: "x"})

      refute base == with_adapter
    end

    test "a deleted transcript simply disappears from results", %{corpus: corpus} do
      path = write_transcript(corpus, "s1.jsonl", 3)
      write_transcript(corpus, "s2.jsonl", 3)
      assert length(scan(corpus)) == 2

      File.rm!(path)

      # discover/1 no longer yields it, so a lingering entry can't resurrect it.
      assert length(scan(corpus)) == 1
    end
  end

  describe "uncacheable sources" do
    test "a stampless source is never cached, even end to end", %{corpus: corpus} do
      write_transcript(corpus, "s1.jsonl", 3)
      opts = [base: corpus, min_messages: 0, dedupe: false, source: StamplessSource]

      # The unit half: a nil stamp makes put/5 a no-op.
      assert {:miss, nil} = Cache.fetch(StamplessSource, "anything", Cache.version())
      assert :ok = Cache.put(StamplessSource, "anything", nil, Cache.version(), :whatever)
      assert Cache.size() == 0

      # The end-to-end half, which the previous version of this test only claimed to do: it called
      # the `scan/2` helper, which resolves the DEFAULT :files source — so it re-proved "a normal
      # scan caches" and never drove a stampless source through Scan.score_maybe_cached/4 at all.
      # StamplessSource discovers and parses exactly like Files; it just can't stamp.
      assert [_] = Scan.run(opts)
      assert Cache.size() == 0, "a source that cannot stamp must never be cached"

      # ...and it still returns the same answer as the cacheable source, just without the speedup.
      assert [stampless] = Scan.run(opts)
      assert [cached] = scan(corpus)
      assert stampless.message_count == cached.message_count
    end

    test "a cacheable source is still cached (the control for the test above)", %{corpus: corpus} do
      write_transcript(corpus, "s1.jsonl", 3)

      scan(corpus)
      assert Cache.size() == 1
    end
  end

  describe "snapshot" do
    test "entries survive the owner restarting", %{corpus: corpus} do
      # Distinct turn counts so the ranking is total, which keeps this comparison from flapping:
      # `Task.async_stream(ordered: false)` returns in completion order, so any tie in the sort key
      # is broken arbitrarily.
      #
      # Precisely: these synthetic transcripts drive none of Friction's six signals (no tool_uses,
      # no correction phrasing, no compactions), so every one of them scores `raw = 0.0` and the
      # ONLY thing separating them is `message_count` — the second element of `Scan.sort_key/2`'s
      # `{raw, message_count}`. So the invariant is distinct message_count, not distinct friction.
      # A refactor that drops message_count from sort_key/2 would silently reintroduce the flake.
      for i <- 1..3, do: write_transcript(corpus, "s#{i}.jsonl", i * 2)

      cold = scan(corpus)
      assert :ok = Cache.flush()

      # Kill the owner; the table dies with it and the supervisor restarts it, which reloads the
      # snapshot. This is the real boot path, not a stubbed one.
      restart_owner()

      assert Cache.size() == 3, "the snapshot did not come back"
      assert scan(corpus) == cold
    end

    test "a corrupt snapshot degrades to an empty cache, not a crash", %{
      corpus: corpus,
      tmp_dir: tmp_dir
    } do
      for i <- 1..3, do: write_transcript(corpus, "s#{i}.jsonl", 3)
      scan(corpus)
      assert :ok = Cache.flush()

      snapshot = Path.join([tmp_dir, "cache", "scan.cache"])
      assert File.exists?(snapshot)
      File.write!(snapshot, "this is not a term, it is a truncated mess")

      restart_owner()

      assert Cache.size() == 0
      # And the scan still works — it just pays full price.
      assert length(scan(corpus)) == 3
    end

    test "a well-formed snapshot of the wrong shape does not kill the owner", %{
      corpus: corpus,
      tmp_dir: tmp_dir
    } do
      # `:safe` vouches for how a term was CONSTRUCTED, not for its SHAPE: this uses only
      # pre-existing atoms, so binary_to_term accepts it and decode/1's rescue never fires. The
      # entries then fail to match the 5-tuple the loader expects.
      #
      # This is not a hypothetical attacker — it is what Faber's own snapshot looks like the day
      # someone changes the entry tuple's arity and forgets to bump @snapshot_format.
      #
      # The stakes are the reason this test exists: load_snapshot/1 runs in handle_continue/2, so a
      # raise kills the owner, the supervisor restarts it, it re-reads the SAME file and dies again
      # — until :one_for_one's restart intensity is exceeded and Faber.Supervisor takes the whole
      # app (endpoint included) down. The file survives reboots, so the outage is permanent.
      snapshot = Path.join([tmp_dir, "cache", "scan.cache"])
      File.mkdir_p!(Path.dirname(snapshot))

      File.write!(
        snapshot,
        :erlang.term_to_binary(%{format: 1, entries: [:ok, :error]}, compressed: 6)
      )

      restart_owner()

      # Alive, empty, and still scanning — a bad snapshot is a cache miss, never an outage.
      assert Process.alive?(Process.whereis(Cache))
      assert Cache.size() == 0

      for i <- 1..3, do: write_transcript(corpus, "s#{i}.jsonl", i * 2)
      assert length(scan(corpus)) == 3
    end

    test "snapshot and cache dir are private, not world-readable", %{corpus: corpus} do
      # Same class of data as f3ea23e ("write the scored skill private, not world-readable"): a
      # Result carries the user's session paths, cwds and touched file_paths.
      write_transcript(corpus, "s1.jsonl", 4)
      scan(corpus)
      assert :ok = Cache.flush()

      snapshot = Path.join(Faber.cache_dir(), "scan.cache")
      assert File.exists?(snapshot)

      assert %File.Stat{mode: mode} = File.stat!(snapshot)
      assert Bitwise.band(mode, 0o077) == 0, "snapshot is group/other readable"

      assert %File.Stat{mode: dir_mode} = File.stat!(Faber.cache_dir())
      assert Bitwise.band(dir_mode, 0o077) == 0, "cache dir is group/other accessible"
    end

    test "a missing snapshot is not an error", %{corpus: corpus, tmp_dir: tmp_dir} do
      # Must restart the owner, not just call `clear/0`. load_snapshot/1 — and its
      # `{:error, :enoent} -> :ok` branch, which is the whole point of this test — runs ONLY from
      # handle_continue(:load, ...) at init. The previous version called `Cache.clear/0` and
      # asserted on an empty scan, so the enoent branch was never reached: `raise "boom"` in it
      # would not have failed the test.
      for i <- 1..2, do: write_transcript(corpus, "s#{i}.jsonl", i * 2)
      scan(corpus)
      assert :ok = Cache.flush()

      snapshot = Path.join([tmp_dir, "cache", "scan.cache"])
      assert File.exists?(snapshot)
      File.rm!(snapshot)

      restart_owner()

      assert Process.alive?(Process.whereis(Cache))
      assert Cache.size() == 0
      assert length(scan(corpus)) == 2
    end
  end

  describe "persisting on the one-shot CLI exit path" do
    # `System.halt/1` cannot be exercised in a test (it takes the runner's VM with it), so these
    # drive `Faber.CLI.persist/0` — the seam the halt path calls — exactly as `guarded/1` is tested.

    test "a one-shot command's scan survives the exit", %{corpus: corpus, tmp_dir: tmp_dir} do
      for i <- 1..3, do: write_transcript(corpus, "s#{i}.jsonl", i * 2)
      cold = scan(corpus)

      snapshot = Path.join([tmp_dir, "cache", "scan.cache"])
      refute File.exists?(snapshot), "nothing should be written before the exit path runs"

      # Everything a one-shot `faber scan` does between finishing its work and halting.
      assert :ok = Faber.CLI.persist()
      assert File.exists?(snapshot)

      # The proof that matters is not that a file appeared but that the next process gets the work:
      # a debounce that never fires and a terminate/2 that never runs both leave a cold cache.
      restart_owner()
      assert Cache.size() == 3, "the next `faber scan` would rescore the whole corpus"
      assert scan(corpus) == cold
    end

    test "persisting cannot fail a command, even with the cache owner gone", %{corpus: corpus} do
      write_transcript(corpus, "s1.jsonl", 3)
      scan(corpus)

      :ok = Supervisor.terminate_child(Faber.Supervisor, Cache)
      on_exit(fn -> Supervisor.restart_child(Faber.Supervisor, Cache) end)

      # A cache that cannot persist is a slower next run. It must never raise on the way out and
      # strand the VM short of its System.halt/1.
      assert :ok = Faber.CLI.persist()
    end
  end

  describe "disabled" do
    test "with the cache off, scanning still works and stores nothing", %{corpus: corpus} do
      write_transcript(corpus, "s1.jsonl", 3)
      Application.put_env(:faber, :scan_cache, false)

      refute Cache.enabled?()
      assert length(scan(corpus)) == 1
      assert Cache.size() == 0
    end
  end

  # Restart the owner through its supervisor rather than `GenServer.stop/1`.
  #
  # Two reasons, both learned the hard way. (1) `GenServer.stop/1` counts as a crash against
  # `:one_for_one`'s restart intensity — the default is 3 restarts in 5 seconds, and this file has
  # four tests that need a fresh owner. They run in well under 5s, so the fourth tipped
  # `Faber.Supervisor` over and it took the whole tree down, failing unrelated tests. (2)
  # terminate/restart_child are synchronous, so there is no poll-until-registered race, and the
  # `{:continue, :load}` is guaranteed done before the `:sys.get_state/1` below returns.
  defp restart_owner do
    :ok = Supervisor.terminate_child(Faber.Supervisor, Cache)
    {:ok, pid} = Supervisor.restart_child(Faber.Supervisor, Cache)
    # A sync call drains the mailbox, so handle_continue(:load, ...) has definitely run.
    _ = :sys.get_state(pid)
    :ok
  end
end

defmodule StamplessSource do
  @moduledoc """
  A source identical to `Faber.Ingest.Source.Files` except that it cannot answer `stamp/1`.

  Delegates discover/parse/label rather than returning empties, so a scan through it does real work
  and the "never cached" assertion is about the cache wiring rather than about an empty corpus.
  """
  @behaviour Faber.Ingest.Source

  alias Faber.Ingest.Source.Files

  @impl true
  defdelegate discover(opts), to: Files
  @impl true
  defdelegate parse(handle, opts), to: Files
  @impl true
  defdelegate label(handle), to: Files
end
