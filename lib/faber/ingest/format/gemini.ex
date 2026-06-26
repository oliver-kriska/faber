defmodule Faber.Ingest.Format.Gemini do
  @moduledoc """
  **Gemini CLI** (Google's `gemini-cli`) transcript format — Faber's fourth cross-agent ingest
  format. The identical on-disk shape is also used by **Qwen Code** (a Gemini CLI fork), so this one
  module covers both: point `base` at `~/.qwen/tmp` instead of `~/.gemini/tmp`.

  Gemini CLI stores its session recording (rewritten as the turn progresses) under:

      ~/.gemini/tmp/<project-hash>/chats/

  The common shape is a JSON **object** with a `messages` array; each message is a conversation turn
  carrying a `role` and either a string `content` or a Gemini-style `parts`/content array of
  `{text}`, `{functionCall: {name, args}}`, and `{functionResponse: {name, response}}` items. Roles
  map `user` → `:user` and Gemini's `model` (or `assistant`) → `:assistant`. A line-delimited
  variant also exists — both are handled (see "Two documented shapes" below).

  Tool calls are canonicalized to Faber's vocabulary so `Faber.Detect`'s name-keyed signals fire
  cross-agent: `run_shell_command` → `Bash` (`args.command`), `read_file` → `Read`, `write_file` →
  `Write`, `replace` → `Edit` (`args.file_path`/`args.absolute_path`/`args.path` → `file_path`),
  `glob` → `Glob`, `search_file_content` → `Grep`. Unknown tools keep their name (still counted).
  A `functionResponse` whose `response` carries an `error` is flagged as a tool error.

  Because a JSON object/array can't be parsed incrementally without a streaming parser, the file is
  read and decoded in full; a malformed file surfaces as a single `{:error, _}` rather than crashing.
  The session id is taken from the top-level `sessionId` when present, else derived from the filename.
  Untrusted keys are decoded as **strings** (`keys: :strings`) — never atoms (Iron Law).

  ## Two documented shapes (both handled)

  Gemini CLI's session schema is not formally published, and two same-day reverse-engineerings
  disagree — so this module handles the **union** of both rather than betting on one:

    1. **Survey shape** (`session-*.json`, single JSON object): `{messages: [{role, content, …}]}`
       where `role` is `"user"`/`"model"` and tools live in `content`/`parts` as `functionCall`/
       `functionResponse` items.
    2. **Source-derived shape** (`*.jsonl`, line-delimited `ConversationRecord`s, from
       `chatRecordingTypes.ts`): each `MessageRecord` uses a `type` discriminator
       (`user`/`gemini`/`info`/`error`/`warning`) as the role and carries a message-level
       `toolCalls: [{id, name, args, result, status}]` array.

  `normalize/1` reads the role from `role` **or** `type`, and tool calls from a `toolCalls` array
  **or** `content` parts; `discover/1` globs both `session-*.json` and `*.jsonl`; `stream_file!/1`
  falls back to line-delimited decoding (last `ConversationRecord` wins) when whole-file JSON decode
  fails. Unknown shapes still degrade to inert `:other` events. Confirm against a real Gemini install
  when one is available. See `.claude/research/2026-06-26-cross-agent-ingest-survey.md` and the
  `coding-agent-transcript-storage-formats` scriptorium note.
  """

  @behaviour Faber.Ingest.Format

  alias Faber.Ingest.Event

  @default_base "~/.gemini/tmp"

  @impl true
  def default_base, do: @default_base

  @doc """
  Discover Gemini CLI session files under `base` (default `#{@default_base}`).

  Globs `*/chats/session-*.json` **and** `*/chats/*.jsonl` (one project-hash dir per project) —
  the two shapes documented for Gemini CLI's session recording differ on extension (see the
  moduledoc's validation note). For Qwen Code, pass `base: "~/.qwen/tmp"`. `Path.wildcard/2` doesn't
  expand `~`, so `base` is `Path.expand/1`-ed first.
  """
  @impl true
  def discover(base \\ @default_base) do
    expanded = Path.expand(base)

    Path.wildcard(Path.join(expanded, "*/chats/session-*.json")) ++
      Path.wildcard(Path.join(expanded, "*/chats/*.jsonl"))
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

      {:error, _reason} ->
        # Whole-file decode failed — likely the line-delimited (`.jsonl`) ConversationRecord variant.
        decode_jsonl(body, path)
    end
  end

  # The source-derived shape is line-delimited: each line is either a full `ConversationRecord`
  # snapshot (full rewrite per turn → the *last* one wins) or a bare `MessageRecord`. Decode each
  # line; if any records carry a `messages` array, take the last such record's messages, else treat
  # the decoded line-objects themselves as the message list.
  defp decode_jsonl(body, path) do
    decoded =
      body
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode(&1, keys: :strings))
      |> Enum.flat_map(fn
        {:ok, map} when is_map(map) -> [map]
        _ -> []
      end)

    records = Enum.filter(decoded, &is_list(&1["messages"]))

    case records do
      [] when decoded == [] ->
        [{:error, %{line: path, reason: :undecodable}}]

      [] ->
        emit(decoded, session_id_from_path(path))

      _ ->
        last = List.last(records)

        emit(
          last["messages"],
          last["sessionId"] || last["session_id"] || session_id_from_path(path)
        )
    end
  end

  defp emit(messages, sid), do: Enum.map(messages, &decode_message(&1, sid))

  defp decode_message(map, sid) when is_map(map), do: {:ok, %{normalize(map) | session_id: sid}}
  defp decode_message(other, _sid), do: {:error, %{line: other, reason: {:not_an_object, other}}}

  defp session_id_from_path(path), do: path |> Path.basename(".json")

  @doc """
  Normalize one decoded Gemini message (string keys) into an `Event`.

  Handles both documented shapes (see the moduledoc validation note): the role comes from `role`
  ("user"/"model") **or** `type` ("user"/"gemini"/…); tool calls come from a `content`/`parts`
  array's `functionCall`/`functionResponse` items **or** from a message-level `toolCalls` array
  (`[{id, name, args, result, status}]`). `session_id` is left `nil` here — `stream_file!/1` stamps it.
  """
  @impl true
  def normalize(map) when is_map(map) do
    role = map["role"] || map["type"]

    if is_nil(role) do
      %Event{raw: map}
    else
      content = map["content"] || map["parts"]
      tool_calls = map["toolCalls"]

      %Event{
        type: parse_type(role),
        role: role,
        text: extract_text(content),
        tool_uses: tool_uses(content, tool_calls),
        tool_results: tool_results(content, tool_calls),
        raw: map
      }
    end
  end

  defp parse_type("user"), do: :user
  defp parse_type("model"), do: :assistant
  defp parse_type("assistant"), do: :assistant
  defp parse_type("gemini"), do: :assistant
  defp parse_type("system"), do: :system
  defp parse_type(_), do: :other

  # Prefer the explicit `toolCalls` summary array when present; else read `functionCall` parts.
  defp tool_uses(_content, tool_calls) when is_list(tool_calls) and tool_calls != [],
    do: extract_tool_calls(tool_calls)

  defp tool_uses(content, _tool_calls), do: extract_tool_uses(content)

  defp tool_results(_content, tool_calls) when is_list(tool_calls) and tool_calls != [],
    do: extract_tool_call_results(tool_calls)

  defp tool_results(content, _tool_calls), do: extract_tool_results(content)

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

  # ── message-level `toolCalls` array (source-derived shape) ───────────────────────────────────
  # `[{id, name, args, result, status}]` — each entry is a call *and* its outcome.

  defp extract_tool_calls(tool_calls) do
    tool_calls
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn tc -> map_tool(tc["name"], tc["args"] || %{}, tc["id"]) end)
  end

  defp extract_tool_call_results(tool_calls) do
    tool_calls
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn tc -> %{tool_use_id: tc["id"], is_error: tool_call_error?(tc)} end)
  end

  defp tool_call_error?(tc) do
    tc["status"] in ["error", "failed", "cancelled"] or
      (is_map(tc["result"]) and not is_nil(tc["result"]["error"]))
  end

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
