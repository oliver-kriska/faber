defmodule Faber.CLI do
  @moduledoc """
  Command-line entry point for the single-binary distribution.

  When Faber runs as a Burrito release the binary's argv selects a subcommand; `command/0` parses
  it (and returns `nil` in dev/test/iex so `mix phx.server` and the LiveView tests behave exactly
  as before — the web endpoint still starts). `Faber.Application` calls `command/0` at boot, starts
  the web endpoint only for `serve` (so `faber scan` never binds a port), then `dispatch/1` runs the
  command: one-shot commands print and `System.halt/1`; `serve` prints the URL, opens the browser,
  and leaves the BEAM running.

  Subcommands: `scan`, `propose [--rank N] [--install] [--trigger]`, `serve [--port P] [--no-open]`,
  `help`, `--version`.
  """

  alias Faber.{Adapter, Eval, Install, Propose, Scan}

  @default_port 4710

  @typedoc "A parsed command: `{name, opts}`."
  @type command :: {atom(), keyword()}

  @doc "Parsed command when running as a Burrito release, else `nil` (dev/test/iex)."
  @spec command() :: command() | nil
  def command do
    case release_argv() do
      nil -> nil
      argv -> parse(argv)
    end
  end

  # Only treat argv as a CLI invocation inside an actual release wrapped by Burrito. `RELEASE_NAME`
  # is set by every release at runtime; the Burrito argv shim is only present in the wrapped binary.
  defp release_argv do
    if System.get_env("RELEASE_NAME") && function_exported?(Burrito.Util.Args, :argv, 0) do
      Burrito.Util.Args.argv()
    end
  end

  @doc "Pure argv → `{command, opts}` parser (no I/O), so it's unit-testable."
  @spec parse([String.t()]) :: command()
  def parse([]), do: {:help, []}
  def parse([h | _]) when h in ["help", "--help", "-h"], do: {:help, []}
  def parse([v | _]) when v in ["--version", "-V"], do: {:version, []}

  def parse(["scan" | rest]) do
    {opts, _, _} =
      OptionParser.parse(rest,
        strict: [limit: :integer, rank_by: :string, source: :string, db: :string, format: :string]
      )

    {:scan, opts}
  end

  def parse(["propose" | rest]) do
    {opts, _, _} =
      OptionParser.parse(rest,
        strict: [
          rank: :integer,
          install: :boolean,
          force: :boolean,
          trigger: :boolean,
          source: :string,
          db: :string,
          format: :string
        ]
      )

    {:propose, opts}
  end

  def parse(["serve" | rest]) do
    {opts, _, _} = OptionParser.parse(rest, strict: [port: :integer, open: :boolean])
    {:serve, opts}
  end

  def parse(["sync" | rest]) do
    {opts, _, _} =
      OptionParser.parse(rest,
        strict: [target: :string, check: :boolean, force: :boolean, dir: :string, file: :string]
      )

    {:sync, opts}
  end

  def parse([other | _]), do: {:unknown, arg: other}

  @doc """
  Apply a `serve --port` override to the endpoint config BEFORE the endpoint child starts. Called
  by `Faber.Application` between parsing the command and building the supervision tree.
  """
  @spec maybe_apply_port(command() | nil) :: :ok
  def maybe_apply_port({:serve, opts}) do
    if port = opts[:port] do
      cfg = Application.get_env(:faber, FaberWeb.Endpoint, [])
      http = Keyword.get(cfg, :http, []) |> Keyword.put(:port, port)
      Application.put_env(:faber, FaberWeb.Endpoint, Keyword.put(cfg, :http, http))
    end

    :ok
  end

  def maybe_apply_port(_), do: :ok

  @doc """
  Run the parsed command. `serve` returns (the listening endpoint keeps the VM up); one-shot
  commands run in their OWN process so `Faber.Application.start/2` returns cleanly rather than
  halting inside the boot path. The command prints synchronously, then `System.halt/1` stops the
  VM — which flushes pending stdio before exit (so the last line is never dropped).
  """
  @spec dispatch(command() | nil) :: :ok
  def dispatch(nil), do: :ok
  def dispatch({:serve, opts}), do: serve(opts)

  def dispatch({command, opts}) do
    # ALWAYS halt — if run/2 raises, halt with 1 rather than leaving the release VM hung with no
    # exit path (one-shot commands have no other process keeping the node alive).
    spawn(fn ->
      status =
        try do
          run(command, opts)
        rescue
          e -> halt_on_raise(e, __STACKTRACE__)
        end

      System.halt(status)
    end)

    :ok
  end

  defp halt_on_raise(error, stacktrace) do
    IO.puts(:stderr, "faber: #{Exception.message(error)}")
    IO.puts(:stderr, Exception.format_stacktrace(stacktrace))
    1
  end

  @doc "Run a one-shot command, returning a process exit status (0 ok / 1 error). No `halt`."
  @spec run(atom(), keyword()) :: non_neg_integer()
  def run(:help, _opts) do
    IO.puts(usage())
    0
  end

  def run(:version, _opts) do
    IO.puts("faber #{version()}")
    0
  end

  def run(:unknown, opts) do
    IO.puts(:stderr, "faber: unknown command '#{opts[:arg]}'\n")
    IO.puts(usage())
    1
  end

  def run(:scan, opts) do
    scan_opts =
      opts
      |> Keyword.take([:limit, :base, :min_messages, :db])
      |> put_if(:rank_by, normalize_rank_by(opts[:rank_by]))
      |> put_if(:source, normalize_source(opts[:source]))
      |> put_if(:format, normalize_format(opts[:format]))

    results = Scan.run(scan_opts)
    IO.puts(render_table(results))
    0
  end

  def run(:propose, opts) do
    rank = opts[:rank] || 1

    # Score all sessions so `--rank N` selects from the TRUE friction ranking (a `:limit` here
    # would sample a subset and could miss the worst sessions). `--limit` still passes through.
    scan_opts =
      opts
      |> Keyword.take([:limit, :base, :min_messages, :db])
      |> put_if(:source, normalize_source(opts[:source]))
      |> put_if(:format, normalize_format(opts[:format]))

    # `--trigger` opts into the behavioral trigger-accuracy dimension (one keyless LLM call per
    # fixture). It's off by default and one-shot only — never wired into the reflective loop, where
    # optimizing a composite that includes an LLM-judged dimension would let the loop game its own
    # generated fixtures (see .claude/research/2026-06-26-behavioral-eval-trigger-accuracy.md).
    trigger? = opts[:trigger] == true

    with {:ok, adapter} <- Adapter.load(Faber.adapter_dir()),
         %Scan.Result{} = result <- Enum.at(Scan.run(scan_opts), rank - 1),
         :ok <- stack_gate(adapter, result, opts[:force]),
         {:ok, proposal} <- Propose.propose(result, adapter),
         {:ok, eval} <- Eval.score(proposal, adapter: adapter, trigger: trigger?) do
      IO.puts(render_proposal(proposal, eval, adapter))
      maybe_install(proposal, adapter, opts[:install])
      0
    else
      nil ->
        IO.puts(:stderr, "faber: no session at rank #{rank}")
        1

      {:error, {:stack_mismatch, adapter, result}} ->
        IO.puts(:stderr, stack_mismatch_message(adapter, result))
        1

      {:error, reason} ->
        IO.puts(:stderr, "faber propose failed: #{inspect(reason)}")
        1
    end
  end

  def run(:sync, opts) do
    targets = parse_targets(opts[:target])
    check? = opts[:check] == true
    pass = Keyword.take(opts, [:force, :dir, :file])

    results =
      Enum.map(targets, fn agent ->
        {agent,
         if(check?,
           do: Install.check_pointer(agent, pass),
           else: Install.sync_pointer(agent, pass)
         )}
      end)

    Enum.each(results, fn {agent, result} -> IO.puts(format_sync(agent, result)) end)
    if Enum.all?(results, fn {_a, r} -> sync_ok?(r) end), do: 0, else: 1
  end

  defp parse_targets(nil), do: ["claude"]
  defp parse_targets(str), do: str |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

  defp sync_ok?({:ok, _}), do: true
  defp sync_ok?(:in_sync), do: true
  defp sync_ok?(_), do: false

  defp format_sync(agent, {:ok, :written}), do: "#{agent}: pointer updated"
  defp format_sync(agent, {:ok, :unchanged}), do: "#{agent}: already up to date"
  defp format_sync(agent, :in_sync), do: "#{agent}: in sync"
  defp format_sync(agent, :drift), do: "#{agent}: DRIFT — run `faber sync --target #{agent}`"

  defp format_sync(agent, :absent),
    do: "#{agent}: no Faber block yet — run `faber sync --target #{agent}`"

  defp format_sync(agent, :modified),
    do: "#{agent}: block hand-edited — `faber sync --target #{agent} --force` to overwrite"

  defp format_sync(agent, {:error, :block_modified}),
    do: "#{agent}: block hand-edited — re-run with --force to overwrite"

  defp format_sync(agent, {:error, {:unknown_agent, a}}), do: "#{agent}: unknown agent '#{a}'"
  defp format_sync(agent, other), do: "#{agent}: #{inspect(other)}"

  # Stack-aware gate: refuse to draft a skill when the chosen session doesn't belong to the
  # adapter's stack (e.g. proposing an Elixir skill for a Codex/Next.js session). `--force` skips it.
  defp stack_gate(_adapter, _result, true), do: :ok

  defp stack_gate(adapter, result, _force) do
    if Adapter.matches_session?(adapter, result.file_paths),
      do: :ok,
      else: {:error, {:stack_mismatch, adapter, result}}
  end

  defp stack_mismatch_message(adapter, result) do
    exts =
      result.file_paths
      |> Enum.map(&Path.extname/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.frequencies()
      |> Enum.sort_by(fn {_ext, n} -> -n end)
      |> Enum.map_join(", ", fn {ext, n} -> "#{ext}×#{n}" end)

    """
    faber: session #{session(result)} doesn't match adapter '#{adapter.name}' (stack mismatch).
      Files touched: #{if exts == "", do: "none", else: exts}
      This adapter targets: #{Enum.join(adapter.file_globs, ", ")}
      Re-run with --force to draft anyway.
    """
  end

  # ── serve ────────────────────────────────────────────────────────────────-

  # The endpoint is already a started child (Faber.Application added it for :serve). Print the URL
  # and open the browser; the listening endpoint keeps the BEAM alive. `:opener` is injectable for
  # tests; `--no-open` (open: false) skips it.
  defp serve(opts) do
    url = "http://localhost:#{serve_port()}"
    IO.puts("Faber UI → #{url}  (Ctrl-C to stop)")

    if Keyword.get(opts, :open, true) do
      opener = Keyword.get(opts, :opener, &open_browser/1)
      opener.(url)
    end

    :ok
  end

  defp serve_port do
    Application.get_env(:faber, FaberWeb.Endpoint, [])
    |> Keyword.get(:http, [])
    |> Keyword.get(:port, @default_port)
  end

  defp open_browser(url) do
    case :os.type() do
      {:unix, :darwin} -> System.cmd("open", [url])
      {:unix, _} -> System.cmd("xdg-open", [url])
      _ -> {"", 0}
    end
  rescue
    e ->
      IO.puts(:stderr, "could not open browser (open #{url} manually): #{Exception.message(e)}")
  end

  # ── rendering ──────────────────────────────────────────────────────────────

  defp render_table([]), do: "No sessions matched."

  defp render_table(results) do
    header = "  #  friction  fingerprint            signal           msgs  t2  session"

    rows =
      results
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {r, i} ->
        [
          String.pad_leading(to_string(i), 3),
          String.pad_leading(fmt(r.raw), 9),
          String.pad_trailing(to_string(r.fingerprint), 22),
          String.pad_trailing(to_string(r.dominant_signal || "—"), 16),
          String.pad_leading(to_string(r.message_count), 5),
          String.pad_leading(if(r.tier2, do: "✓", else: ""), 3),
          "  " <> session(r)
        ]
        |> Enum.join(" ")
      end)

    "#{header}\n#{rows}\n\n#{length(results)} sessions shown."
  end

  defp render_proposal(proposal, eval, adapter) do
    verdict = if eval.passed, do: "PASS", else: "below threshold #{eval.threshold}"

    """
    #{proposal.name} — composite #{fmt(eval.composite)} (#{verdict})

    #{Propose.render_skill_md(proposal, adapter)}
    """
  end

  defp maybe_install(_proposal, _adapter, install) when install in [nil, false], do: :ok

  defp maybe_install(proposal, adapter, true) do
    case Install.install(proposal, adapter: adapter) do
      {:ok, path} -> IO.puts("installed → #{path}")
      {:error, reason} -> IO.puts(:stderr, "install failed: #{inspect(reason)}")
    end
  end

  defp session(%{path: path, session_id: sid} = result) do
    project = project_label(result, path)
    short = if is_binary(sid), do: String.slice(sid, 0, 8), else: Path.basename(path, ".jsonl")
    "#{project}/#{short}"
  end

  # Prefer the session's real working dir (clean project name) over the transcript path, which is
  # an opaque slug for Claude and a date directory for Codex. Falls back to the path basename.
  defp project_label(%{cwd: cwd}, _path) when is_binary(cwd) and cwd != "",
    do: Path.basename(cwd)

  defp project_label(_result, path), do: path |> Path.dirname() |> Path.basename()

  defp normalize_rank_by(rb) when rb in [:raw, :rate], do: rb
  defp normalize_rank_by("rate"), do: :rate
  defp normalize_rank_by("raw"), do: :raw
  defp normalize_rank_by(_), do: nil

  defp normalize_source(s) when s in [:files, :ccrider], do: s
  defp normalize_source("files"), do: :files
  defp normalize_source("ccrider"), do: :ccrider
  defp normalize_source(_), do: nil

  defp normalize_format(f) when f in [:claude, :codex], do: f
  defp normalize_format("claude"), do: :claude
  defp normalize_format("codex"), do: :codex
  defp normalize_format(_), do: nil

  defp put_if(opts, _key, nil), do: opts
  defp put_if(opts, key, value), do: Keyword.put(opts, key, value)

  defp fmt(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 1)
  defp fmt(n), do: to_string(n)

  defp version do
    case Application.spec(:faber, :vsn) do
      vsn when is_list(vsn) -> List.to_string(vsn)
      _ -> "dev"
    end
  end

  defp usage do
    """
    faber #{version()} — local-first improvement engine for AI coding agents

    Usage:
      faber scan [--limit N] [--rank-by raw|rate] [--source S] [--format F] [--db PATH]
                                                    Rank session friction
      faber propose [--rank N] [--install] [--force] [--trigger] [--source S] [--format F] [--db PATH]
                                                    Draft + eval a skill for one session
                                                    (--force: skip the stack-match gate;
                                                     --trigger: add the behavioral trigger-accuracy
                                                     dimension — one keyless LLM call per fixture)
      faber serve [--port P] [--no-open]            Start the dashboard UI in your browser
                                                    (also serves the read-only MCP server at /mcp)
      faber sync [--target claude,codex] [--check] [--force] [--dir PATH]
                                                    Register installed skills in each agent's
                                                    context file (managed block; --check: report
                                                    drift only, no write)
      faber help | --version

    Sources (--source): files (default) walks the agent's transcript dir; ccrider reads ccrider's
    SQLite index (--db, default ~/.config/ccrider/sessions.db). Or set config :faber, :ingest_source.

    Formats (--format): claude (default, ~/.claude/projects) or codex (~/.codex/sessions). The codex
    format is files-only — ccrider stores codex content empty, so use --source files --format codex.
    """
  end
end
