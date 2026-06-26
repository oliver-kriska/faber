defmodule Faber.Ingest.Format.OpenCode do
  @moduledoc """
  **OpenCode** (the `opencode` CLI) transcript format — Faber's fifth cross-agent ingest format, and
  the first backed by a **SQLite database** rather than flat JSON/JSONL files.

  OpenCode stores everything in one SQLite DB:

      ~/.local/share/opencode/opencode.db

  with three relevant tables: `session`, `message` (one row per turn; `data` is a JSON blob holding
  `role`/`time`/`model`), and `part` (one row per content piece; `data` is a JSON blob whose `type`
  is `text`, `tool`, `patch`, `reasoning`, `step-start`, or `step-finish`). A logical message is a
  `message` row plus its ordered `part` rows.

  Unlike Claude/Cline/Gemini, OpenCode folds a tool **call and its result into a single `tool`
  part** — `{"type":"tool","tool":"bash","callID":…,"state":{"status":"completed"|"error","input":
  {…},"output"|"error":…}}` — so one part yields **both** a `tool_use` and a `tool_result`
  (`is_error` from `state.status == "error"`). Applied edits appear as `patch` parts carrying a
  `files` list; each becomes a canonical `Edit` tool_use so `Faber.Detect`'s file signals fire.

  Tool names are canonicalized to Faber's vocabulary: `bash` → `Bash` (`input.command`), `read` →
  `Read`, `edit` → `Edit`, `write` → `Write` (all with `input.filePath` → `file_path`), `grep` →
  `Grep`, `glob` → `Glob`. Unknown tools keep their name (still counted).

  ## Reading SQLite without a NIF

  Faithful to this project's "subprocess boundary, no NIF" design (the Python eval sidecar is reached
  the same way — see `mix.exs`), the DB is read via the **`sqlite3` CLI** (`-json` mode) rather than
  by adding an `exqlite`/`ecto_sqlite3` NIF dependency. If `sqlite3` isn't on `PATH`, ingest degrades
  gracefully to a single `{:error, %{reason: :sqlite3_unavailable}}` rather than crashing — exactly
  like the sidecar's graceful-unavailable path. Because that makes `discover/1`/`stream_file!/1`
  depend on an external CLI, the DB-reading tests are tagged `:opencode` (excluded from the hermetic
  `mix test`, included by `mix test.full`); `normalize/1` — the pure record→Event core — is tested
  inline with no DB.

  Untrusted JSON keys are decoded as **strings** (`keys: :strings`) — never atoms (Iron Law).

  > **Validation status:** built and verified against a **real `opencode.db`** (schema + part shapes
  > confirmed on disk), unlike the documentation-derived Cline/Gemini formats. Token usage
  > (`step-finish.tokens`) is present but not mapped to `Event.usage` for v1 — OpenCode records no
  > inline context window, so a pressure signal can't be derived without model→window knowledge.
  > See `.claude/research/2026-06-26-cross-agent-ingest-survey.md`.
  """

  @behaviour Faber.Ingest.Format

  alias Faber.Ingest.Event

  @default_base "~/.local/share/opencode"
  @db_name "opencode.db"

  # One row per (message, part), ordered so a message's parts are contiguous. The `part` column is a
  # JSON-text blob (decoded in Elixir); a LEFT JOIN keeps part-less messages.
  @query "SELECT m.id AS id, m.session_id AS session_id, " <>
           "json_extract(m.data,'$.role') AS role, p.data AS part " <>
           "FROM message m LEFT JOIN part p ON p.message_id = m.id " <>
           "ORDER BY m.time_created, m.id, p.time_created"

  @impl true
  def default_base, do: @default_base

  @doc """
  Discover the OpenCode DB under `base` (default `#{@default_base}`).

  Returns `[<base>/#{@db_name}]` when it exists (OpenCode keeps a single global DB), else `[]`. If
  `base` itself points at a `.db` file, it's returned as-is. `~` is expanded.
  """
  @impl true
  def discover(base \\ @default_base) do
    expanded = Path.expand(base)

    db =
      if String.ends_with?(expanded, ".db"), do: expanded, else: Path.join(expanded, @db_name)

    if File.exists?(db), do: [db], else: []
  end

  @doc """
  Stream an OpenCode `opencode.db` as `{:ok, Event.t()} | {:error, map()}` per logical message.

  Reads the message⋈part join via the `sqlite3` CLI (`-json`), groups rows into logical messages,
  and emits one event each, stamped with the session id. A missing `sqlite3`, a query failure, or a
  decode error surfaces as a single `{:error, _}` rather than crashing the run.
  """
  @impl true
  def stream_file!(path) do
    case System.find_executable("sqlite3") do
      nil -> [{:error, %{line: path, reason: :sqlite3_unavailable}}]
      sqlite3 -> run_query(sqlite3, path)
    end
  end

  defp run_query(sqlite3, path) do
    case System.cmd(sqlite3, ["-json", "-readonly", path, @query], stderr_to_stdout: true) do
      {"", 0} -> []
      {output, 0} -> decode_rows(output, path)
      {output, status} -> [{:error, %{line: path, reason: {:sqlite3_exit, status, output}}}]
    end
  rescue
    e -> [{:error, %{line: path, reason: Exception.message(e)}}]
  end

  defp decode_rows(output, path) do
    case Jason.decode(output, keys: :strings) do
      {:ok, rows} when is_list(rows) ->
        rows
        |> Enum.chunk_by(& &1["id"])
        |> Enum.map(&decode_message/1)

      {:ok, other} ->
        [{:error, %{line: path, reason: {:unexpected_shape, other}}}]

      {:error, reason} ->
        [{:error, %{line: path, reason: reason}}]
    end
  end

  defp decode_message([first | _] = rows) do
    sid = first["session_id"]
    parts = rows |> Enum.map(& &1["part"]) |> Enum.reject(&is_nil/1) |> Enum.map(&decode_part/1)
    logical = %{"role" => first["role"], "parts" => parts}
    {:ok, %{normalize(logical) | session_id: sid}}
  rescue
    # `rows` is the function parameter (non-empty per the head pattern) — identify the failing
    # message by its id, not by embedding the whole row group in the error payload.
    e -> {:error, %{line: hd(rows)["id"], reason: Exception.message(e)}}
  end

  # A malformed part is skipped (decodes to `%{}`, which has no `"type"` so every extractor ignores
  # it) rather than failing the whole message — one corrupt part shouldn't drop a turn's signal.
  defp decode_part(json) when is_binary(json) do
    case Jason.decode(json, keys: :strings) do
      {:ok, decoded} -> decoded
      {:error, _} -> %{}
    end
  end

  defp decode_part(_), do: %{}

  @doc """
  Normalize one logical OpenCode message (`%{"role" => role, "parts" => [part, …]}`, string keys)
  into an `Event`. Pure — no DB access. `session_id` is left `nil`; `stream_file!/1` stamps it.
  """
  @impl true
  def normalize(%{"role" => role, "parts" => parts}) when is_list(parts) do
    %Event{
      type: parse_type(role),
      role: role,
      text: extract_text(parts),
      tool_uses: extract_tool_uses(parts),
      tool_results: extract_tool_results(parts),
      raw: %{"role" => role, "parts" => parts}
    }
  end

  def normalize(map) when is_map(map), do: %Event{raw: map}

  defp parse_type("user"), do: :user
  defp parse_type("assistant"), do: :assistant
  defp parse_type(_), do: :other

  # ── text / tool extraction (OpenCode parts) ──────────────────────────────────────────────────

  defp extract_text(parts) do
    parts
    |> Enum.filter(&(is_map(&1) and &1["type"] == "text" and is_binary(&1["text"])))
    |> Enum.map_join("\n", & &1["text"])
    |> nilify_blank()
  end

  # A `tool` part is call+result combined → contribute a tool_use; a `patch` part's files each
  # become a canonical Edit so referenced-path / edit-count signals fire.
  defp extract_tool_uses(parts) do
    Enum.flat_map(parts, fn
      %{"type" => "tool"} = p ->
        [map_tool(p["tool"], get_in(p, ["state", "input"]) || %{}, p["callID"])]

      %{"type" => "patch", "files" => files} when is_list(files) ->
        Enum.map(files, &%{name: "Edit", input: %{"file_path" => &1}, id: nil})

      _ ->
        []
    end)
  end

  # The result half of each `tool` part: an `error` status is a failed tool call.
  defp extract_tool_results(parts) do
    parts
    |> Enum.filter(&(is_map(&1) and &1["type"] == "tool"))
    |> Enum.map(fn p ->
      %{tool_use_id: p["callID"], is_error: get_in(p, ["state", "status"]) == "error"}
    end)
  end

  # ── canonical tool mapping ───────────────────────────────────────────────────────────────────

  defp map_tool("bash", input, id),
    do: %{name: "Bash", input: %{"command" => input["command"]}, id: id}

  defp map_tool("read", input, id),
    do: %{name: "Read", input: %{"file_path" => file_arg(input)}, id: id}

  defp map_tool("write", input, id),
    do: %{name: "Write", input: %{"file_path" => file_arg(input)}, id: id}

  defp map_tool("edit", input, id),
    do: %{name: "Edit", input: %{"file_path" => file_arg(input)}, id: id}

  defp map_tool("grep", input, id), do: %{name: "Grep", input: input, id: id}
  defp map_tool("glob", input, id), do: %{name: "Glob", input: input, id: id}

  defp map_tool(name, input, id) when is_binary(name), do: %{name: name, input: input, id: id}
  defp map_tool(_name, input, id), do: %{name: "UnknownTool", input: input, id: id}

  # OpenCode's file tools use `filePath`; accept a couple of fallbacks defensively.
  defp file_arg(input), do: input["filePath"] || input["file_path"] || input["path"]

  defp nilify_blank(text) do
    case String.trim(text) do
      "" -> nil
      _ -> text
    end
  end
end
