defmodule Faber.Ingest do
  @moduledoc """
  **Stage 1 — Ingest.** Parse coding-agent session transcripts into a normalized stream of
  `Faber.Ingest.Event` structs.

  Ingest is **agent-agnostic**: it delegates the format-specific work (where transcripts live, how
  to discover them, how to decode a record) to a `Faber.Ingest.Format` implementation, and exposes
  one uniform `discover` / `stream_file!` / `parse_file` API over whichever format is selected.

  The format is resolved (in order) from the call's `:format` option, then
  `config :faber, :ingest_format`, then the default — `Faber.Ingest.Format.Claude` (Claude Code's
  `~/.claude/projects/**/*.jsonl`). v1 ships only the Claude format; Codex/OpenCode/Pi are a new
  module each behind this seam once their transcript specs are pinned down (see
  `Faber.Ingest.Format`).
  """

  alias Faber.Ingest.{Event, Format}

  @doc "The active format module (`opts[:format]` → config → Claude default)."
  @spec format(keyword()) :: module()
  def format(opts \\ []), do: Format.resolve(opts)

  @doc "The active format's default transcript base (`~`-relative; expanded on discovery)."
  @spec default_base(keyword()) :: String.t()
  def default_base(opts \\ []), do: format(opts).default_base()

  @doc """
  Discover session files. Options: `:format` (override the agent), `:base` (override the root;
  defaults to the format's `default_base/0`).
  """
  @spec discover(keyword()) :: [Path.t()]
  def discover(opts \\ []) do
    fmt = format(opts)
    base = opts[:base] || fmt.default_base()
    fmt.discover(base)
  end

  @doc """
  Stream a transcript as `{:ok, Event.t()} | {:error, map()}` per record, via the active format.

  Lazy: records are decoded on demand. Callers drive the stream (`Enum.to_list/1`,
  `Stream.filter/2`, `Task.async_stream/3`, …).
  """
  @spec stream_file!(Path.t(), keyword()) :: Enumerable.t()
  def stream_file!(path, opts \\ []), do: format(opts).stream_file!(path)

  @doc """
  Eagerly parse a transcript into `{events, errors}`.

  `events` are the successfully normalized `Event` structs in file order; `errors` are
  `%{line:, reason:}` maps for any records that failed to decode.
  """
  @spec parse_file(Path.t(), keyword()) :: {[Event.t()], [map()]}
  def parse_file(path, opts \\ []) do
    path
    |> stream_file!(opts)
    |> Enum.reduce({[], []}, fn
      {:ok, event}, {events, errors} -> {[event | events], errors}
      {:error, err}, {events, errors} -> {events, [err | errors]}
    end)
    |> then(fn {events, errors} -> {Enum.reverse(events), Enum.reverse(errors)} end)
  end

  @doc "Normalize a decoded transcript record into an `Event` via the active format."
  @spec normalize(map(), keyword()) :: Event.t()
  def normalize(map, opts \\ []) when is_map(map), do: format(opts).normalize(map)
end
