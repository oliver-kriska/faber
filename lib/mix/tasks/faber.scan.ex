defmodule Mix.Tasks.Faber.Scan do
  @shortdoc "Rank coding-agent sessions by friction"
  @moduledoc """
  Scan Claude Code transcripts and print the highest-friction sessions.

      mix faber.scan                       # top 20 for THIS project
      mix faber.scan --all                 # ...across every project
      mix faber.scan --top 30
      mix faber.scan --limit 200           # score an even sample of 200 sessions
      mix faber.scan --base /path/to/dir --min-messages 10
      mix faber.scan --format opencode     # scan another agent (codex|cline|gemini|opencode)

  Options:

    * `--top N`            rows to print (default 20)
    * `--all`              rank every project, not just the one you're in
    * `--limit N`          cap sessions scored (default: all)
    * `--min-messages N`   drop trivial sessions (default 4)
    * `--base PATH`        transcript root (default: the format's own default)
    * `--format AGENT`     ingest format: claude (default), codex, cline, gemini, opencode
    * `--no-dedupe`        keep sidechain duplicates that share a session_id

  Read-only: this task does not start the application (Iron Law #23 — start only what you
  need); it just discovers, parses, and scores.
  """

  use Mix.Task

  alias Faber.CLI.Render
  alias Faber.Scan.Scope

  @switches [
    top: :integer,
    limit: :integer,
    min_messages: :integer,
    base: :string,
    format: :string,
    dedupe: :boolean,
    all: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _argv, _invalid} = OptionParser.parse(argv, strict: @switches)
    top = Keyword.get(opts, :top, 20)
    scan_opts = scan_opts(opts)

    started = System.monotonic_time(:millisecond)
    results = Faber.Scan.run(scan_opts)
    elapsed = System.monotonic_time(:millisecond) - started

    print_report(results, top, elapsed, scan_opts[:scope])
  end

  @doc false
  # Public (`@doc false`) so the scope decision is unit-testable without scanning the developer's
  # real `~/.claude` — the same reason `Faber.CLI.humanize_error/1` is. A test cannot reach this
  # through argv: proving cwd-scoping needs an injected format module, and `--format` only accepts
  # the names `Format.cast/1` knows.
  #
  # Resolution mirrors `Faber.CLI.scan_opts/2` deliberately, through the same public `Scope` API, so
  # the policy has ONE owner. `Scope.resolve/1` is asked with the NORMALIZED opts because it has to
  # ask the format module where transcripts live, and `Format.resolve/1` raises on the `--format`
  # *string* that argv carries.
  def scan_opts(opts) do
    resolved =
      opts
      |> Keyword.take([:limit, :min_messages, :base, :dedupe])
      |> put_format(opts[:format])

    scope = Scope.resolve(Keyword.put(resolved, :all, opts[:all] == true))
    Keyword.put(resolved, :scope, scope)
  end

  # Validate `--format` against the ingest registry; fail loudly on a typo rather than silently
  # scanning the default (Claude) format. Absent flag → no `:format` key → Scan defaults to Claude.
  defp put_format(scan_opts, nil), do: scan_opts

  defp put_format(scan_opts, format) do
    case Faber.Ingest.Format.cast(format) do
      {:ok, atom} ->
        Keyword.put(scan_opts, :format, atom)

      :error ->
        Mix.raise(
          "unknown --format #{inspect(format)}; known: " <>
            (Faber.Ingest.Format.known() |> Enum.map_join(", ", &Atom.to_string/1))
        )
    end
  end

  defp print_report([], _top, elapsed, scope) do
    Mix.shell().info(Render.scope_line(scope))
    Mix.shell().info("No sessions matched (scanned in #{elapsed}ms).")
  end

  defp print_report(results, top, elapsed, scope) do
    total = length(results)
    tier2 = Enum.count(results, & &1.tier2)

    # The same line `faber scan` prints, from the same function — a scan that silently changed which
    # sessions it ranks is unreadable without it: "Top 20" of what?
    Mix.shell().info(Render.scope_line(scope))

    Mix.shell().info(
      "Scanned #{total} non-trivial sessions in #{elapsed}ms — #{tier2} tier-2 eligible. Top #{min(top, total)}:\n"
    )

    Mix.shell().info(
      pad("#", 4) <>
        pad("FRICTION", 10) <>
        pad("EVENTS", 8) <>
        pad("TURNS", 7) <>
        pad("TOOLS", 6) <>
        pad("ERRS", 6) <>
        pad("TYPE", 14) <>
        pad("OPP", 6) <> pad("DOMINANT SIGNAL", 22) <> pad("T2", 4) <> "SESSION"
    )

    results
    |> Enum.take(top)
    |> Enum.with_index(1)
    |> Enum.each(fn {r, i} ->
      Mix.shell().info(
        pad("#{i}", 4) <>
          pad(Render.raw_score(r.raw), 10) <>
          pad("#{r.message_count}", 8) <>
          pad("#{r.human_turns}", 7) <>
          pad("#{r.tool_count}", 6) <>
          pad("#{r.error_count}", 6) <>
          pad(type_label(r), 14) <>
          pad(Render.friction(r.opportunity), 6) <>
          pad(signal_label(r.dominant_signal), 22) <>
          pad(if(r.tier2, do: "✓", else: ""), 4) <> session_label(r)
      )
    end)

    Mix.shell().info(
      "\nFRICTION = raw weighted friction (rank metric); TYPE = session fingerprint;" <>
        " OPP = missed-automation score; T2 = tier-2 eligible."
    )
  end

  # "<type> ~<confidence>" truncated to fit, e.g. "feature ~.8".
  defp type_label(%{fingerprint: type, fingerprint_confidence: conf}) do
    c = conf |> Float.round(1) |> :erlang.float_to_binary(decimals: 1) |> String.trim_leading("0")
    String.slice("#{type} ~#{c}", 0, 13)
  end

  defp signal_label(nil), do: Render.none()
  defp signal_label(signal), do: to_string(signal)

  # "<project>/<short-session-id>" — compact, no transcript content.
  defp session_label(%{path: path, session_id: sid}) do
    project = path |> Path.dirname() |> Path.basename()
    short = if is_binary(sid), do: String.slice(sid, 0, 8), else: Path.basename(path, ".jsonl")
    "#{project}/#{short}"
  end

  defp pad(str, width), do: String.pad_trailing(str, width)
end
