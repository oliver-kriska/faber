defmodule Faber.Ingest.Source.Ccrider do
  @moduledoc """
  Opt-in ingest source: [ccrider](https://github.com/neilberkman/ccrider)'s SQLite session index.

  ccrider is a Go CLI that incrementally imports Claude Code (and Codex) sessions into
  `~/.config/ccrider/sessions.db`. Reading from it instead of walking `~/.claude/projects` gives
  Faber: sessions Claude Code has already cleaned up (30-day deletion — ccrider keeps them),
  incremental import, and dedup, for free.

  **Full fidelity, no new dependency.** ccrider stores the *raw inner message JSON* in
  `messages.content` (model, `usage` token counts, and `tool_use`/`tool_result` blocks), so every
  Faber signal — including context-pressure — is recoverable. We rebuild the JSONL envelope per row
  and run it through the **Claude** `Faber.Ingest.Format`. Access is via the `sqlite3` CLI in `-json`
  mode (read-only) — ccrider users already have it — so the engine takes on no `exqlite`/NIF
  dependency and the single-binary stays lean.

  **Claude only (for now).** Probing a real DB shows ccrider stores codex rows' `content` as empty
  (only `text_content` is populated for codex), so tool/usage structure isn't recoverable for codex
  here. `discover/1` therefore filters to `provider = 'claude'`; a real cross-agent path needs either
  upstream ccrider changes or a native Codex format reading `~/.codex/sessions`. See
  `.claude/research/2026-06-23-ccrider-as-ingestion-source.md`.

  Options: `:db` (path to `sessions.db`, default `~/.config/ccrider/sessions.db`), `:provider`
  (default `"claude"`).
  """

  @behaviour Faber.Ingest.Source

  require Logger

  alias Faber.Ingest

  @default_db "~/.config/ccrider/sessions.db"

  @typedoc "An opaque ccrider session handle."
  @type handle :: %{
          id: integer(),
          session_id: String.t(),
          project_path: String.t(),
          db: String.t()
        }

  @impl true
  def discover(opts) do
    db = db_path(opts)
    provider = opts[:provider] || "claude"

    sql =
      "SELECT id, session_id, project_path FROM sessions WHERE provider = #{quote_str(provider)} ORDER BY id"

    case query(sql, db) do
      {:ok, rows} ->
        Enum.map(rows, fn r ->
          %{id: r["id"], session_id: r["session_id"], project_path: r["project_path"], db: db}
        end)

      {:error, reason} ->
        Logger.warning("faber ccrider: discover failed — #{inspect(reason)}")
        []
    end
  end

  @impl true
  def parse(%{id: id, session_id: sid, db: db}, _opts) do
    # Ordered by sequence (then id as a stable tiebreak) so the event stream matches file order.
    sql =
      "SELECT type, content, uuid, parent_uuid, timestamp, is_sidechain " <>
        "FROM messages WHERE session_id = #{int(id)} ORDER BY sequence, id"

    case query(sql, db) do
      {:ok, rows} ->
        rows
        |> Enum.reduce({[], []}, fn row, {events, errors} ->
          case envelope(row, sid) do
            {:ok, env} -> {[Ingest.normalize(env, format: :claude) | events], errors}
            {:error, err} -> {events, [err | errors]}
          end
        end)
        |> then(fn {events, errors} -> {Enum.reverse(events), Enum.reverse(errors)} end)

      {:error, reason} ->
        {[], [%{line: "ccrider session #{sid}", reason: reason}]}
    end
  end

  @impl true
  def label(%{project_path: pp, session_id: sid}) do
    Path.join(pp || "ccrider", "#{sid}.jsonl")
  end

  # Rebuild the Claude JSONL line envelope from ccrider's columns. `content` is the *inner* message
  # object; `type`/`is_sidechain`/`uuid`/`session_id` are separate columns. `isMeta` is not stored,
  # so the user-corrections "exclude meta turns" refinement degrades slightly under this source.
  defp envelope(row, sid) do
    case Jason.decode(row["content"] || "", keys: :strings) do
      {:ok, message} when is_map(message) ->
        {:ok,
         %{
           "type" => row["type"],
           "message" => message,
           "timestamp" => row["timestamp"],
           "uuid" => row["uuid"],
           "parentUuid" => row["parent_uuid"],
           "sessionId" => sid,
           "isSidechain" => row["is_sidechain"] == 1
         }}

      _ ->
        {:error, %{line: "ccrider message #{row["uuid"]}", reason: :unparseable_content}}
    end
  end

  # ── sqlite3 CLI (read-only, JSON output) — no hex/NIF dependency ────────────────

  # Missing binary / missing DB stay a `raise`: the source is explicit opt-in, so a setup gap
  # should fail loud with a fix hint, not silently scan nothing. *Query* failures (corrupt DB,
  # non-JSON output) degrade to `{:error, reason}` so one bad DB read can't crash a whole scan.
  defp query(sql, db) do
    bin =
      System.find_executable("sqlite3") ||
        raise "source: :ccrider needs the `sqlite3` CLI on PATH (it ships with ccrider's sqlite)"

    unless File.exists?(db) do
      raise "ccrider DB not found at #{db} (set `db:` or run ccrider first)"
    end

    case Faber.Subprocess.run(bin, ["-json", "-readonly", db, sql],
           stderr_to_stdout: true,
           timeout: :timer.seconds(30)
         ) do
      {:error, :timeout} ->
        {:error, :sqlite3_timeout}

      {out, 0} ->
        case String.trim(out) do
          "" ->
            {:ok, []}

          json ->
            case Jason.decode(json) do
              {:ok, rows} when is_list(rows) -> {:ok, rows}
              {:ok, other} -> {:error, {:unexpected_shape, other}}
              {:error, reason} -> {:error, {:bad_json, reason}}
            end
        end

      {out, code} ->
        {:error, {:sqlite3_exit, code, String.trim(out)}}
    end
  end

  defp db_path(opts), do: Path.expand(opts[:db] || @default_db)

  # Provider is a small known set; still single-quote-escape defensively (SQLi hygiene at a boundary
  # reading an LLM-adjacent DB). Ids are cast to integer so they can be inlined safely.
  defp quote_str(s), do: "'" <> String.replace(to_string(s), "'", "''") <> "'"
  defp int(n) when is_integer(n), do: n
end
