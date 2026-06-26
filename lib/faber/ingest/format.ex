defmodule Faber.Ingest.Format do
  @moduledoc """
  **The cross-agent ingest seam.** A behaviour each coding agent's transcript format implements,
  so `Faber.Ingest` stays agent-agnostic: it discovers files and streams normalized
  `Faber.Ingest.Event`s without knowing whose on-disk shape it's reading.

  Formats that ship today: `Faber.Ingest.Format.Claude` (Claude Code's
  `~/.claude/projects/**/*.jsonl`), `Faber.Ingest.Format.Codex` (OpenAI Codex's
  `~/.codex/sessions/**/rollout-*.jsonl`), `Faber.Ingest.Format.Cline` (the
  `saoudrizwan.claude-dev` VS Code extension's `**/tasks/*/api_conversation_history.json`), and
  `Faber.Ingest.Format.Gemini` (Google's `gemini-cli` — and, identically, Qwen Code —
  `~/.gemini/tmp/*/chats/session-*.json`), and `Faber.Ingest.Format.OpenCode` (the `opencode` CLI's
  SQLite DB at `~/.local/share/opencode/opencode.db`, read via the `sqlite3` CLI).
  Pi is **not yet implemented**: it needs a real transcript spec (file layout + per-record shape)
  before a faithful format module can be written, so it is deliberately absent rather than guessed.
  Adding one is a single new module implementing this behaviour plus a `format` alias — no engine
  changes.

  A format owns three things:

    * `default_base/0` — where this agent stores transcripts (`~`-relative is fine; the caller
      expands it).
    * `discover/1` — the transcript files under a base.
    * `stream_file!/1` — a lazy stream of `{:ok, Event.t()} | {:error, %{line:, reason:}}`, one
      element per record, so arbitrarily large sessions decode in constant memory.

  `normalize/1` (decoded-record → `Event`) is also part of the contract: it's the pure, testable
  core of `stream_file!/1`, exposed so format authors and tests can exercise mapping directly.
  """

  alias Faber.Ingest.Event

  @callback default_base() :: String.t()
  @callback discover(base :: String.t()) :: [Path.t()]
  @callback stream_file!(path :: Path.t()) :: Enumerable.t()
  @callback normalize(record :: map()) :: Event.t()

  @aliases %{
    claude: Faber.Ingest.Format.Claude,
    codex: Faber.Ingest.Format.Codex,
    cline: Faber.Ingest.Format.Cline,
    gemini: Faber.Ingest.Format.Gemini,
    opencode: Faber.Ingest.Format.OpenCode
  }

  @doc """
  Resolve a format from `opts[:format]` → `config :faber, :ingest_format` → the Claude default.

  Accepts a module directly or a short alias atom (`:claude`). Raises on an unknown alias so a
  typo'd or not-yet-shipped agent fails loudly rather than silently scanning the wrong format.
  """
  @spec resolve(keyword()) :: module()
  def resolve(opts \\ []) do
    case opts[:format] || Application.get_env(:faber, :ingest_format, :claude) do
      mod when is_atom(mod) -> from_alias(mod)
      other -> raise ArgumentError, "invalid ingest format: #{inspect(other)}"
    end
  end

  defp from_alias(value) do
    case Map.fetch(@aliases, value) do
      {:ok, mod} ->
        mod

      :error ->
        if Code.ensure_loaded?(value) and function_exported?(value, :stream_file!, 1) do
          value
        else
          raise ArgumentError,
                "unknown ingest format #{inspect(value)}; known: #{inspect(Map.keys(@aliases))} " <>
                  "(Pi not yet implemented)"
        end
    end
  end
end
