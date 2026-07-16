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

  @doc """
  Where under `base` this format keeps the transcripts of sessions run in `cwd` — the seam
  `Faber.Scan.Scope` narrows a scan through, so scoping to one project reads that project's
  directory instead of the whole corpus (~40x fewer files on a real machine).

  **Pure, and answers "would live", not "does live".** It must not touch the filesystem: the
  caller owns the existence check and the fallback, because "cwd is not a known project" is a
  policy question (does it mean scan everything? say nothing?) that a format has no business
  deciding. Return `:error` when `cwd` has no representable directory at all.

  Optional: implement it only for formats that **partition storage by project**, which is what
  makes the narrowing possible. Codex (date-stamped rollout dirs), Gemini (an opaque project
  hash), and OpenCode (one SQLite DB) do not, so they decline it and `Faber.Scan` falls back to
  filtering scored results by `cwd` — same answer, no speedup.
  """
  @callback project_base(base :: String.t(), cwd :: String.t()) :: {:ok, Path.t()} | :error

  @optional_callbacks project_base: 2

  @doc """
  The directory `cwd`'s transcripts would live in for `format`, or `:error` if the format does not
  partition by project (or cannot represent this `cwd`).

  Wraps the optional `c:project_base/2` so callers never have to `function_exported?/3` — which is
  also load-bearing in a Burrito release: it boots in `-mode embedded` and does not autoload, so
  the check needs the `Code.ensure_loaded?/1` this does.
  """
  @spec project_base(module(), String.t(), String.t()) :: {:ok, Path.t()} | :error
  def project_base(format, base, cwd) do
    if Code.ensure_loaded?(format) and function_exported?(format, :project_base, 2) do
      format.project_base(base, cwd)
    else
      :error
    end
  end

  @aliases %{
    claude: Faber.Ingest.Format.Claude,
    codex: Faber.Ingest.Format.Codex,
    cline: Faber.Ingest.Format.Cline,
    gemini: Faber.Ingest.Format.Gemini,
    opencode: Faber.Ingest.Format.OpenCode
  }

  @doc """
  The known format aliases (the keys of the alias map) — the single source of truth for which
  agents are selectable. CLI surfaces validate `--format` against this so they can't drift behind
  a newly-added format.
  """
  @spec known() :: [atom()]
  def known, do: Map.keys(@aliases)

  @doc """
  Cast a user-supplied format (string or atom) to a known alias atom, or `:error`.

  Used by CLI entrypoints to validate untrusted `--format` input **without** `String.to_atom/1` —
  it compares the string form of each known alias, so an unknown value can never mint a new atom.
  """
  @spec cast(String.t() | atom()) :: {:ok, atom()} | :error
  def cast(value) when is_atom(value) do
    if value in known(), do: {:ok, value}, else: :error
  end

  def cast(value) when is_binary(value) do
    case Enum.find(known(), fn name -> Atom.to_string(name) == value end) do
      nil -> :error
      name -> {:ok, name}
    end
  end

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
