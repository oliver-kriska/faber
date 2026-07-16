defmodule Faber.Scan.Cache do
  @moduledoc """
  A content-addressed cache for per-session `Faber.Scan.Result`s.

  Scoring a session is a **pure function of the bytes behind its handle** — `Faber.Scan.score_session/2`
  parses the transcript and folds it through `Faber.Detect`, reading nothing else. Transcripts are
  append-only and overwhelmingly *finished*: on a real corpus (~6.6k sessions / 4 GB) only ~1.5%
  change in a given day. So the same scan gets recomputed from scratch on every dashboard mount,
  ~98% of it re-deriving results that were already correct.

  This caches that. Each session's `Result` is stored under its source's `c:Faber.Ingest.Source.stamp/1`
  and a **scorer version**; a scan reuses the entry only when both still match, and reparses
  otherwise. That turns a ~9s cold scan into a ~0.6s warm one, whose floor is the unavoidable work:
  discovering handles and stat-ing each one.

  ## This is a cache, not a store

  Everything here is recomputable, so every failure path degrades to *rescan* rather than to an
  error: no snapshot, a corrupt snapshot, a snapshot from an older format, the owner not running,
  the table missing — all simply mean cache misses. Nothing Faber can't rebuild is kept here, and
  `~/.faber/cache` can be deleted at any moment. `Faber.Proposal.Store` is the deliberate opposite:
  proposals cost tokens, so they are never invalidated on Faber's initiative.

  ## Correctness: what invalidates an entry

  Under-invalidating serves a silently wrong score, so both halves of the key fail *safe*:

    * **stamp** — the source's answer to "did the bytes change" (`{mtime, size}` for files). Cheap
      by contract, since it runs on every handle on every scan, hits included.
    * **version** — `:erlang.phash2/1` over the BEAM `md5` of every module that can change a
      `Result`, plus the adapter and format. Derived from `Application.spec(:faber, :modules)`
      rather than a hand-kept list, so a new detector or ingest format is covered the moment it
      exists, and recomputed per scan rather than memoized, so dev code reloading can't serve
      scores from a scorer that no longer exists.

  ## Shape

  A supervised owner process holds a named **public** ETS table: the scan's `Task.async_stream`
  workers read and write it directly rather than serializing ~6.6k lookups through one mailbox. The
  owner exists to give the table an OTP lifetime, to load the snapshot at boot, and to write it
  back — debounced, since a scan that misses N sessions should still only produce one disk write.
  """

  use GenServer

  alias Faber.Ingest.Source

  require Logger

  @table :faber_scan_cache
  @snapshot "scan.cache"

  # Bumped when the entry tuple or snapshot envelope changes shape. An older/newer snapshot is
  # discarded wholesale rather than migrated — it's a cache; rebuilding it costs one scan.
  #
  # `readable_formats: [format()]` is the DECISION, not an accident of pattern-matching: this store
  # holds `:derived` data, so dropping is *correct* here in a way it would be catastrophic in
  # `Faber.Proposal.Store` (which holds `:paid` data and must read every format it ever wrote).
  # Declaring it means the next person to bump this number sees the posture instead of inferring it.
  #
  # `unstamped: :unreadable` — every snapshot this store has ever written carries `format: 1` in its
  # envelope, so a term without one is not ours.
  use Faber.Store.Format,
    format: 1,
    readable_formats: [1],
    data_class: :derived,
    unstamped: :unreadable

  # Entries for sessions no scan has touched in this long are dropped when the snapshot loads.
  # Without this the table would grow forever: Claude Code deletes transcripts after ~30 days, and
  # their cached scores would otherwise outlive them by years. Pruning at load (not at write) keeps
  # it off the hot path entirely.
  @max_age_s 60 * 60 * 24 * 30

  # One scan reports dirty once, but a burst of scans (a rescan click, a loop) shouldn't each
  # rewrite a multi-MB snapshot. Coalesce them; an unflushed cache only costs a rescan.
  @flush_debounce_ms 5_000

  # Modules whose code can change a `Result`: the scorer itself, every detector, and the whole
  # ingest path that feeds it. Everything else in the app (web, eval, loop, LLM) is deliberately
  # out of scope — including it would invalidate the entire cache on every unrelated edit, which
  # in day-to-day development means never getting a hit.
  @scorer_prefixes ["Elixir.Faber.Scan", "Elixir.Faber.Detect", "Elixir.Faber.Ingest"]

  @type entry ::
          {key :: term(), Source.stamp(), version :: integer(), Faber.Scan.Result.t(), integer()}

  # ── Public API ────────────────────────────────────────────────────────────────────────────────

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Whether the cache can serve this scan: switched on, and the table actually there.

  The table check is not paranoia — it's what lets `Faber.Scan` call into the cache unconditionally
  and still work when the owner isn't running (a bare `Faber.Scan` call from a test or a script that
  never started the app). Missing table ⇒ every fetch misses ⇒ correct, just uncached.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:faber, :scan_cache, true) == true and
      :ets.whereis(@table) != :undefined
  end

  @doc """
  Look up `handle`'s cached `Result`.

  Returns `{:ok, result}` on a hit, or `{:miss, stamp}` — where `stamp` is threaded back into
  `put/5` so the caller doesn't stat the same file twice. A `nil` stamp means the handle is
  uncacheable (see `c:Faber.Ingest.Source.stamp/1`) and `put/5` will correctly ignore it.
  """
  @spec fetch(module(), Source.handle(), integer()) ::
          {:ok, Faber.Scan.Result.t()} | {:miss, Source.stamp() | nil}
  def fetch(source, handle, version) do
    if enabled?() do
      do_fetch(source, handle, version)
    else
      {:miss, nil}
    end
  end

  defp do_fetch(source, handle, version) do
    case Source.stamp(source, handle) do
      nil ->
        {:miss, nil}

      stamp ->
        key = key(source, handle)

        case :ets.lookup(@table, key) do
          [{^key, ^stamp, ^version, result, _last_seen}] ->
            # Touch on hit so a session that keeps getting scanned never ages out of the snapshot,
            # while one whose transcript was deleted eventually does.
            :ets.update_element(@table, key, {5, now()})
            {:ok, result}

          _ ->
            {:miss, stamp}
        end
    end
  rescue
    # The owner can die (or the table vanish) between `enabled?/0` and the lookup. A cache is never
    # worth failing a scan over.
    ArgumentError -> {:miss, nil}
  end

  @doc """
  Store `result` for `handle`.

  A `nil` stamp is a no-op: the source couldn't tell us when the handle changes, so anything we
  wrote could never be safely invalidated.
  """
  @spec put(module(), Source.handle(), Source.stamp() | nil, integer(), Faber.Scan.Result.t()) ::
          :ok
  def put(_source, _handle, nil, _version, _result), do: :ok

  def put(source, handle, stamp, version, result) do
    if enabled?() do
      # One entry per session, keyed without the version, so alternating adapters overwrite rather
      # than accumulate — this is what bounds the table to the size of the live corpus.
      :ets.insert(@table, {key(source, handle), stamp, version, result, now()})

      # Nudge the owner to persist. One cast per *miss*, not per session: a warm scan sends none,
      # and a cold one's ~1.6k casts collapse into a single write via `@flush_debounce_ms`. Casting
      # from the worker (rather than tallying misses in `Faber.Scan`) keeps this correct when two
      # scans overlap — neither has to know what the other missed.
      GenServer.cast(__MODULE__, :dirty)
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  The scorer version for a scan under `opts` — see the moduledoc's "what invalidates an entry".
  """
  @spec version(keyword()) :: integer()
  def version(opts \\ []) do
    :erlang.phash2({
      scorer_digest(),
      # The adapter feeds fingerprint bonuses and opportunity rules straight into the Result, so
      # hash the whole pack: any edit to it must rescore.
      opts[:adapter],
      opts[:format] || Application.get_env(:faber, :ingest_format, :claude)
    })
  end

  @doc """
  Write the snapshot now (synchronously), if there is anything new to write.

  Needed because the debounce and `terminate/2` between them do NOT cover every exit: one-shot CLI
  commands end at `System.halt/1`, an immediate VM halt that runs no supervisor shutdown and so no
  `terminate/2`. `Faber.CLI` calls this on that path — without it a `faber scan` would score the
  whole corpus and persist none of it, leaving every run cold.

  A no-op when nothing has been cached since the last write, so commands that never scan (`faber
  help`) don't rewrite a multi-MB snapshot to say the same thing.
  """
  @spec flush() :: :ok | {:error, term()}
  def flush, do: GenServer.call(__MODULE__, :flush)

  @doc """
  Drop every entry, in memory and on disk.
  """
  @spec clear() :: :ok
  def clear, do: GenServer.call(__MODULE__, :clear)

  @doc """
  Entry count — for tests and `faber` diagnostics.
  """
  @spec size() :: non_neg_integer()
  def size do
    case :ets.whereis(@table) do
      :undefined -> 0
      _ -> :ets.info(@table, :size)
    end
  end

  # ── Owner ─────────────────────────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    # trap_exit so a supervisor shutdown runs `terminate/2` and the last scan's work survives.
    Process.flag(:trap_exit, true)

    # Created synchronously in `init/1`, so the table exists the moment `start_link` returns and no
    # scan can race a half-built cache. `public` + `write_concurrency`: the scan's workers write it
    # directly from ~N schedulers.
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    # `nil` means "resolve from config at each use" rather than freezing it here — otherwise a
    # config change (a test redirecting `:cache_dir`) would silently write to wherever the process
    # happened to boot pointing.
    path = Keyword.get(opts, :path)

    # Loading decompresses and decodes a few MB; do it after init returns so it never sits in the
    # boot path. A scan arriving first just misses and rescores.
    {:ok, %{path: path, dirty: false, timer: nil}, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, state) do
    load_snapshot(path(state))
    {:noreply, state}
  end

  @impl true
  def handle_cast(:dirty, %{timer: nil} = state) do
    {:noreply,
     %{state | dirty: true, timer: Process.send_after(self(), :flush, @flush_debounce_ms)}}
  end

  def handle_cast(:dirty, state), do: {:noreply, %{state | dirty: true}}

  @impl true
  def handle_info(:flush, state) do
    write_snapshot(path(state))
    {:noreply, %{state | dirty: false, timer: nil}}
  end

  @impl true
  def handle_call(:flush, _from, %{dirty: false} = state), do: {:reply, :ok, state}

  def handle_call(:flush, _from, state) do
    result = write_snapshot(path(state))
    if state.timer, do: Process.cancel_timer(state.timer)
    {:reply, result, %{state | dirty: false, timer: nil}}
  end

  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@table)
    File.rm(path(state))
    if state.timer, do: Process.cancel_timer(state.timer)
    {:reply, :ok, %{state | dirty: false, timer: nil}}
  end

  @impl true
  def terminate(_reason, %{dirty: true} = state), do: write_snapshot(path(state))
  def terminate(_reason, _state), do: :ok

  # ── Snapshot ──────────────────────────────────────────────────────────────────────────────────

  defp path(%{path: nil}), do: Path.join(Faber.cache_dir(), @snapshot)
  defp path(%{path: path}), do: path

  defp load_snapshot(path) do
    # `binary_to_term(:safe)` refuses to invent atoms — but the snapshot is *full* of them (the
    # Result struct name, every signal name), and at boot the modules defining them may not be
    # loaded yet, which would make every load fail and the cache silently dead. Loading the scorer
    # modules first puts those atoms in the table, so `:safe` rejects only genuinely foreign ones.
    Enum.each(scorer_modules(), &Code.ensure_loaded/1)

    with {:ok, bin} <- File.read(path),
         {:ok, %{format: fmt, entries: entries}} when is_list(entries) <- decode(bin),
         true <- readable?(fmt) do
      cutoff = now() - @max_age_s

      # A comprehension, not `Enum.filter/2`: `:safe` vouches for how a term was *constructed* (no
      # new atoms, no funs, no pids) and says nothing about its *shape*. `%{format: 1, entries:
      # [:ok]}` decodes perfectly happily, and a filter fn whose head matches a 5-tuple then raises
      # FunctionClauseError. Here a non-matching entry is skipped instead — this is a cache, so a
      # dropped entry costs one rescore.
      #
      # The realistic way this fires is not an attacker, it is us: change the entry tuple's arity,
      # forget to bump @snapshot_format, and Faber's own last snapshot becomes the bad input.
      fresh = for {_k, _s, _v, _r, seen} = e <- entries, is_integer(seen), seen >= cutoff, do: e
      :ets.insert(@table, fresh)
      :ok
    else
      false ->
        # A snapshot from a different build: a format this one doesn't read. Not an error — just
        # nothing to reuse. See the `use Faber.Store.Format` above: dropping is this store's
        # declared policy, because the data is derived and rebuilding costs one scan.
        :ok

      {:ok, _unrecognized_envelope} ->
        :ok

      {:error, :enoent} ->
        :ok

      other ->
        Logger.debug(
          "faber scan cache: ignoring unreadable snapshot at #{path} — #{inspect(other)}"
        )

        :ok
    end
  rescue
    # Belt and braces around the entire load. This runs in `handle_continue/2`, so anything that
    # escapes kills the owner — and with it the app: the supervisor restarts us, we re-read the very
    # same file, and we die identically until `:one_for_one`'s restart intensity is exceeded and
    # `Faber.Supervisor` takes the endpoint down too. The file is still there next boot, so that is a
    # *persistent* outage. Nothing about warming a cache is worth that.
    e ->
      Logger.debug("faber scan cache: ignoring unusable snapshot at #{path} — #{inspect(e)}")
      :ok
  end

  defp decode(bin) do
    {:ok, :erlang.binary_to_term(bin, [:safe])}
  rescue
    # Truncated, corrupt, or carrying terms this build doesn't know. Discard and rescan.
    _ -> {:error, :corrupt}
  end

  defp write_snapshot(path) do
    entries = :ets.tab2list(@table)
    bin = :erlang.term_to_binary(%{format: format(), entries: entries}, compressed: 6)

    # Private, not just atomic. A Result carries the user's session paths, cwds and touched
    # file_paths — a map of what they work on — so the snapshot gets 0700/0600 like the eval tree
    # (f3ea23e) and secret_key_base, rather than the 0755/0644 a umask default would hand it.
    with :ok <- Faber.mkdir_private(Path.dirname(path)),
         :ok <- Faber.write_private(path, bin) do
      :ok
    else
      {:error, reason} = err ->
        Logger.warning("faber scan cache: snapshot write failed — #{inspect(reason)}")
        err
    end
  end

  # ── Keys & versioning ─────────────────────────────────────────────────────────────────────────

  # The source is part of the key: two sources can describe the same session, and their stamps are
  # not comparable.
  defp key(source, handle), do: {source, source.label(handle)}

  defp now, do: System.os_time(:second)

  defp scorer_digest do
    scorer_modules()
    |> Enum.map(fn mod ->
      if Code.ensure_loaded?(mod), do: {mod, mod.module_info(:md5)}, else: {mod, :not_loaded}
    end)
    |> :erlang.phash2()
  end

  # From the .app spec, not `:code.all_loaded/0`: module loading is lazy, so an all_loaded scan
  # would hash a different set depending on what happened to run first, and quietly miss a detector
  # that hadn't been touched yet.
  defp scorer_modules do
    :faber
    |> Application.spec(:modules)
    |> Kernel.||([])
    |> Enum.filter(fn mod ->
      mod != __MODULE__ and String.starts_with?(Atom.to_string(mod), @scorer_prefixes)
    end)
    |> Enum.sort()
  end
end
