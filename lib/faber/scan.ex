defmodule Faber.Scan do
  @moduledoc """
  Orchestrate friction detection across many sessions and rank them.

  Discovers transcripts via `Faber.Ingest`, scores each with `Faber.Detect`, and returns a
  list of `Faber.Scan.Result` sorted by friction (descending) — the input to the skill
  proposer. This is OTP's home turf: the fan-out runs under `Task.async_stream` with bounded
  concurrency, a per-session timeout, and crash isolation, so one pathological transcript
  can't take down the scan.
  """

  alias Faber.Detect
  alias Faber.Ingest.Source

  defmodule Result do
    @moduledoc "Per-session friction summary produced by `Faber.Scan`."
    @type t :: %__MODULE__{
            path: Path.t(),
            session_id: String.t() | nil,
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
            parse_errors: non_neg_integer(),
            max_ctx_pct: float() | nil,
            file_paths: [String.t()],
            tier2: boolean()
          }
    defstruct [
      :path,
      :session_id,
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
      :message_count,
      :parse_errors,
      :max_ctx_pct,
      # File paths the session touched (edited/read/patched) — the stack signal `Faber.Adapter`
      # matches its `file_globs` against to decide whether an adapter applies to this session.
      file_paths: [],
      tier2: false
    ]
  end

  @session_timeout_ms 60_000

  @doc """
  Scan sessions and return ranked `Result`s (highest friction first).

  Options:

    * `:source` — where sessions come from: `:files` (default, walks the filesystem) or `:ccrider`
      (read ccrider's SQLite index; see `Faber.Ingest.Source`). Also `config :faber, :ingest_source`.
    * `:base` — transcript root (default: the ingest format's `default_base/0`); `:files` source only
    * `:db` — ccrider DB path (default `~/.config/ccrider/sessions.db`); `:ccrider` source only
    * `:format` — ingest format / agent (default `:claude`; see `Faber.Ingest.Format`)
    * `:limit` — cap the number of sessions scored, sampled as an even spread across the
      corpus (default: all). NOT an alphabetical prefix — that would hide high-friction sessions.
    * `:min_messages` — drop sessions with fewer user+assistant messages (default `4`)
    * `:max_concurrency` — fan-out width (default `System.schedulers_online/0`)
    * `:timeout` — per-session timeout in ms (default `#{@session_timeout_ms}`)
    * `:dedupe` — collapse rows sharing a `session_id` to the richest one (default `true`)
    * `:rank_by` — `:raw` (total friction, favors long sessions; default) or `:rate`
      (`raw / message_count`, surfaces *concentrated* friction)
  """
  @spec run(keyword()) :: [Result.t()]
  def run(opts \\ []) do
    min_messages = Keyword.get(opts, :min_messages, 4)
    max_concurrency = Keyword.get(opts, :max_concurrency, System.schedulers_online())
    timeout = Keyword.get(opts, :timeout, @session_timeout_ms)
    dedupe = Keyword.get(opts, :dedupe, true)
    rank_by = Keyword.get(opts, :rank_by, :raw)
    source = Source.resolve(opts)

    source.discover(opts)
    |> maybe_take(opts[:limit])
    |> Task.async_stream(&score_session(&1, opts),
      max_concurrency: max_concurrency,
      timeout: timeout,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Stream.filter(&match?({:ok, %Result{}}, &1))
    |> Stream.map(fn {:ok, result} -> result end)
    |> Stream.filter(&(&1.message_count >= min_messages))
    |> Enum.to_list()
    |> dedupe(dedupe)
    # Rank by raw weighted friction (not the sigmoid score, which saturates to ~1.0 on any long
    # session). `:rank_by :rate` instead surfaces concentrated friction (raw/message). Both keep
    # `score`/`tier2` for the per-session y/n gate.
    |> Enum.sort_by(&sort_key(&1, rank_by), :desc)
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
    {events, parse_errors} = source.parse(handle, opts)
    f = Detect.friction(events)
    fp = Detect.fingerprint(events)
    op = Detect.opportunity(events)
    ctx = Detect.context(events)

    %Result{
      path: source.label(handle),
      session_id: session_id(events),
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
      parse_errors: length(parse_errors),
      max_ctx_pct: ctx.max_ctx_pct,
      file_paths: referenced_paths(events),
      tier2: tier2?(f, op, ctx)
    }
  end

  # File paths the session referenced through tool calls (Edit/Write/Read/NotebookEdit `file_path`,
  # Read/view_image `path`). Feeds `Faber.Adapter.matches_session?/2` for stack-aware gating — a
  # session that edits/reads `.ex` files matches the Elixir adapter; a Next.js one won't.
  defp referenced_paths(events) do
    events
    |> Enum.flat_map(& &1.tool_uses)
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

  # A `:limit` caps how many sessions are scored (a speed knob). Sample an EVEN SPREAD across the
  # discovered paths, not the alphabetical prefix: `Path.wildcard/1` returns sorted paths, so a
  # prefix skews toward whatever sorts first (often tiny stub sessions) and hides the
  # highest-friction sessions entirely. `take_every` gives a deterministic cross-section.
  defp maybe_take(paths, nil), do: paths

  defp maybe_take(paths, limit) when is_integer(limit) and limit > 0 do
    step = max(div(length(paths), limit), 1)
    paths |> Enum.take_every(step) |> Enum.take(limit)
  end

  defp maybe_take(paths, _limit), do: paths
end
