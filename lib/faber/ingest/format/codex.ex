defmodule Faber.Ingest.Format.Codex do
  @moduledoc """
  OpenAI **Codex** CLI transcript format — Faber's second cross-agent ingest format.

  Codex stores sessions under `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`: line-delimited JSON,
  one *event* per line. Unlike Claude (one self-contained message per line, tool calls/results
  embedded as content blocks), Codex spreads a turn across several event lines and **two parallel
  streams**:

    * `response_item/*` — the API-level conversation items (`message`, `function_call`,
      `function_call_output`, `custom_tool_call`, `reasoning`).
    * `event_msg/*` — UI/telemetry events (`user_message`, `agent_message`, `token_count`,
      `task_started`/`task_complete`, …).

  To avoid double-counting, this format takes a **single canonical view**:

    * **user turns** ← `event_msg/user_message` (the human's typed prompt; the `response_item`
      `message[role=user]` lines are Codex's injected `AGENTS.md`/skills preamble, not real input).
    * **assistant text** ← `event_msg/agent_message`.
    * **tool calls** ← `response_item/function_call` and `custom_tool_call`, normalized to Faber's
      canonical tool vocabulary so `Faber.Detect`'s name-keyed signals fire cross-agent:
      `exec_command` → `Bash` (`input.command`), `view_image` → `Read` (`input.file_path`),
      `apply_patch` → one `Edit` per file in the patch, `write_stdin` → `WriteStdin` (counted but
      Bash-signal-neutral).
    * **tool results / errors** ← `function_call_output` / `custom_tool_call_output`, with
      `is_error` inferred from `Process exited with code N`, a `… failed:` / `SandboxDenied`
      prefix, or a custom-tool `metadata.exit_code`.
    * **context pressure** ← `event_msg/token_count`, normalized into `Event.usage`
      (`last_token_usage.input_tokens` / `model_context_window`) — Codex carries the window
      *inline*, so unlike Claude there's no model→window lookup. See `Faber.Ingest.Event`.

  `reasoning`, `turn_context`, `session_meta`, and other telemetry map to inert `:other` events
  (kept in `:raw`, never counted as messages). `session_meta` additionally seeds the session id,
  which Codex stores **only** on that first line — `stream_file!/1` carries it forward onto every
  subsequent event (Claude has `sessionId` on every line; Codex does not).

  Untrusted transcript keys are decoded as **strings** (`keys: :strings`) — never atoms — to avoid
  atom-exhaustion, same as the Claude format.

  ## Known mapping asymmetries (vs. Claude)

  Codex emits one line per conversation item, where Claude batches text + multiple `tool_use`
  blocks into one message. So a Codex session's `message_count` (and tool-call count for a
  multi-file `apply_patch`, mapped to one `Edit` per file) runs higher than the Claude equivalent
  for the same work. Friction signals are consistent *within* the Codex corpus; cross-agent
  absolute counts are not directly comparable. Interrupts/compactions have no Codex marker in the
  current schema, so those signals stay at zero. See
  `.claude/research/2026-06-23-codex-ingest-format.md`.
  """

  @behaviour Faber.Ingest.Format

  alias Faber.Ingest.Event

  @default_base "~/.codex/sessions"

  @impl true
  def default_base, do: @default_base

  @doc "Discover Codex session files under `base` (default `#{@default_base}`)."
  @impl true
  def discover(base \\ @default_base) do
    base
    |> Path.expand()
    |> Path.join("**/*.jsonl")
    |> Path.wildcard()
  end

  @doc """
  Stream a Codex `rollout-*.jsonl` as `{:ok, Event.t()} | {:error, map()}` per line.

  Lazy and single-pass; the session id seen on the `session_meta` line is threaded forward onto
  later events (Codex stores it only once).
  """
  @impl true
  def stream_file!(path) do
    path
    |> File.stream!()
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == ""))
    |> Stream.map(&decode_line/1)
    |> thread_session_id()
  end

  defp decode_line(line) do
    case Jason.decode(line, keys: :strings) do
      {:ok, map} when is_map(map) -> {:ok, normalize(map)}
      {:ok, other} -> {:error, %{line: line, reason: {:not_an_object, other}}}
      {:error, reason} -> {:error, %{line: line, reason: reason}}
    end
  end

  # Codex puts the session id only on `session_meta` (the first line). Carry it forward so every
  # event reports the same `session_id` (Claude has it on every line; Codex does not). The
  # session_meta event itself sets the accumulator via its own `session_id`.
  defp thread_session_id(stream) do
    Stream.transform(stream, nil, fn
      {:ok, %Event{session_id: sid} = e}, _acc when is_binary(sid) -> {[{:ok, e}], sid}
      {:ok, %Event{} = e}, acc -> {[{:ok, %{e | session_id: acc}}], acc}
      {:error, _} = err, acc -> {[err], acc}
    end)
  end

  @doc """
  Normalize a decoded Codex transcript line (string keys) into an `Event`.

  Dispatches on the outer `type` + `payload.type`; unrecognized shapes become inert `:other`
  events so an evolving Codex schema degrades gracefully rather than crashing the scan.
  """
  @impl true
  def normalize(%{"payload" => payload} = map) when is_map(payload) do
    base = %Event{timestamp: parse_timestamp(map["timestamp"]), raw: map}
    normalize_payload(map["type"], payload["type"], payload, base)
  end

  def normalize(map) when is_map(map), do: %Event{raw: map}

  # session_meta seeds the session id and the project cwd (and is otherwise inert). Codex carries
  # `cwd` only on this first line — Scan threads the first non-nil cwd onto the whole session, so
  # the project shows as the real working dir, not the rollout file's date directory.
  defp normalize_payload("session_meta", _pt, payload, base) do
    %{
      base
      | type: :other,
        is_meta: true,
        session_id: payload["session_id"] || payload["id"],
        cwd: payload["cwd"]
    }
  end

  # The human's typed prompt — the canonical user turn.
  defp normalize_payload("event_msg", "user_message", payload, base) do
    %{base | type: :user, text: nilify_blank(to_string(payload["message"] || ""))}
  end

  # Assistant commentary — the canonical assistant text turn.
  defp normalize_payload("event_msg", "agent_message", payload, base) do
    %{base | type: :assistant, text: nilify_blank(to_string(payload["message"] || ""))}
  end

  # Per-turn token usage with the context window inline (Codex's context-pressure source).
  defp normalize_payload("event_msg", "token_count", payload, base) do
    %{base | type: :other, is_meta: true, usage: usage_from_token_count(payload["info"])}
  end

  # An assistant tool call (exec/read/stdin/…), normalized to canonical names + input keys.
  defp normalize_payload("response_item", "function_call", payload, base) do
    %{base | type: :assistant, tool_uses: [function_tool_use(payload)]}
  end

  # A custom tool call (e.g. `apply_patch`) — may expand to several canonical tool uses.
  defp normalize_payload("response_item", "custom_tool_call", payload, base) do
    %{base | type: :assistant, tool_uses: custom_tool_uses(payload)}
  end

  # A tool result returned to the model (Claude surfaces these on a user turn too).
  defp normalize_payload("response_item", "function_call_output", payload, base) do
    %{base | type: :user, tool_results: [tool_result(payload, &output_error?/1)]}
  end

  defp normalize_payload("response_item", "custom_tool_call_output", payload, base) do
    %{base | type: :user, tool_results: [tool_result(payload, &custom_output_error?/1)]}
  end

  # reasoning, response_item/message (preamble + duplicates), turn_context, task_*, patch_apply_end,
  # web_search_*, image_generation_* — kept in :raw, counted as nothing.
  defp normalize_payload(_type, _pt, _payload, base), do: %{base | type: :other}

  # ── tool calls ──────────────────────────────────────────────────────────────

  defp function_tool_use(payload) do
    map_tool(
      payload["name"],
      decode_args(payload["arguments"]),
      payload["call_id"] || payload["id"]
    )
  end

  # `exec_command` is Codex's shell — map to Bash so retry-loop / bash-command signals fire.
  defp map_tool("exec_command", args, id) do
    %{name: "Bash", input: %{"command" => args["cmd"], "workdir" => args["workdir"]}, id: id}
  end

  # `view_image` reads a file off disk — closest canonical is Read (feeds the exploration profile).
  defp map_tool("view_image", args, id) do
    %{name: "Read", input: %{"file_path" => args["path"]}, id: id}
  end

  # stdin to a running exec session — counted toward tool_count but deliberately NOT Bash (it isn't
  # a fresh command, so it must not register as a retry loop).
  defp map_tool("write_stdin", args, id), do: %{name: "WriteStdin", input: args, id: id}

  # Unknown future tool — preserve the name so it still counts (error_tool_ratio), no canonical signal.
  defp map_tool(name, args, id), do: %{name: name || "UnknownTool", input: args, id: id}

  # `apply_patch` edits one or more files in a single call. Emit one canonical `Edit` per file so
  # `files_edited` (fingerprint bonuses) is accurate; fall back to a single file_path-less Edit.
  defp custom_tool_uses(%{"name" => "apply_patch", "input" => input} = p) do
    id = p["call_id"] || p["id"]

    case parse_patch_files(input) do
      [] ->
        [%{name: "Edit", input: %{"file_path" => nil, "patch" => input}, id: id}]

      files ->
        Enum.with_index(files, fn f, i ->
          %{name: "Edit", input: %{"file_path" => f}, id: "#{id}##{i}"}
        end)
    end
  end

  defp custom_tool_uses(%{"name" => name} = p) do
    [%{name: name || "CustomTool", input: %{"input" => p["input"]}, id: p["call_id"] || p["id"]}]
  end

  # File paths touched by a Codex apply_patch envelope (`*** Add/Update/Delete File: <path>`).
  defp parse_patch_files(input) when is_binary(input) do
    ~r/^\*\*\* (?:Add|Update|Delete) File: (.+)$/m
    |> Regex.scan(input, capture: :all_but_first)
    |> List.flatten()
    |> Enum.map(&String.trim/1)
  end

  defp parse_patch_files(_), do: []

  # ── tool results / errors ────────────────────────────────────────────────────

  defp tool_result(payload, error_fun) do
    %{tool_use_id: payload["call_id"], is_error: error_fun.(payload["output"])}
  end

  # exec output is a string ("Process exited with code N\n…") or, for image tools, a list (no error).
  defp output_error?(out) when is_binary(out) do
    case Regex.run(~r/Process exited with code (\d+)/, out) do
      [_, "0"] -> false
      [_, _code] -> true
      nil -> String.contains?(out, "SandboxDenied") or Regex.match?(~r/^\w+ failed:/, out)
    end
  end

  defp output_error?(_), do: false

  # custom-tool output is a JSON string carrying `metadata.exit_code` (apply_patch); fall back to
  # the inner `output` text, then the raw string heuristic.
  defp custom_output_error?(out) when is_binary(out) do
    case Jason.decode(out) do
      {:ok, %{"metadata" => %{"exit_code" => code}}} when is_integer(code) -> code != 0
      {:ok, %{"output" => text}} when is_binary(text) -> output_error?(text)
      _ -> output_error?(out)
    end
  end

  defp custom_output_error?(other), do: output_error?(other)

  # ── usage / context pressure ──────────────────────────────────────────────────

  # `last_token_usage.input_tokens` is the prompt fill for the most recent turn (it already includes
  # the cached portion); the peak across turns = context pressure. `info` is `null` early in a
  # session, so guard for the populated shape.
  defp usage_from_token_count(%{"last_token_usage" => %{"input_tokens" => prompt}} = info)
       when is_integer(prompt) do
    %{prompt_tokens: prompt, context_window: window_of(info["model_context_window"])}
  end

  defp usage_from_token_count(_), do: nil

  defp window_of(w) when is_integer(w) and w > 0, do: w
  defp window_of(_), do: nil

  # ── shared helpers ────────────────────────────────────────────────────────────

  defp decode_args(s) when is_binary(s) do
    case Jason.decode(s) do
      {:ok, m} when is_map(m) -> m
      _ -> %{}
    end
  end

  defp decode_args(m) when is_map(m), do: m
  defp decode_args(_), do: %{}

  defp parse_timestamp(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_timestamp(_), do: nil

  defp nilify_blank(text) do
    case String.trim(text) do
      "" -> nil
      _ -> text
    end
  end
end
