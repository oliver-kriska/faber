defmodule Faber.Ingest.Format.Gemini do
  @moduledoc """
  **Gemini CLI** (Google's `gemini-cli`) transcript format — Faber's fourth cross-agent ingest
  format. The identical on-disk shape is also used by **Qwen Code** (a Gemini CLI fork), so this one
  module covers both: point `base` at `~/.qwen/tmp` instead of `~/.gemini/tmp`.

  Gemini CLI stores one JSON file per session (rewritten in full each turn) at:

      ~/.gemini/tmp/<project-hash>/chats/session-*.json

  The file is a JSON **object** with a `messages` array (not line-delimited JSONL). Each message is a
  conversation turn carrying a `role` and either a string `content` or a Gemini-style `parts`/content
  array of `{text}`, `{functionCall: {name, args}}`, and `{functionResponse: {name, response}}`
  items. Roles map `user` → `:user` and Gemini's `model` (or `assistant`) → `:assistant`.

  Tool calls are canonicalized to Faber's vocabulary so `Faber.Detect`'s name-keyed signals fire
  cross-agent: `run_shell_command` → `Bash` (`args.command`), `read_file` → `Read`, `write_file` →
  `Write`, `replace` → `Edit` (`args.file_path`/`args.absolute_path`/`args.path` → `file_path`),
  `glob` → `Glob`, `search_file_content` → `Grep`. Unknown tools keep their name (still counted).
  A `functionResponse` whose `response` carries an `error` is flagged as a tool error.

  Because a JSON object/array can't be parsed incrementally without a streaming parser, the file is
  read and decoded in full; a malformed file surfaces as a single `{:error, _}` rather than crashing.
  The session id is taken from the top-level `sessionId` when present, else derived from the filename.
  Untrusted keys are decoded as **strings** (`keys: :strings`) — never atoms (Iron Law).

  > **Validation status:** Gemini CLI's session schema is not formally published; this is built
  > defensively against the documented `{messages: [{role, content|parts, …}]}` shape and Gemini
  > CLI's documented tool names. It tolerates string-or-array content and degrades unknown shapes to
  > inert `:other` events, but the exact `parts`/`functionResponse` layout and tool-name set should
  > be confirmed against a real `session-*.json`. See
  > `.claude/research/2026-06-26-cross-agent-ingest-survey.md`.
  """

  @behaviour Faber.Ingest.Format

  alias Faber.Ingest.Event

  @default_base "~/.gemini/tmp"

  @impl true
  def default_base, do: @default_base

  @doc """
  Discover Gemini CLI session files under `base` (default `#{@default_base}`).

  Globs `*/chats/session-*.json` (one project-hash dir per project). For Qwen Code, pass
  `base: "~/.qwen/tmp"`. `Path.wildcard/2` doesn't expand `~`, so `base` is `Path.expand/1`-ed first.
  """
  @impl true
  def discover(base \\ @default_base) do
    base
    |> Path.expand()
    |> Path.join("*/chats/session-*.json")
    |> Path.wildcard()
  end

  @doc """
  Stream a Gemini `session-*.json` as `{:ok, Event.t()} | {:error, map()}` per message.

  The file is one JSON document, so it's read and decoded in full, then one event is emitted per
  message in the `messages` array (a bare top-level array is tolerated), each stamped with the
  session id.
  """
  @impl true
  def stream_file!(path) do
    case File.read(path) do
      {:ok, body} -> decode_body(body, path)
      {:error, reason} -> [{:error, %{line: path, reason: reason}}]
    end
  end

  defp decode_body(body, path) do
    case Jason.decode(body, keys: :strings) do
      {:ok, %{"messages" => messages} = top} when is_list(messages) ->
        emit(messages, top["sessionId"] || top["session_id"] || session_id_from_path(path))

      {:ok, messages} when is_list(messages) ->
        emit(messages, session_id_from_path(path))

      {:ok, other} ->
        [{:error, %{line: path, reason: {:unexpected_shape, other}}}]

      {:error, reason} ->
        [{:error, %{line: path, reason: reason}}]
    end
  end

  defp emit(messages, sid), do: Enum.map(messages, &decode_message(&1, sid))

  defp decode_message(map, sid) when is_map(map), do: {:ok, %{normalize(map) | session_id: sid}}
  defp decode_message(other, _sid), do: {:error, %{line: other, reason: {:not_an_object, other}}}

  defp session_id_from_path(path), do: path |> Path.basename(".json")

  @doc """
  Normalize one decoded Gemini message (string keys) into an `Event`.

  Accepts string `content` or a Gemini `content`/`parts` array. `session_id` is left `nil` here —
  `stream_file!/1` stamps it.
  """
  @impl true
  def normalize(%{"role" => role} = map) do
    content = map["content"] || map["parts"]

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
  defp parse_type("model"), do: :assistant
  defp parse_type("assistant"), do: :assistant
  defp parse_type("system"), do: :system
  defp parse_type(_), do: :other

  # ── text / tool extraction (Gemini parts) ────────────────────────────────────────────────────

  defp extract_text(content) when is_binary(content), do: nilify_blank(content)

  defp extract_text(content) when is_list(content) do
    content
    |> Enum.filter(&(is_map(&1) and is_binary(&1["text"])))
    |> Enum.map_join("\n", & &1["text"])
    |> nilify_blank()
  end

  defp extract_text(_), do: nil

  defp extract_tool_uses(content) when is_list(content) do
    content
    |> Enum.filter(&(is_map(&1) and is_map(&1["functionCall"])))
    |> Enum.map(fn part ->
      fc = part["functionCall"]
      map_tool(fc["name"], fc["args"] || %{}, fc["id"])
    end)
  end

  defp extract_tool_uses(_), do: []

  defp extract_tool_results(content) when is_list(content) do
    content
    |> Enum.filter(&(is_map(&1) and is_map(&1["functionResponse"])))
    |> Enum.map(fn part ->
      fr = part["functionResponse"]
      %{tool_use_id: fr["id"], is_error: response_error?(fr["response"])}
    end)
  end

  defp extract_tool_results(_), do: []

  # ── canonical tool mapping ───────────────────────────────────────────────────────────────────

  defp map_tool("run_shell_command", args, id),
    do: %{name: "Bash", input: %{"command" => args["command"]}, id: id}

  defp map_tool("read_file", args, id),
    do: %{name: "Read", input: %{"file_path" => file_arg(args)}, id: id}

  defp map_tool("write_file", args, id),
    do: %{name: "Write", input: %{"file_path" => file_arg(args)}, id: id}

  defp map_tool("replace", args, id),
    do: %{name: "Edit", input: %{"file_path" => file_arg(args)}, id: id}

  defp map_tool("glob", args, id), do: %{name: "Glob", input: args, id: id}
  defp map_tool("search_file_content", args, id), do: %{name: "Grep", input: args, id: id}

  defp map_tool(name, args, id), do: %{name: name || "UnknownTool", input: args, id: id}

  # Gemini's file tools use varied path keys across tools/versions.
  defp file_arg(args), do: args["file_path"] || args["absolute_path"] || args["path"]

  # A functionResponse carries the tool's return; treat an explicit `error` (or an `error`-keyed
  # output) as a failure. Unknown shapes are not errors (conservative — avoids false friction).
  defp response_error?(%{"error" => err}) when not is_nil(err), do: true
  defp response_error?(%{"output" => %{"error" => err}}) when not is_nil(err), do: true
  defp response_error?(_), do: false

  defp nilify_blank(text) do
    case String.trim(text) do
      "" -> nil
      _ -> text
    end
  end
end
