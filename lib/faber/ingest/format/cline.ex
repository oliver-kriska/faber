defmodule Faber.Ingest.Format.Cline do
  @moduledoc """
  **Cline** (the `saoudrizwan.claude-dev` VS Code extension) transcript format — Faber's third
  cross-agent ingest format.

  Cline stores one directory per task under VS Code's `globalStorage`:

      <globalStorage>/saoudrizwan.claude-dev/tasks/<task-id>/api_conversation_history.json

  Unlike Claude/Codex (line-delimited JSONL), `api_conversation_history.json` is a **single JSON
  array** holding the conversation in the **Anthropic Messages API format** verbatim — `[{"role":
  "user"|"assistant", "content": string | [content-block, …]}]` where blocks are `text`,
  `tool_use`, and `tool_result`. Because that's the same content-block shape Claude Code uses, text
  and tool-result extraction mirror `Faber.Ingest.Format.Claude` exactly.

  Two things differ from Claude:

    * **Tool names are Cline's own**, not Claude Code's. They are canonicalized to Faber's vocabulary
      so `Faber.Detect`'s name-keyed signals fire cross-agent: `execute_command` → `Bash`
      (`input.command`), `read_file` → `Read`, `write_to_file` → `Write`, `replace_in_file` → `Edit`
      (all with `input.path` → `file_path`), `search_files` → `Grep`. Unknown tools keep their name
      (still counted toward `tool_count`).
    * **The array carries no per-message `session_id`/`timestamp`/`uuid`** (those live in the
      sibling `ui_messages.json`). The session id is the **task-id directory name**, so
      `stream_file!/1` derives it from the path and stamps it onto every event.

  Because a JSON array can't be parsed incrementally without a streaming parser, the file is read in
  full and decoded once (not line-streamed like JSONL); a malformed file surfaces as a single
  `{:error, _}` rather than crashing the run.

  Untrusted transcript keys are decoded as **strings** (`keys: :strings`) — never atoms — to avoid
  atom-exhaustion (Iron Law: no `String.to_atom` on user-controlled input).

  > **Validation status:** built against the documented Anthropic-Messages shape and Cline's
  > documented tool vocabulary; the exact tool-name set should be confirmed against a real
  > `api_conversation_history.json`. Unknown tools degrade gracefully (name preserved), so an
  > unseen tool never crashes the scan. See `.claude/research/2026-06-26-cross-agent-ingest-survey.md`.
  """

  @behaviour Faber.Ingest.Format

  alias Faber.Ingest.Event

  # VS Code's globalStorage parent on macOS. The `*` in `discover/1` spans IDE variants
  # (Code, "Code - Insiders", VSCodium). On Linux this is `~/.config`; override with `base`.
  @default_base "~/Library/Application Support"

  @impl true
  def default_base, do: @default_base

  @doc """
  Discover Cline task transcripts under `base` (default `#{@default_base}`).

  Globs `*/User/globalStorage/saoudrizwan.claude-dev/tasks/*/api_conversation_history.json`, so a
  single base covers every VS Code variant. `Path.wildcard/2` doesn't expand `~`, so `base` is
  `Path.expand/1`-ed first.
  """
  @impl true
  def discover(base \\ @default_base) do
    base
    |> Path.expand()
    |> Path.join(
      "*/User/globalStorage/saoudrizwan.claude-dev/tasks/*/api_conversation_history.json"
    )
    |> Path.wildcard()
  end

  @doc """
  Stream a Cline `api_conversation_history.json` as `{:ok, Event.t()} | {:error, map()}` per message.

  The file is one JSON array, so it's read and decoded in full (not line-streamed), then one event
  is emitted per message with the session id derived from the task directory.
  """
  @impl true
  def stream_file!(path) do
    sid = session_id_from_path(path)

    case File.read(path) do
      {:ok, body} -> decode_body(body, sid, path)
      {:error, reason} -> [{:error, %{line: path, reason: reason}}]
    end
  end

  defp decode_body(body, sid, path) do
    case Jason.decode(body, keys: :strings) do
      {:ok, messages} when is_list(messages) ->
        Enum.map(messages, &decode_message(&1, sid))

      {:ok, other} ->
        [{:error, %{line: path, reason: {:not_an_array, other}}}]

      {:error, reason} ->
        [{:error, %{line: path, reason: reason}}]
    end
  end

  defp decode_message(map, sid) when is_map(map), do: {:ok, %{normalize(map) | session_id: sid}}
  defp decode_message(other, _sid), do: {:error, %{line: other, reason: {:not_an_object, other}}}

  # The task-id directory (…/tasks/<task-id>/api_conversation_history.json) is Cline's stable
  # per-session identifier; the array itself carries none.
  defp session_id_from_path(path) do
    path |> Path.dirname() |> Path.basename()
  end

  @doc """
  Normalize one decoded Cline message (Anthropic Messages shape, string keys) into an `Event`.

  `session_id` is left `nil` here — `stream_file!/1` stamps it from the task directory.
  """
  @impl true
  def normalize(%{"role" => role} = map) do
    content = map["content"]

    %Event{
      type: parse_type(role),
      role: role,
      text: extract_text(content),
      tool_uses: extract_tool_uses(content),
      tool_results: extract_tool_results(content),
      raw: map
    }
  end

  def normalize(map) when is_map(map), do: %Event{raw: map}

  defp parse_type("user"), do: :user
  defp parse_type("assistant"), do: :assistant
  defp parse_type(_), do: :other

  # ── text / tool-result extraction (Anthropic content blocks — same shape as Claude) ──────────

  defp extract_text(content) when is_binary(content), do: nilify_blank(content)

  defp extract_text(content) when is_list(content) do
    content
    |> Enum.filter(&(is_map(&1) and &1["type"] == "text" and is_binary(&1["text"])))
    |> Enum.map_join("\n", & &1["text"])
    |> nilify_blank()
  end

  defp extract_text(_), do: nil

  defp extract_tool_results(content) when is_list(content) do
    content
    |> Enum.filter(&(is_map(&1) and &1["type"] == "tool_result"))
    |> Enum.map(fn it -> %{tool_use_id: it["tool_use_id"], is_error: it["is_error"] == true} end)
  end

  defp extract_tool_results(_), do: []

  # ── tool calls (canonicalized to Faber's vocabulary so Detect's name-keyed signals fire) ─────

  defp extract_tool_uses(content) when is_list(content) do
    content
    |> Enum.filter(&(is_map(&1) and &1["type"] == "tool_use"))
    |> Enum.map(fn it -> map_tool(it["name"], it["input"] || %{}, it["id"]) end)
  end

  defp extract_tool_uses(_), do: []

  # Cline's shell — map to Bash so retry-loop / bash-command signals fire.
  defp map_tool("execute_command", input, id),
    do: %{name: "Bash", input: %{"command" => input["command"]}, id: id}

  defp map_tool("read_file", input, id),
    do: %{name: "Read", input: %{"file_path" => input["path"]}, id: id}

  # Both whole-file writes and in-place edits touch a file path → canonical Write / Edit so
  # `files_edited` (fingerprint bonuses) and `edit_count` are accurate.
  defp map_tool("write_to_file", input, id),
    do: %{name: "Write", input: %{"file_path" => input["path"]}, id: id}

  defp map_tool("replace_in_file", input, id),
    do: %{name: "Edit", input: %{"file_path" => input["path"]}, id: id}

  defp map_tool("search_files", input, id), do: %{name: "Grep", input: input, id: id}

  # Unknown / non-friction tools (list_files, ask_followup_question, attempt_completion,
  # use_mcp_tool, browser_action, …) keep their name so they still count toward tool_count.
  defp map_tool(name, input, id) when is_binary(name), do: %{name: name, input: input, id: id}
  defp map_tool(_name, input, id), do: %{name: "UnknownTool", input: input, id: id}

  # ── shared helpers ───────────────────────────────────────────────────────────────────────────

  defp nilify_blank(text) do
    case String.trim(text) do
      "" -> nil
      _ -> text
    end
  end
end
