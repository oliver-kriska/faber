defmodule Faber.Scan do
  @moduledoc """
  Orchestrate friction detection across many sessions and rank them.

  Discovers transcripts via `Faber.Ingest`, scores each with `Faber.Detect`, and returns a
  list of `Faber.Scan.Result` sorted by friction (descending) — the input to the skill
  proposer. This is OTP's home turf: the fan-out runs under `Task.async_stream` with bounded
  concurrency, a per-session timeout, and crash isolation, so one pathological transcript
  can't take down the scan.
  """

  alias Faber.{Detect, Ingest}

  defmodule Result do
    @moduledoc "Per-session friction summary produced by `Faber.Scan`."
    @type t :: %__MODULE__{
            path: Path.t(),
            session_id: String.t() | nil,
            friction: float(),
            raw: float(),
            dominant_signal: atom() | nil,
            signals: Detect.signals(),
            tool_count: non_neg_integer(),
            error_count: non_neg_integer(),
            message_count: non_neg_integer(),
            parse_errors: non_neg_integer(),
            tier2: boolean()
          }
    defstruct [
      :path,
      :session_id,
      :friction,
      :raw,
      :dominant_signal,
      :signals,
      :tool_count,
      :error_count,
      :message_count,
      :parse_errors,
      :tier2
    ]
  end

  @default_base "~/.claude/projects"
  @session_timeout_ms 60_000

  @doc """
  Scan sessions and return ranked `Result`s (highest friction first).

  Options:

    * `:base` — transcript root (default `#{@default_base}`)
    * `:limit` — cap the number of sessions scored (default: all)
    * `:min_messages` — drop sessions with fewer user+assistant messages (default `4`)
    * `:max_concurrency` — fan-out width (default `System.schedulers_online/0`)
    * `:timeout` — per-session timeout in ms (default `#{@session_timeout_ms}`)
  """
  @spec run(keyword()) :: [Result.t()]
  def run(opts \\ []) do
    base = Keyword.get(opts, :base, @default_base)
    min_messages = Keyword.get(opts, :min_messages, 4)
    max_concurrency = Keyword.get(opts, :max_concurrency, System.schedulers_online())
    timeout = Keyword.get(opts, :timeout, @session_timeout_ms)

    base
    |> Ingest.discover()
    |> maybe_take(opts[:limit])
    |> Task.async_stream(&score_session/1,
      max_concurrency: max_concurrency,
      timeout: timeout,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Stream.filter(&match?({:ok, %Result{}}, &1))
    |> Stream.map(fn {:ok, result} -> result end)
    |> Stream.filter(&(&1.message_count >= min_messages))
    # Rank by raw weighted friction, not the sigmoid score: the score saturates to ~1.0 on
    # any long session, so it can't order high-friction sessions against each other. raw is
    # monotonic and discriminates. (`score`/`tier2` remain for the per-session y/n gate.)
    |> Enum.sort_by(&{&1.raw, &1.message_count}, :desc)
  end

  @doc """
  Score a single session file into a `Result`.
  """
  @spec score_session(Path.t()) :: Result.t()
  def score_session(path) do
    {events, parse_errors} = Ingest.parse_file(path)
    f = Detect.friction(events)

    %Result{
      path: path,
      session_id: session_id(events),
      friction: f.score,
      raw: f.raw,
      dominant_signal: f.dominant_signal,
      signals: f.signals,
      tool_count: f.tool_count,
      error_count: f.error_count,
      message_count: f.message_count,
      parse_errors: length(parse_errors),
      tier2: tier2?(f)
    }
  end

  # Tier-2 (deep qualitative analysis) eligibility, per the plugin's scoring guide. The
  # opportunity-score and plugin-commands-used criteria arrive with opportunity scoring.
  defp tier2?(f), do: f.score > 0.35 or f.message_count > 50

  defp session_id(events) do
    Enum.find_value(events, fn e -> e.session_id end)
  end

  defp maybe_take(paths, nil), do: paths
  defp maybe_take(paths, limit) when is_integer(limit), do: Enum.take(paths, limit)
end
