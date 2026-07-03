defmodule Faber.Ingest.Format.Claude do
  @moduledoc """
  Claude Code transcript format — the v1 ingest format.

  Transcripts live under `~/.claude/projects/**/*.jsonl`: line-delimited JSON, one event per
  line. This reads the *real* transcript — tool calls, results, failures, repetition — not a
  shallow report. Files are streamed line by line (`File.stream!/1`), so arbitrarily large
  sessions decode in constant memory, and malformed lines surface as `{:error, _}` rather than
  crashing the run.

  Untrusted transcript keys are decoded as **strings** (`keys: :strings`) — never atoms — to
  avoid atom-exhaustion (Iron Law: no `String.to_atom` on user-controlled input).
  """

  @behaviour Faber.Ingest.Format

  alias Faber.Ingest.Event

  @default_base "~/.claude/projects"

  @impl true
  def default_base, do: @default_base

  @doc """
  Discover Claude Code session files under `base` (default `#{@default_base}`).

  `Path.wildcard/2` does not expand `~`, so the base is `Path.expand/1`-ed first.
  """
  @impl true
  def discover(base \\ @default_base) do
    base
    |> Path.expand()
    |> Path.join("**/*.jsonl")
    |> Path.wildcard()
  end

  @doc """
  Stream a `.jsonl` transcript as `{:ok, Event.t()} | {:error, map()}` per line.

  Lazy: the file is read line by line and decoded on demand. Blank lines are skipped.
  """
  @impl true
  def stream_file!(path) do
    path
    |> File.stream!()
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == ""))
    |> Stream.map(&decode_line/1)
  end

  defp decode_line(line) do
    case Jason.decode(line, keys: :strings) do
      {:ok, map} when is_map(map) -> {:ok, normalize(map)}
      {:ok, other} -> {:error, %{line: line, reason: {:not_an_object, other}}}
      {:error, reason} -> {:error, %{line: line, reason: reason}}
    end
  end

  @doc """
  Normalize a decoded Claude transcript map (string keys) into an `Event`.
  """
  @impl true
  def normalize(map) when is_map(map) do
    message = map["message"]
    content = message_content(message, map)

    %Event{
      type: parse_type(map["type"]),
      role: message_role(message),
      timestamp: parse_timestamp(map["timestamp"]),
      uuid: map["uuid"],
      parent_uuid: map["parentUuid"],
      session_id: map["sessionId"],
      text: extract_text(content),
      tool_uses: extract_tool_uses(content),
      tool_results: extract_tool_results(content),
      is_meta: map["isMeta"] == true,
      cwd: map["cwd"],
      raw: map
    }
  end

  # `message` is usually a map, but the line is untrusted JSON — a non-map value must degrade
  # to an inert event, not crash the stream (the moduledoc promises malformed input never raises).
  defp message_role(%{"role" => role}), do: role
  defp message_role(_), do: nil

  defp parse_type("user"), do: :user
  defp parse_type("assistant"), do: :assistant
  defp parse_type("system"), do: :system
  defp parse_type("summary"), do: :summary
  defp parse_type(_), do: :other

  # message.content for user/assistant; system lines sometimes carry a top-level "content".
  defp message_content(%{"content" => content}, _map), do: content
  defp message_content(_message, %{"content" => content}), do: content
  defp message_content(_message, _map), do: nil

  defp parse_timestamp(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_timestamp(_), do: nil

  defp extract_text(content) when is_binary(content), do: nilify_blank(content)

  defp extract_text(content) when is_list(content) do
    content
    |> Enum.filter(&(is_map(&1) and &1["type"] == "text" and is_binary(&1["text"])))
    |> Enum.map_join("\n", & &1["text"])
    |> nilify_blank()
  end

  defp extract_text(_), do: nil

  defp nilify_blank(text) do
    case String.trim(text) do
      "" -> nil
      _ -> text
    end
  end

  defp extract_tool_uses(content) when is_list(content) do
    content
    |> Enum.filter(&(is_map(&1) and &1["type"] == "tool_use"))
    |> Enum.map(fn it ->
      %{name: it["name"], input: it["input"] || %{}, id: it["id"]}
    end)
  end

  defp extract_tool_uses(_), do: []

  defp extract_tool_results(content) when is_list(content) do
    content
    |> Enum.filter(&(is_map(&1) and &1["type"] == "tool_result"))
    |> Enum.map(fn it ->
      %{tool_use_id: it["tool_use_id"], is_error: it["is_error"] == true}
    end)
  end

  defp extract_tool_results(_), do: []
end
