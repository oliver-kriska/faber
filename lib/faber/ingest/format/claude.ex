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

  # Blocks Claude Code injects into `role: "user"` turns that no human typed: background-task
  # completions, messages from other agent sessions, slash-command echoes, command output, and
  # system reminders. They are stripped from `Event.text` (never from `:raw`) so friction signals
  # scoped to human turns don't score the harness talking to itself — a `<task-notification>`
  # reporting "fixed, but the approach was wrong" trips the correction regex exactly like a human
  # would. See `.claude/research/2026-07-15-faber-scan-propose-verification.md`.
  #
  # `<command-args>` is deliberately NOT here: it holds what the user actually typed after a slash
  # command, which is genuine input.
  @synthetic_tags ~w(
    task-notification
    teammate-message
    system-reminder
    local-command-stdout
    local-command-caveat
    command-name
    command-message
  )

  # Well-formed pairs only, via a backreference to the opening tag — a genuine message that merely
  # *mentions* `<system-reminder>` in prose keeps its text. `s` so a block spans newlines; the lazy
  # body stops at the first matching close, so blocks nesting other tags strip as a unit.
  @synthetic_block_regex Regex.compile!(
                           "<(#{Enum.join(@synthetic_tags, "|")})(?:\\s[^>]*)?>.*?</\\1>",
                           "s"
                         )

  # Scaffolding prose Claude Code wraps around an injected teammate block. Stripping the block
  # alone leaves these orphans behind, and a non-blank residue reads as a genuine turn — the
  # postamble in particular trips the correction regex on "asks you to do it instead", which is
  # 4 of the 6 residual false positives measured on the audited session.
  #
  # Matched as prose rather than by "the turn had a teammate block, so bin the whole turn": that
  # structural shortcut would discard a genuine message *quoting* a teammate block (contract Risk
  # 1). The trade-off is version-sensitivity, so the postamble anchors on its stable opening clause
  # and runs to the end of the paragraph instead of pinning the exact closing sentence.
  @teammate_scaffolding [
    ~r/^[ \t]*Another Claude session sent a message:[ \t]*$/m,
    ~r/^[ \t]*This came from another Claude session\b.*?(?=\n[ \t]*\n|\z)/sm
  ]

  @impl true
  def default_base, do: @default_base

  # Claude Code names a project directory by flattening the session's working directory: every
  # character outside `[a-zA-Z0-9]` becomes `-`, case preserved. Verified against a real
  # `~/.claude/projects` rather than assumed, because the rule is wider than the obvious "slashes
  # become dashes" — dots and underscores go too:
  #
  #     /Users/o/Projects/faber                → -Users-o-Projects-faber
  #     /Users/o/Projects/andrej_skolenia      → -Users-o-Projects-andrej-skolenia   (underscore)
  #     /Users/o/.supacode/repos/x             → -Users-o--supacode-repos-x          (dot; note --)
  #     /Users/o/Projects/webSerialCommunication → …-webSerialCommunication          (case kept)
  #
  # The encoding is LOSSY and therefore one-way: `andrej_skolenia` and `andrej-skolenia` collide on
  # one directory. That is Claude Code's own behavior, not something this can undo — which is why
  # `Faber.Scan` still filters the scored results by `cwd` instead of trusting the directory alone.
  @slug_regex ~r/[^a-zA-Z0-9]/

  @doc """
  The project directory `cwd`'s transcripts would live in — `base` joined to Claude Code's
  flattened form of `cwd`.

  Pure: it reports where the directory *would* be, never whether it exists (see
  `c:Faber.Ingest.Format.project_base/2`). `cwd` is expanded first, so a relative or `~` path
  flattens the same way an absolute one does.
  """
  @impl true
  def project_base(base, cwd) when is_binary(base) and is_binary(cwd) do
    case cwd |> Path.expand() |> String.replace(@slug_regex, "-") do
      "" -> :error
      slug -> {:ok, base |> Path.expand() |> Path.join(slug)}
    end
  end

  def project_base(_base, _cwd), do: :error

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
    {text, synthetic?} = content |> extract_text() |> strip_synthetic()

    %Event{
      type: parse_type(map["type"]),
      role: message_role(message),
      timestamp: parse_timestamp(map["timestamp"]),
      uuid: map["uuid"],
      parent_uuid: map["parentUuid"],
      session_id: map["sessionId"],
      text: text,
      tool_uses: extract_tool_uses(content),
      tool_results: extract_tool_results(content),
      is_meta: map["isMeta"] == true,
      synthetic: synthetic?,
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

  # Remove harness-injected blocks, returning `{text, synthetic?}`. A turn is synthetic when it had
  # content and *nothing but* injected blocks: text that survives stripping was typed by a human, so
  # a real correction sent alongside a system-reminder still counts as a human turn.
  @spec strip_synthetic(String.t() | nil) :: {String.t() | nil, boolean()}
  defp strip_synthetic(nil), do: {nil, false}

  defp strip_synthetic(text) do
    stripped =
      @teammate_scaffolding
      |> Enum.reduce(Regex.replace(@synthetic_block_regex, text, ""), fn re, acc ->
        Regex.replace(re, acc, "")
      end)
      |> nilify_blank()

    {stripped, is_nil(stripped)}
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
