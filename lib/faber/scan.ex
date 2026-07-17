defmodule Faber.Scan do
  @moduledoc """
  Orchestrate friction detection across many sessions and rank them.

  Discovers transcripts via `Faber.Ingest`, scores each with `Faber.Detect`, and returns a
  list of `Faber.Scan.Result` sorted by friction (descending) — the input to the skill
  proposer. This is OTP's home turf: the fan-out runs under `Task.async_stream` with bounded
  concurrency, a per-session timeout, and crash isolation, so one pathological transcript
  can't take down the scan.

  Scoring is memoized by `Faber.Scan.Cache`, which is why re-running a scan over an unchanged
  corpus is cheap. The cache is transparent — it can only ever return what `score_session/2` would
  have — so it needs no cooperation from callers; pass `cache: false` to bypass it.
  """

  alias Faber.Detect
  alias Faber.Ingest.Source
  alias Faber.Scan.Cache
  alias Faber.Scan.Coalesce
  alias Faber.Scan.Scope

  defmodule Result do
    @moduledoc "Per-session friction summary produced by `Faber.Scan`."
    @type t :: %__MODULE__{
            path: Path.t(),
            session_id: String.t() | nil,
            stamp: Source.stamp() | nil,
            friction: float(),
            raw: float(),
            rate: float(),
            dominant_signal: atom() | nil,
            signals: Detect.signals(),
            fingerprint: String.t(),
            fingerprint_confidence: float(),
            opportunity: float(),
            missed: [String.t()],
            skills_used: [String.t()],
            tool_count: non_neg_integer(),
            error_count: non_neg_integer(),
            message_count: non_neg_integer(),
            human_turns: non_neg_integer(),
            parse_errors: non_neg_integer(),
            max_ctx_pct: float() | nil,
            file_paths: [String.t()],
            cwd: String.t() | nil,
            tier2: boolean(),
            hazards: [Detect.Hazard.summary()]
          }
    defstruct [
      :path,
      :session_id,
      # The source's `c:Faber.Ingest.Source.stamp/1` for this session at scoring time — "which bytes
      # this score was derived from". `nil` for a source that can't answer cheaply.
      #
      # This is the only field that tracks *content* change. Note `fingerprint` does NOT: it is a
      # six-bucket session-*type* label read off the first ten human messages, so it is effectively
      # frozen once a session opens and stays `"bug-fix"` whether the session has 6 messages or 800.
      # Anything asking "has this session moved on since?" (`Faber.Proposal.Store.stale?/2`) must
      # compare this, not that.
      :stamp,
      # The session's working directory (from the transcript), used for a clean project label —
      # the on-disk transcript path is an opaque slug (Claude) or a date dir (Codex).
      :cwd,
      :friction,
      :raw,
      :rate,
      :dominant_signal,
      :signals,
      :fingerprint,
      :fingerprint_confidence,
      :opportunity,
      :missed,
      :skills_used,
      :tool_count,
      :error_count,
      # Transcript events (user + assistant lines) vs. messages a human actually typed. These
      # differ by 20-70x on real sessions; `message_count` keeps driving the gates below, while
      # the display surfaces both. See `Faber.Detect.Friction.friction/0`.
      :message_count,
      :human_turns,
      :parse_errors,
      :max_ctx_pct,
      # File paths the session touched (edited/read/patched) — the stack signal `Faber.Adapter`
      # matches its `file_globs` against to decide whether an adapter applies to this session.
      file_paths: [],
      tier2: false,
      # Frictionless hazards, one entry per class (`Faber.Detect.Hazard.summarize/1`). NOT part of
      # the ranking and deliberately not a column beside it: a hazard says what the session *risked*,
      # not how hard it was, so a session carrying one may legitimately rank last. Each entry names
      # the hook that would intercept it — this is the input to `faber propose --hazard <kind>`.
      hazards: []
    ]
  end

  @session_timeout_ms 60_000

  @doc """
  Scan sessions and return ranked `Result`s (highest friction first).

  Options:

    * `:source` — where sessions come from: `:files` (default, walks the filesystem) or `:ccrider`
      (read ccrider's SQLite index; see `Faber.Ingest.Source`). Also `config :faber, :ingest_source`.
    * `:scope` — a `Faber.Scan.Scope` limiting the scan to one project's sessions. Absent (the
      default) ⇒ the whole corpus, unchanged. A `:project` scope both narrows discovery and drops
      scored sessions that don't belong to it; see the Scope moduledoc for why it takes both steps.
    * `:base` — transcript root (default: the ingest format's `default_base/0`); `:files` source only
    * `:db` — ccrider DB path (default `~/.config/ccrider/sessions.db`); `:ccrider` source only
    * `:format` — ingest format / agent (default `:claude`; see `Faber.Ingest.Format`)
    * `:limit` — cap how much comes back (default: all). What it caps depends on whether the scope
      could narrow discovery (see `split_limit/2`): normally it caps the sessions SCORED, sampled as
      an even spread across the corpus — never an alphabetical prefix, which would hide
      high-friction sessions. Under a project scope on a format that can't partition by project
      (Codex/Gemini/OpenCode), everything must be scored to know what's in scope, so it caps the
      RESULTS instead — the top N of the finished ranking.
    * `:min_messages` — drop sessions with fewer user+assistant messages (default `4`)
    * `:max_concurrency` — fan-out width (default `System.schedulers_online/0`)
    * `:timeout` — per-session timeout in ms (default `#{@session_timeout_ms}`)
    * `:dedupe` — collapse rows sharing a `session_id` to the richest one (default `true`)
    * `:rank_by` — `:raw` (total friction, favors long sessions; default) or `:rate`
      (`raw / message_count`, surfaces *concentrated* friction)
    * `:adapter` — an optional `%Faber.Adapter{}` whose detection vocab (contract §4.1) drives
      fingerprint command-bonuses, opportunity→skill rules, and skill-namespace extraction.
      Absent ⇒ the engine's generic defaults (adapter-free behavior, unchanged).
    * `:cache` — set `false` to rescore every session from source rather than reusing
      `Faber.Scan.Cache` (default `true`). Results are identical either way; this only trades
      time for independence from the cache.
    * `:coalesce` — set `false` to always run your own scan rather than joining an identical one
      already in flight (default `true`; see `Faber.Scan.Coalesce`). Only matters under
      concurrency — sequential calls never coalesce.
  """
  @spec run(keyword()) :: [Result.t()]
  def run(opts \\ []) do
    # Concurrent callers asking the identical question share one scan (see `Faber.Scan.Coalesce`).
    # Sequential calls never coalesce — a flight only exists while a leader is mid-scan — so this
    # cannot affect a scan-modify-scan sequence.
    if Keyword.get(opts, :coalesce, true) do
      Coalesce.run(flight_key(opts), fn -> do_run(opts) end)
    else
      do_run(opts)
    end
  end

  # Opts that change the *result*. `max_concurrency`/`timeout`/`coalesce` are deliberately excluded:
  # they affect only how the scan is executed, so two callers differing on them are still asking the
  # same question and should share an answer.
  @result_opts [
    :base,
    :format,
    :source,
    :db,
    :limit,
    :min_messages,
    :dedupe,
    :rank_by,
    :adapter,
    :cache,
    :scope
  ]

  defp flight_key(opts) do
    opts
    |> Keyword.take(@result_opts)
    |> Enum.sort()
    |> :erlang.phash2()
  end

  defp do_run(opts) do
    min_messages = Keyword.get(opts, :min_messages, 4)
    max_concurrency = Keyword.get(opts, :max_concurrency, System.schedulers_online())
    timeout = Keyword.get(opts, :timeout, @session_timeout_ms)
    dedupe = Keyword.get(opts, :dedupe, true)
    rank_by = Keyword.get(opts, :rank_by, :raw)
    scope = Keyword.get(opts, :scope)

    # A scope that knows its project's transcript directory narrows discovery through `:base`, which
    # every source already honors — so scoping needs no new discovery plumbing, just a smaller root.
    opts = Keyword.merge(opts, Scope.to_opts(scope))
    source = Source.resolve(opts)
    cache = cache_ctx(opts)
    {discover_limit, post_limit} = split_limit(opts[:limit], scope)

    source.discover(opts)
    |> maybe_take(discover_limit)
    |> Task.async_stream(&score_maybe_cached(&1, source, cache, opts),
      max_concurrency: max_concurrency,
      timeout: timeout,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Stream.filter(&match?({:ok, %Result{}}, &1))
    |> Stream.map(fn {:ok, result} -> result end)
    |> Stream.filter(&(&1.message_count >= min_messages))
    |> Stream.filter(&Scope.member?(scope, &1))
    |> Enum.to_list()
    |> dedupe(dedupe)
    # Rank by raw weighted friction (not the sigmoid score, which saturates to ~1.0 on any long
    # session). `:rank_by :rate` instead surfaces concentrated friction (raw/message). Both keep
    # `score`/`tier2` for the per-session y/n gate.
    |> Enum.sort_by(&sort_key(&1, rank_by), :desc)
    # LAST, and it has to be: `post_limit` caps the RANKING's top, so it cannot run until the
    # ranking exists. Taking N before this sorts an arbitrary sample and presents it as the top N —
    # arbitrary twice over, since the scoring stream is `ordered: false` and dedupe had not yet
    # collapsed the sidechain rows competing for those N slots.
    |> take_top(post_limit)
  end

  # Where `:limit` bites depends on whether the scope could narrow discovery.
  #
  # Narrowed (or unscoped): the discovered handles already *are* the sessions in scope, so the limit
  # caps scoring — the speed knob it was designed to be.
  #
  # Scoped but NOT narrowed (a format that doesn't partition by project): the handles are the whole
  # corpus, and membership is only knowable once a session is parsed. Capping discovery would sample
  # N sessions machine-wide and then filter them down to however few happened to be this project's —
  # usually none. So the limit moves after the filter: it stops being a speed knob (everything is
  # scored either way) and becomes a cap on results, which is the only honest reading left.
  defp split_limit(nil, _scope), do: {nil, nil}
  defp split_limit(limit, %Scope{kind: :project, base: nil}), do: {nil, limit}
  defp split_limit(limit, _scope), do: {limit, nil}

  # `nil` when caching is off/unavailable, otherwise the scorer version every entry is keyed by.
  # Computed once per scan rather than per session — it hashes ~20 modules' BEAM digests.
  defp cache_ctx(opts) do
    if Keyword.get(opts, :cache, true) and Cache.enabled?(), do: Cache.version(opts)
  end

  defp score_maybe_cached(handle, _source, nil, opts), do: score_session(handle, opts)

  defp score_maybe_cached(handle, source, version, opts) do
    case Cache.fetch(source, handle, version) do
      {:ok, result} ->
        result

      {:miss, stamp} ->
        result = score_session(handle, opts)
        Cache.put(source, handle, stamp, version, result)
        result
    end
  end

  defp sort_key(%Result{} = r, :rate), do: {r.rate, r.message_count}
  defp sort_key(%Result{} = r, _raw), do: {r.raw, r.message_count}

  # Subagent/sidechain transcripts (`isSidechain: true`) surface as near-duplicate rows that
  # share a `session_id` with their parent. Collapse each `session_id` group to its richest
  # member (most messages, then highest raw friction) so the ranking counts a session once.
  # Rows without a `session_id` can't be grouped safely, so they pass through untouched.
  defp dedupe(results, false), do: results

  defp dedupe(results, true) do
    {with_id, without_id} = Enum.split_with(results, & &1.session_id)

    deduped =
      with_id
      |> Enum.group_by(& &1.session_id)
      |> Enum.map(fn {_id, group} -> Enum.max_by(group, &{&1.message_count, &1.raw}) end)

    deduped ++ without_id
  end

  @doc """
  Score a single session into a `Result`.

  `handle` is whatever the active source yields — a file path (`:files`, the default) or a ccrider
  session descriptor (`:ccrider`). The source resolves from `opts` (or config), so the historical
  `score_session(path)` call keeps working unchanged.
  """
  @spec score_session(Source.handle(), keyword()) :: Result.t()
  def score_session(handle, opts \\ []) do
    source = Source.resolve(opts)
    adapter = opts[:adapter]
    {events, parse_errors} = source.parse(handle, opts)

    %{
      friction: f,
      fingerprint: fp,
      opportunity: op,
      context: ctx,
      hazards: hazards,
      tool_uses: tool_uses
    } = Detect.analyze(events, adapter)

    %Result{
      path: source.label(handle),
      session_id: session_id(events),
      # Re-stat rather than threading the cache's stamp in: `score_session/2` is public and called
      # directly, so it has to stand alone. Costs one extra stat per *miss* (~28µs) — nothing next
      # to the parse it sits beside, and cache hits never reach here at all.
      stamp: Source.stamp(source, handle),
      cwd: session_cwd(events),
      friction: f.score,
      raw: f.raw,
      rate: rate(f.raw, f.message_count),
      dominant_signal: f.dominant_signal,
      signals: f.signals,
      fingerprint: fp.type,
      fingerprint_confidence: fp.confidence,
      opportunity: op.score,
      missed: op.missed,
      skills_used: op.used,
      tool_count: f.tool_count,
      error_count: f.error_count,
      message_count: f.message_count,
      human_turns: f.human_turns,
      parse_errors: length(parse_errors),
      max_ctx_pct: ctx.max_ctx_pct,
      file_paths: referenced_paths(tool_uses),
      tier2: tier2?(f, op, ctx),
      hazards: Detect.Hazard.summarize(hazards)
    }
  end

  # File paths the session referenced through tool calls (Edit/Write/Read/NotebookEdit `file_path`,
  # Read/view_image `path`). Feeds `Faber.Adapter.matches_session?/2` for stack-aware gating — a
  # session that edits/reads `.ex` files matches the Elixir adapter; a Next.js one won't.
  defp referenced_paths(tool_uses) do
    tool_uses
    |> Enum.flat_map(fn
      %{input: input} when is_map(input) ->
        [input["file_path"], input["path"], input["notebook_path"]]

      _ ->
        []
    end)
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  # Tier-2 (deep qualitative analysis) eligibility, per the plugin's scoring guide: a session
  # earns the expensive pass if it's painful (friction), automatable (opportunity score or a
  # skill the user already reached for), long enough to be worth mining, or context-pressured
  # (peak prompt fill ≥ 90% of the model's window — the 5th reference trigger).
  defp tier2?(f, op, ctx) do
    f.score > 0.35 or op.score > 0.5 or op.used != [] or f.message_count > 50 or
      (is_number(ctx.max_ctx_pct) and ctx.max_ctx_pct >= 90)
  end

  defp rate(_raw, 0), do: 0.0
  defp rate(raw, message_count), do: raw / message_count

  defp session_id(events) do
    Enum.find_value(events, fn e -> e.session_id end)
  end

  # The session's working dir, taken from the first event that carries one. Codex records it only
  # on the `session_meta` line; Claude repeats it on every entry — `find_value` handles both.
  defp session_cwd(events) do
    Enum.find_value(events, fn e -> e.cwd end)
  end

  # A `:limit` caps how many sessions are scored (a speed knob). Sample an EVEN SPREAD across the
  # discovered paths, not the alphabetical prefix: `Path.wildcard/1` returns sorted paths, so a
  # prefix skews toward whatever sorts first (often tiny stub sessions) and hides the
  # highest-friction sessions entirely.
  #
  # The spread is computed by INDEX (`i * count / limit`), not by a step, because a step cannot
  # express it — and `Enum.take_every(div(count, limit)) |> Enum.take(limit)` fails in a way worth
  # spelling out, because it reads as correct.
  #
  # That pipeline visits indices `0, step, 2*step, … (limit-1)*step`, so it spans
  # `step*(limit-1)+1` paths. `step = div(count, limit)` FLOORS, so the span always falls short of
  # `count` and the tail is simply unreachable — at EVERY limit, not just some. Measured against the
  # real corpus (507 sessions, `--limit 200`): it reached index 398 of 506, so the 108 last-sorted
  # sessions could not be sampled at all, and nothing said so. At `limit > count / 2` it degenerates
  # further — the step floors to 1, `take_every(1)` keeps everything, and `take(limit)` hands back
  # precisely the alphabetical prefix this function exists to avoid.
  #
  # Both failures are the same mistake: a stride is not a ratio. One integer cannot describe
  # `count / limit` unless it divides evenly, and the remainder is paid out of the tail — which is
  # exactly where an alphabetically-sorted corpus hides the sessions this scan is looking for.
  defp maybe_take(paths, nil), do: paths

  defp maybe_take(paths, limit) when is_integer(limit) and limit > 0 do
    count = length(paths)

    if limit >= count do
      paths
    else
      keep = MapSet.new(0..(limit - 1), &div(&1 * count, limit))

      paths
      |> Enum.with_index()
      |> Enum.filter(fn {_path, i} -> MapSet.member?(keep, i) end)
      |> Enum.map(&elem(&1, 0))
    end
  end

  defp maybe_take(paths, _limit), do: paths

  # `post_limit`'s limit means something else entirely, so it must not reuse `maybe_take/2`. There
  # the input is UNRANKED paths and a spread is the honest sample; here the input is the finished
  # ranking, and a spread across it would return ranks 1, 4, 7 of 10 while calling them the top 3.
  # A cap on a ranking is a prefix, and only a prefix.
  defp take_top(results, nil), do: results

  defp take_top(results, limit) when is_integer(limit) and limit > 0,
    do: Enum.take(results, limit)

  defp take_top(results, _limit), do: results
end
