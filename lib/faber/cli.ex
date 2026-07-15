defmodule Faber.CLI do
  @moduledoc """
  Command-line entry point for the single-binary distribution.

  When Faber runs as a Burrito release the binary's argv selects a subcommand; `command/0` parses
  it (and returns `nil` in dev/test/iex so `mix phx.server` and the LiveView tests behave exactly
  as before — the web endpoint still starts). `Faber.Application` calls `command/0` at boot, starts
  the web endpoint only for `serve` (so `faber scan` never binds a port), then `dispatch/1` runs the
  command: one-shot commands print and `System.halt/1`; `serve` prints the URL, opens the browser,
  and leaves the BEAM running.

  Subcommands: `scan`, `propose [--rank N] [--install] [--trigger]`, `refine`, `consolidate
  [--top N] [--cluster-threshold F]`, `feedback`, `serve [--port P] [--no-open]`, `sync`,
  `help`, `--version`.
  """

  alias Faber.{Adapter, Consolidate, Eval, Install, Loop, Propose, Proposal, Scan}

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

  # Only treat argv as a CLI invocation inside an actual release wrapped by Burrito.
  #
  # Two things this guard must get right, both of which silently degrade to `nil` — i.e. to booting
  # the dashboard instead of running the subcommand:
  #
  #   * `__BURRITO`, not `RELEASE_NAME`. Burrito's launcher execs `erl` directly instead of the
  #     release's generated bin script, so it exports RELEASE_ROOT/RELEASE_SYS_CONFIG/`__BURRITO`
  #     but never RELEASE_NAME. (Mirrors Burrito.Util.running_standalone?/0.)
  #   * `Code.ensure_loaded?`, not `function_exported?`. A release boots in `-mode embedded` and
  #     `Application.start/2` runs before Burrito's modules are loaded; `function_exported?/3` does
  #     not autoload, so it answers false for a module that is present and loadable.
  defp release_argv do
    if System.get_env("__BURRITO") && Code.ensure_loaded?(Burrito.Util.Args) do
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
        strict: [
          limit: :integer,
          rank_by: :string,
          source: :string,
          db: :string,
          format: :string,
          base: :string,
          min_messages: :integer
        ]
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
          format: :string,
          limit: :integer,
          base: :string,
          min_messages: :integer
        ]
      )

    {:propose, opts}
  end

  def parse(["refine" | rest]) do
    {opts, _, _} =
      OptionParser.parse(rest,
        strict: [
          rank: :integer,
          strategy: :string,
          iterations: :integer,
          patience: :integer,
          target: :float,
          min_improvement: :float,
          trigger: :boolean,
          trigger_samples: :integer,
          holdout: :boolean,
          install: :boolean,
          force: :boolean,
          source: :string,
          db: :string,
          format: :string,
          limit: :integer,
          base: :string,
          min_messages: :integer
        ]
      )

    {:refine, opts}
  end

  def parse(["consolidate" | rest]) do
    {opts, _, _} =
      OptionParser.parse(rest,
        strict: [
          top: :integer,
          cluster_threshold: :float,
          trigger: :boolean,
          force: :boolean,
          source: :string,
          db: :string,
          format: :string,
          limit: :integer,
          base: :string,
          min_messages: :integer
        ]
      )

    {:consolidate, opts}
  end

  def parse(["feedback" | rest]) do
    {opts, _, _} =
      OptionParser.parse(rest,
        strict: [
          dir: :string,
          source: :string,
          db: :string,
          format: :string,
          limit: :integer,
          base: :string,
          min_messages: :integer
        ]
      )

    {:feedback, opts}
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
    # ALWAYS halt — if run/2 raises, exits, or throws, halt with 1 rather than leaving the
    # release VM hung with no exit path (one-shot commands have no other process keeping the node
    # alive). `catch` is load-bearing, not belt-and-braces: `Faber.Subprocess` re-raises abnormal
    # task exits via `exit/1`, which `rescue` alone lets escape — the process would die with
    # System.halt/1 never reached and the VM hung.
    Task.start(fn -> System.halt(guarded(fn -> run(command, opts) end)) end)
    :ok
  end

  @doc false
  # The halt-guard of dispatch/1, minus the halt — exposed so the raise/exit/throw → exit-status-1
  # contract is unit-testable (System.halt/1 itself can't be exercised in a test).
  @spec guarded((-> non_neg_integer())) :: non_neg_integer()
  def guarded(fun) do
    fun.()
  rescue
    e -> fail("faber: #{Exception.message(e)}", __STACKTRACE__)
  catch
    kind, reason -> fail("faber: uncaught #{kind}: #{inspect(reason)}", __STACKTRACE__)
  end

  defp fail(message, stacktrace) do
    IO.puts(:stderr, message)
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
    # fixture). Off by default. In the loop (`Faber.Loop.refine/3` with `trigger: true`) the same
    # dimension is safe to optimize only because candidates are scored against the SEED's fixtures,
    # pinned — a candidate can't game the objective by rewriting its own exam (see
    # .claude/research/2026-06-26-behavioral-eval-trigger-accuracy.md and the Loop moduledoc).
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

  def run(:refine, opts) do
    rank = opts[:rank] || 1

    scan_opts =
      opts
      |> Keyword.take([:limit, :base, :min_messages, :db])
      |> put_if(:source, normalize_source(opts[:source]))
      |> put_if(:format, normalize_format(opts[:format]))

    # CLI defaults are deliberately tighter than the library's (5 iterations vs 50): every
    # iteration is a real `claude -p` propose + eval, so a CLI run should be minutes, not hours.
    # Strategy defaults to :reflect — targeted edits from eval feedback beat blind regeneration
    # (see .claude/research/2026-06-23-gepa-reflective-loop-decision.md).
    refine_opts =
      [
        strategy: normalize_strategy(opts[:strategy]),
        max_iterations: opts[:iterations] || 5
      ]
      |> put_if(:patience, opts[:patience])
      |> put_if(:target, opts[:target])
      |> put_if(:min_improvement, opts[:min_improvement])
      |> put_if(:trigger, opts[:trigger])
      |> put_if(:trigger_samples, opts[:trigger_samples])
      |> put_if(:trigger_holdout, opts[:holdout])

    with {:ok, adapter} <- Adapter.load(Faber.adapter_dir()),
         %Scan.Result{} = result <- Enum.at(Scan.run(scan_opts), rank - 1),
         :ok <- stack_gate(adapter, result, opts[:force]),
         %Loop.State{} = state <- Loop.refine(result, adapter, refine_opts) do
      IO.puts(render_refinement(state, adapter))
      maybe_install_best(state, adapter, opts[:install])
      0
    else
      nil ->
        IO.puts(:stderr, "faber: no session at rank #{rank}")
        1

      {:error, {:stack_mismatch, adapter, result}} ->
        IO.puts(:stderr, stack_mismatch_message(adapter, result))
        1

      {:error, reason} ->
        IO.puts(:stderr, "faber refine failed: #{inspect(reason)}")
        1
    end
  end

  def run(:consolidate, opts) do
    top = opts[:top] || 5

    scan_opts =
      opts
      |> Keyword.take([:limit, :base, :min_messages, :db])
      |> put_if(:source, normalize_source(opts[:source]))
      |> put_if(:format, normalize_format(opts[:format]))

    # `:threshold` here is Consolidate's CLUSTER threshold (token-Jaccard); the eval gate keeps
    # its own configured bar. `--trigger` forwards to the gate like `propose --trigger`.
    consolidate_opts =
      []
      |> put_if(:threshold, opts[:cluster_threshold])
      |> put_if(:trigger, opts[:trigger])

    case Adapter.load(Faber.adapter_dir()) do
      {:ok, adapter} ->
        {candidates, skipped} =
          scan_opts
          |> Scan.run()
          |> Enum.take(top)
          |> Enum.split_with(fn r ->
            opts[:force] == true or Adapter.matches_session?(adapter, r.file_paths)
          end)

        if skipped != [] do
          IO.puts(
            :stderr,
            "skipping #{length(skipped)} stack-mismatched session(s) — --force includes them"
          )
        end

        consolidate_proposals(candidates, adapter, consolidate_opts, top)

      {:error, reason} ->
        IO.puts(:stderr, "faber consolidate failed: #{inspect(reason)}")
        1
    end
  end

  def run(:feedback, opts) do
    feedback_opts =
      opts
      |> Keyword.take([:dir, :limit, :base, :min_messages, :db])
      |> put_if(:source, normalize_source(opts[:source]))
      |> put_if(:format, normalize_format(opts[:format]))

    case Faber.Feedback.report(feedback_opts) do
      [] ->
        IO.puts("No Faber-installed skills found. Install one with `faber propose --install`.")
        0

      reports ->
        IO.puts(render_feedback(reports))
        0
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

  # ── consolidate ─────────────────────────────────────────────────────────────

  # Draft one proposal per candidate session (reporting per-session failures without aborting
  # the batch), then cluster + merge + gate the survivors and print one line per outcome.
  defp consolidate_proposals(candidates, adapter, consolidate_opts, top) do
    {proposals, failures} =
      Enum.reduce(candidates, {[], []}, fn r, {oks, errs} ->
        case Propose.propose(r, adapter) do
          {:ok, p} -> {[p | oks], errs}
          {:error, reason} -> {oks, [{r, reason} | errs]}
        end
      end)

    failures
    |> Enum.reverse()
    |> Enum.each(fn {r, reason} ->
      IO.puts(:stderr, "propose failed for #{session(r)}: #{inspect(reason)}")
    end)

    case Enum.reverse(proposals) do
      [] ->
        IO.puts(:stderr, "faber: no proposals to consolidate (top #{top} sessions)")
        1

      proposals ->
        outcomes = Consolidate.run(proposals, adapter, consolidate_opts)
        IO.puts(render_outcomes(outcomes))
        0
    end
  end

  defp render_outcomes(outcomes) do
    lines = Enum.map_join(outcomes, "\n", &render_outcome/1)
    counts = Enum.frequencies_by(outcomes, &elem(&1, 0))

    summary =
      "#{length(outcomes)} cluster(s): #{counts[:merged] || 0} merged, " <>
        "#{counts[:kept] || 0} kept, #{counts[:kept_originals] || 0} kept-originals, " <>
        "#{counts[:error] || 0} errors."

    "#{lines}\n\n#{summary}"
  end

  # One line per Consolidate outcome, mirroring `t:Faber.Consolidate.outcome/0`.
  defp render_outcome({:kept, p}),
    do: "  kept            —       #{p.name} (singleton cluster)"

  defp render_outcome({:merged, merged, eval, originals}),
    do: "  MERGED          #{fmt4(eval.composite)}  #{merged.name} ← #{names(originals)}"

  defp render_outcome({:kept_originals, originals, eval}),
    do: "  kept-originals  #{fmt4(eval.composite)}  merge below gate — #{names(originals)}"

  defp render_outcome({:error, originals, reason}),
    do: "  error           —       #{names(originals)}: #{inspect(reason)}"

  defp names(proposals), do: Enum.map_join(proposals, " + ", & &1.name)

  # ── refine rendering / install ──────────────────────────────────────────────

  defp render_refinement(%Loop.State{} = state, adapter) do
    kept = Enum.count(state.history, & &1.kept)
    start = starting_composite(state)

    history =
      Enum.map_join(state.history, "\n", fn e ->
        marker = if e.kept, do: "KEEP", else: " -- "

        note =
          case e.reason do
            nil -> ""
            reason -> "  (#{reason})"
          end

        "  #{String.pad_leading(to_string(e.iteration), 3)}  #{marker}  " <>
          "#{fmt4(e.new_composite)}  #{e.description}#{note}"
      end)

    """
    #{state.skill || "skill"} — refined #{fmt4(start)} → #{fmt4(state.best_composite)} \
    (#{state.status}, #{kept}/#{length(state.history)} kept)

    #{history}
    #{render_holdout(state.holdout)}
    #{render_best(state, adapter)}
    """
  end

  # The seed's composite is the first entry's old_composite (entries record best-at-the-time).
  defp starting_composite(%Loop.State{history: [first | _]}), do: first.old_composite
  defp starting_composite(%Loop.State{best_composite: best}), do: best

  defp render_holdout(nil), do: ""

  defp render_holdout(%{error: reason}),
    do: "\nholdout: validation scoring failed — #{inspect(reason)}\n"

  defp render_holdout(%{composite: comp, behavioral: behavioral, fixtures: n}) do
    "\nholdout: composite #{fmt4(comp)}, behavioral #{fmt4(behavioral)} " <>
      "(#{n} validation fixtures the loop never optimized against)\n"
  end

  defp render_best(%Loop.State{best_proposal: %Proposal{} = p}, adapter),
    do: "\n#{Propose.render_skill_md(p, adapter)}"

  defp render_best(%Loop.State{best_content: content}, _adapter) when is_binary(content),
    do: "\n#{content}"

  defp render_best(_state, _adapter), do: ""

  defp maybe_install_best(_state, _adapter, install) when install in [nil, false], do: :ok

  defp maybe_install_best(%Loop.State{best_proposal: %Proposal{} = p}, adapter, true),
    do: maybe_install(p, adapter, true)

  defp maybe_install_best(_state, _adapter, true) do
    IO.puts(:stderr, "install skipped: the run tracked no proposal")
  end

  defp normalize_strategy("regenerate"), do: :regenerate
  defp normalize_strategy("reflect"), do: :reflect
  defp normalize_strategy(_), do: :reflect

  # ── feedback rendering ──────────────────────────────────────────────────────

  defp render_feedback(reports) do
    header =
      "  skill                            sessions  used   rate   friction w/  w/o   verdict"

    rows =
      Enum.map_join(reports, "\n", fn r ->
        [
          "  " <> String.pad_trailing(r.skill, 32),
          String.pad_leading(to_string(r.sessions), 8),
          String.pad_leading(to_string(r.sessions_used), 5),
          String.pad_leading(fmt_rate(r.usage_rate), 6),
          String.pad_leading(fmt_friction(r.friction_with), 12),
          String.pad_leading(fmt_friction(r.friction_without), 5),
          "   #{r.verdict}"
        ]
        |> Enum.join(" ")
      end)

    hints =
      case Enum.filter(reports, &(&1.verdict == :unused)) do
        [] ->
          ""

        unused ->
          names = Enum.map_join(unused, ", ", & &1.skill)

          "\n\nunused: #{names} — sessions ran but the skill never fired; " <>
            "`faber refine --trigger` its routing, or remove it."
      end

    "#{header}\n#{rows}#{hints}"
  end

  defp fmt_rate(nil), do: "—"
  defp fmt_rate(rate), do: "#{round(rate * 100)}%"

  defp fmt_friction(nil), do: "—"
  defp fmt_friction(n), do: :erlang.float_to_binary(n * 1.0, decimals: 2)

  defp fmt4(n) when is_number(n), do: :erlang.float_to_binary(n * 1.0, decimals: 4)
  defp fmt4(_), do: "n/a"

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

  # Validate `--format` against the ingest format registry (single source of truth) rather than a
  # hand-maintained whitelist that drifts behind newly-added agents. Unknown/blank → nil, so it
  # falls back to the default format (parity with normalize_source/normalize_rank_by above).
  defp normalize_format(f) do
    case f && Faber.Ingest.Format.cast(f) do
      {:ok, format} -> format
      _ -> nil
    end
  end

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
                 [--base DIR] [--min-messages N]   Rank session friction
                                                    (--base: transcript root override;
                                                     --min-messages: skip shorter sessions)
      faber propose [--rank N] [--install] [--force] [--trigger] [--source S] [--format F] [--db PATH]
                    [--base DIR] [--min-messages N]
                                                    Draft + eval a skill for one session
                                                    (--force: skip the stack-match gate;
                                                     --trigger: add the behavioral trigger-accuracy
                                                     dimension — one keyless LLM call per fixture)
      faber refine [--rank N] [--strategy reflect|regenerate] [--iterations N] [--patience N]
                   [--target F] [--min-improvement F] [--trigger] [--trigger-samples N]
                   [--holdout] [--install] [--force] [--source S] [--format F] [--db PATH]
                   [--base DIR] [--min-messages N]
                                                    Self-improve a skill: propose → eval → keep
                                                    the best, looping (default: 5 reflective
                                                    iterations, keyless via claude -p).
                                                    (--trigger: also optimize routing recall,
                                                     scored on the seed's pinned fixtures;
                                                     --holdout: report a held-out validation
                                                     score; --install: install the final best)
      faber consolidate [--top N] [--cluster-threshold F] [--trigger] [--force] [--source S]
                        [--format F] [--db PATH] [--base DIR] [--min-messages N]
                                                    Draft skills for the top-N friction sessions
                                                    (default 5), cluster near-duplicates (token
                                                    Jaccard, threshold 0.3), and LLM-merge each
                                                    cluster — a merge must pass the eval gate or
                                                    the originals are kept
      faber feedback [--dir PATH] [--source S] [--format F] [--db PATH] [--base DIR]
                     [--min-messages N]             The outer loop: for every Faber-installed
                                                    skill, report whether sessions since install
                                                    actually used it and how friction compares —
                                                    verdicts flag skills to refine or retire
      faber serve [--port P] [--no-open]            Start the dashboard UI in your browser
                                                    (also serves the read-only MCP server at /mcp)
      faber sync [--target claude,codex] [--check] [--force] [--dir PATH]
                                                    Register installed skills in each agent's
                                                    context file (managed block; --check: report
                                                    drift only, no write)
      faber help | --version

    Sources (--source): files (default) walks the agent's transcript dir; ccrider reads ccrider's
    SQLite index (--db, default ~/.config/ccrider/sessions.db). Or set config :faber, :ingest_source.

    Formats (--format): claude (default), codex, cline, gemini, opencode — each reads that agent's
    own transcript location. The non-Claude formats are files-only (ccrider indexes Claude content);
    opencode reads its SQLite store via the sqlite3 CLI.
    """
  end
end
