defmodule Faber.CLI do
  @moduledoc """
  Command-line entry point for the single-binary distribution.

  When Faber runs as a Burrito release the binary's argv selects a subcommand; `command/0` parses
  it (and returns `nil` in dev/test/iex so `mix phx.server` and the LiveView tests behave exactly
  as before — the web endpoint still starts). `Faber.Application` calls `command/0` at boot, starts
  the web endpoint only for `serve` (so `faber scan` never binds a port), then `dispatch/1` runs the
  command: one-shot commands print and `System.halt/1`; `serve` prints the URL, opens the browser,
  and leaves the BEAM running.

  Subcommands: `scan`, `propose [--rank N | --top N] [--cluster-threshold F] [--install]
  [--trigger] [--dry-run]`, `refine`, `proposals`, `show`, `install`, `feedback`,
  `serve [--port P] [--no-open]`, `sync`, `help`, `--version`. `consolidate` is a deprecated alias
  for `propose --top N`.
  """

  alias Faber.{Adapter, Consolidate, Eval, Install, Loop, Proposal, Propose, Scan}
  alias Faber.CLI.JSON
  alias Faber.CLI.Render
  alias Faber.Detect.Hazard
  alias Faber.Ingest.Format
  alias Faber.Proposal.Store
  alias Faber.Scan.Scope

  @default_port 4710

  # How many proposals `faber proposals --prune` keeps by default. Generous on purpose: these are
  # paid artifacts on the user's own disk (a few KB each), so an over-large store is a far smaller
  # problem than pruning something someone wanted back.
  @default_keep 50

  # What a bare `consolidate` used to draft. Only the deprecated alias needs a default: `propose`
  # has no implicit `--top`, because guessing a batch size on a command whose unit of work costs an
  # LLM call each is not a default anyone should get by accident.
  @default_top 5

  @typedoc "A subcommand name, or `nil` for top-level (`faber --help`)."
  @type subcommand :: atom() | nil

  @typedoc """
  A parsed command: `{name, opts}` for something runnable, plus two outcomes that deliberately
  run **nothing** — `{:help, subcommand}` and `{:parse_error, subcommand, invalid_switches}`.

  Those two are *data*, not printed here, because `parse/1` is pure: rendering usage and picking
  an exit status belong to `run/2`. That separation is the fix for a real bug — every clause used
  to discard `OptionParser`'s invalid list (`{opts, _, _}`), so `faber propose --help` parsed to a
  perfectly valid `{:propose, []}` and spent a minute on a real LLM call.
  """
  @type command ::
          {:help, subcommand()}
          | {:parse_error, subcommand(), [String.t()]}
          | {:conflicting_opts, subcommand(), [String.t()]}
          | {:missing_id, subcommand()}
          | {:extra_args, subcommand(), [String.t()]}
          | {atom(), keyword()}

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

  @doc """
  Pure argv → `command()` parser (no I/O), so it's unit-testable.

  An unknown or malformed switch never yields a runnable command: it becomes `{:parse_error, ...}`,
  and `--help`/`-h` anywhere in a subcommand's args becomes `{:help, subcommand}`. Both are
  rendered by `run/2`.
  """
  @spec parse([String.t()]) :: command()
  def parse([]), do: {:help, nil}
  def parse([h | _]) when h in ["help", "--help", "-h"], do: {:help, nil}
  def parse([v | _]) when v in ["--version", "-V"], do: {:version, []}

  def parse(["scan" | rest]) do
    parse_sub(:scan, rest,
      limit: :integer,
      rank_by: :string,
      source: :string,
      db: :string,
      format: :string,
      base: :string,
      all: :boolean,
      json: :boolean,
      min_messages: :integer
    )
  end

  def parse(["propose" | rest]) do
    :propose
    |> parse_sub(rest,
      rank: :integer,
      top: :integer,
      hazard: :string,
      cluster_threshold: :float,
      install: :boolean,
      force: :boolean,
      trigger: :boolean,
      dry_run: :boolean,
      source: :string,
      db: :string,
      format: :string,
      limit: :integer,
      base: :string,
      all: :boolean,
      min_messages: :integer
    )
    |> reject_conflict([:rank, :top])
    # `--rank N` and `--top N` both select by the friction ranking; `--hazard` selects by a hazard
    # class, which is orthogonal to that ranking by construction — a session carrying a hazard may
    # rank last, or not place at all. So each pairing asks two different questions at once, and
    # honouring one silently would make the other vanish without a word.
    |> reject_conflict([:hazard, :top])
    |> reject_conflict([:hazard, :rank])
  end

  def parse(["refine" | rest]) do
    parse_sub(:refine, rest,
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
      all: :boolean,
      min_messages: :integer
    )
  end

  def parse(["consolidate" | rest]) do
    parse_sub(:consolidate, rest,
      top: :integer,
      cluster_threshold: :float,
      trigger: :boolean,
      dry_run: :boolean,
      force: :boolean,
      source: :string,
      db: :string,
      format: :string,
      limit: :integer,
      base: :string,
      all: :boolean,
      min_messages: :integer
    )
  end

  def parse(["proposals" | rest]) do
    parse_sub(:proposals, rest, prune: :boolean, keep: :integer, dir: :string, json: :boolean)
  end

  # `show`/`install` take a positional id, which `parse_sub/3` discards along with every other
  # non-switch arg. Pull it out of OptionParser's remaining-args list and carry it in the opts, so
  # `parse/1` still returns pure data and `run/2` still does all the I/O.
  def parse(["show" | rest]), do: parse_with_id(:show, rest, json: :boolean)

  def parse(["install" | rest]) do
    parse_with_id(:install, rest, force: :boolean, dir: :string)
  end

  def parse(["feedback" | rest]) do
    parse_sub(:feedback, rest,
      dir: :string,
      source: :string,
      db: :string,
      format: :string,
      limit: :integer,
      base: :string,
      all: :boolean,
      json: :boolean,
      min_messages: :integer
    )
  end

  def parse(["serve" | rest]), do: parse_sub(:serve, rest, port: :integer, open: :boolean)

  def parse(["sync" | rest]) do
    parse_sub(:sync, rest,
      target: :string,
      check: :boolean,
      force: :boolean,
      dir: :string,
      file: :string
    )
  end

  def parse([other | _]), do: {:unknown, arg: other}

  # Switches every subcommand takes, so a script can pass them uniformly without first knowing which
  # commands care. `--quiet` silences status lines; on a command that emits none it is simply inert,
  # which is the point — a global flag that errors on half the commands is not global.
  @global_switches [quiet: :boolean]

  # One strict parse for every subcommand. `OptionParser`'s third element lists switches it could
  # not accept; honoring it is the whole point — discarding it is what let `--help` run a propose.
  defp parse_sub(subcommand, argv, strict) do
    if help?(argv) do
      {:help, subcommand}
    else
      case OptionParser.parse(argv, strict: strict ++ @global_switches) do
        {opts, _argv, []} -> {subcommand, opts}
        {_opts, _argv, invalid} -> {:parse_error, subcommand, Enum.map(invalid, &elem(&1, 0))}
      end
    end
  end

  # Like parse_sub/3, but for the two commands that take a positional id. A missing id is
  # `{:missing_id, sub}` rather than a runnable command with `id: nil` — same reason parse_sub/3
  # honors OptionParser's invalid list: a command that can't know what it was asked to do must not
  # run. A SECOND positional is an error too; silently ignoring it would make `faber install a b`
  # quietly install only `a`.
  defp parse_with_id(subcommand, argv, strict) do
    if help?(argv) do
      {:help, subcommand}
    else
      case OptionParser.parse(argv, strict: strict ++ @global_switches) do
        {opts, [id], []} -> {subcommand, Keyword.put(opts, :id, id)}
        {_opts, [], []} -> {:missing_id, subcommand}
        {_opts, [_ | _] = extra, []} -> {:extra_args, subcommand, extra}
        {_opts, _argv, invalid} -> {:parse_error, subcommand, Enum.map(invalid, &elem(&1, 0))}
      end
    end
  end

  # Two flags that each answer "which sessions?" differently can't both be honored, and picking one
  # silently is how `--rank 3 --top 5` quietly drafts five skills for sessions you didn't name. Same
  # principle as honoring OptionParser's invalid list: a command that can't know what it was asked to
  # do must not run. Stays pure — the outcome is data, rendered by run/2.
  defp reject_conflict({sub, opts} = cmd, keys) when is_list(opts) do
    case Enum.filter(keys, &Keyword.has_key?(opts, &1)) do
      [_, _ | _] = conflicting -> {:conflicting_opts, sub, Enum.map(conflicting, &switch/1)}
      _ -> cmd
    end
  end

  defp reject_conflict(other, _keys), do: other

  # :cluster_threshold → "--cluster-threshold", mirroring OptionParser's own argv spelling so an
  # error names the flag the user actually typed.
  defp switch(key), do: "--" <> (key |> to_string() |> String.replace("_", "-"))

  # `--help`/`-h` anywhere wins over any other flag, valid or not: someone asking how a command
  # works should get the answer, not a complaint about the flag they were unsure of.
  #
  # A bare `help` only counts as the FIRST token (`faber propose help`, the `git help`-style form).
  # Scanning every token for it — as this once did — misreads an ordinary option *value*: with
  # `faber scan --base help`, `help` is the directory you asked to scan, and printing usage instead
  # is simply wrong. `--help`/`-h` stay position-free because no option here takes them as a value.
  defp help?([first | _] = argv),
    do: first == "help" or Enum.any?(argv, &(&1 in ["--help", "-h"]))

  defp help?([]), do: false

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

  # Normalize the two non-running outcomes into the `{command, opts}` shape `run/2` takes, so they
  # get the same halt-guard and exit-status handling as everything else.
  def dispatch({:parse_error, subcommand, invalid}),
    do: dispatch({:parse_error, [subcommand: subcommand, invalid: invalid]})

  def dispatch({:conflicting_opts, subcommand, flags}),
    do: dispatch({:conflicting_opts, [subcommand: subcommand, flags: flags]})

  def dispatch({:help, subcommand}) when is_atom(subcommand),
    do: dispatch({:help, [subcommand: subcommand]})

  def dispatch({:missing_id, subcommand}) when is_atom(subcommand),
    do: dispatch({:missing_id, [subcommand: subcommand]})

  def dispatch({:extra_args, subcommand, extra}),
    do: dispatch({:extra_args, [subcommand: subcommand, extra: extra]})

  def dispatch({:serve, opts}), do: serve(opts)

  def dispatch({command, opts}) do
    # ALWAYS halt — if run/2 raises, exits, or throws, halt with 1 rather than leaving the
    # release VM hung with no exit path (one-shot commands have no other process keeping the node
    # alive). `catch` is load-bearing, not belt-and-braces: `Faber.Subprocess` re-raises abnormal
    # task exits via `exit/1`, which `rescue` alone lets escape — the process would die with
    # System.halt/1 never reached and the VM hung.
    Task.start(fn ->
      status = guarded(fn -> run(command, opts) end)
      persist()
      System.halt(status)
    end)

    :ok
  end

  @doc false
  # `System.halt/1` is an immediate VM halt: no supervisor shutdown, so the scan cache's
  # `terminate/2` never runs and its 5s debounce never fires. Without this, a one-shot `faber scan`
  # scores the whole corpus and persists none of it — every run cold, forever.
  #
  # Persist even when the command failed: work already cached is still valid, and the next run
  # should not pay for this one's failure. Best-effort by design — a cache that cannot write is a
  # slower next run, never a failed command, and must never keep the VM from reaching its exit.
  @spec persist() :: :ok
  def persist do
    _ = Faber.Scan.Cache.flush()
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
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
  def run(command, opts) do
    put_quiet(opts)
    do_run(command, opts)
  end

  # `--quiet` is ambient, and deliberately not threaded. It has to reach `status/1` from inside
  # progress callbacks several layers down (`Loop.refine`'s `:on_progress`, `Consolidate`'s), and
  # passing a boolean through each of them just to reach an `IO.puts` is a lot of plumbing for a
  # flag that means "don't".
  #
  # The process dictionary is the right ambient store here, specifically:
  #
  #   * it works — neither Loop nor Consolidate spawns for those callbacks, so they run in THIS
  #     process, and `dispatch/1` runs each one-shot command in a single Task;
  #   * unlike an Application env it cannot leak between concurrent tests, which matters because the
  #     suite runs `run/2` directly and mostly async;
  #   * it fails in the safe direction — an unset flag reads false, i.e. print.
  defp put_quiet(opts), do: Process.put(:faber_quiet, opts[:quiet] == true)

  defp quiet?, do: Process.get(:faber_quiet, false) == true

  # `--json` is per-command and only ever read where output is rendered, so unlike `--quiet` it
  # stays an ordinary opt — no ambient state needed.
  defp json?(opts), do: opts[:json] == true

  defp do_run(:help, opts) do
    # `parse/1` has carried the subcommand in `{:help, sub}` all along; this used to ignore it and
    # print the whole manual, so `faber propose --help` buried propose's flags in six other
    # commands' worth of text.
    IO.puts(usage(opts[:subcommand]))
    0
  end

  defp do_run(:version, _opts) do
    IO.puts("faber #{version()}")
    0
  end

  defp do_run(:unknown, opts) do
    IO.puts(:stderr, "faber: unknown command '#{opts[:arg]}'\n")
    IO.puts(usage())
    1
  end

  # The command itself never runs: an unknown flag is a typo, and guessing what someone meant is
  # how `--dry-run` silently becomes a real one. Usage goes to stderr because this is the error
  # path — stdout stays clean for anything piping a successful command's output.
  defp do_run(:parse_error, opts) do
    invalid = opts[:invalid] || []
    subcommand = opts[:subcommand]

    IO.puts(
      :stderr,
      "faber: unrecognized #{pluralize("option", invalid)} for '#{subcommand}': " <>
        "#{Enum.join(invalid, ", ")}\n"
    )

    IO.puts(:stderr, usage())
    1
  end

  defp do_run(:conflicting_opts, opts) do
    flags = opts[:flags] || []
    sub = opts[:subcommand]

    IO.puts(
      :stderr,
      "faber: #{sub} — #{Enum.join(flags, " and ")} cannot be combined; they each answer " <>
        "\"which sessions?\" differently. Use --rank N for one session, --top N for the " <>
        "highest-friction N.\n"
    )

    IO.puts(:stderr, usage(sub))
    1
  end

  defp do_run(:missing_id, opts) do
    sub = opts[:subcommand]

    IO.puts(
      :stderr,
      "faber: #{sub} needs an artifact id — `faber #{sub} <id>`. " <>
        "List what you have with `faber proposals`.\n"
    )

    IO.puts(:stderr, usage(sub))
    1
  end

  defp do_run(:extra_args, opts) do
    sub = opts[:subcommand]

    IO.puts(
      :stderr,
      "faber: #{sub} takes exactly one artifact id, but also got: " <>
        "#{Enum.join(opts[:extra], ", ")}\n"
    )

    IO.puts(:stderr, usage(sub))
    1
  end

  defp do_run(:proposals, opts) do
    if opts[:prune] == true do
      prune_proposals(opts[:keep] || @default_keep)
    else
      list_proposals(opts)
    end
  end

  defp do_run(:show, opts) do
    case resolve_id(opts[:id]) do
      {:ok, record} ->
        IO.puts(if json?(opts), do: JSON.show(record), else: render_show(record))
        0

      {:error, reason} ->
        IO.puts(:stderr, "faber show failed: #{humanize_error(reason)}")
        1
    end
  end

  defp do_run(:install, opts) do
    case resolve_id(opts[:id]) do
      {:ok, record} ->
        install_skill(record.name, record.md, opts)

      {:error, reason} ->
        IO.puts(:stderr, "faber install failed: #{humanize_error(reason)}")
        1
    end
  end

  defp do_run(:scan, opts) do
    scan_opts = opts |> scan_opts() |> put_if(:rank_by, normalize_rank_by(opts[:rank_by]))

    {elapsed_us, results} = :timer.tc(fn -> Scan.run(scan_opts) end)
    ms = div(elapsed_us, 1000)
    scope = scan_opts[:scope]

    # An empty scan stays exit 0 in JSON: "this project has no sessions" is an ANSWER, and a script
    # asking `faber scan --json | jq '.count'` should read 0, not have the pipeline fall over.
    if json?(opts),
      do: IO.puts(JSON.scan(results, ms, scope)),
      else: IO.puts(render_table(results, ms, scope))

    0
  end

  # One verb for "draft me a skill", with the count deciding the shape of the work: `--top N` (N > 1)
  # is the only thing that can produce near-duplicates, so it is the only thing that needs the
  # cluster+merge pipeline. `--top 1` is a plain propose, which is also strictly better than what
  # `consolidate --top 1` used to do — a single session was clustered with nothing, `:kept`, and
  # never eval'd.
  defp do_run(:propose, opts) do
    cond do
      # A hazard is not a friction finding, so it does not select a session the way `--rank` does —
      # see `propose_hazard/2`.
      is_binary(opts[:hazard]) -> propose_hazard(opts, opts[:hazard])
      is_integer(opts[:top]) and opts[:top] > 1 -> propose_batch(opts, opts[:top])
      true -> propose_one(opts)
    end
  end

  # DEPRECATED alias, kept because it is in people's shell history and their scripts. It forwards
  # rather than reimplementing, so the two can never disagree about what consolidating means.
  defp do_run(:consolidate, opts) do
    status(
      "faber: `consolidate` is deprecated — use `faber propose --top N`. Forwarding unchanged."
    )

    do_run(:propose, Keyword.put_new(opts, :top, @default_top))
  end

  defp do_run(:refine, opts) do
    rank = opts[:rank] || 1
    scan_opts = scan_opts(opts)

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
         {:ok, result} <- select_session(Scan.run(scan_opts), rank, scan_opts),
         :ok <- stack_gate(adapter, result, opts[:force]),
         %Loop.State{} = state <- refine_with_status(result, adapter, refine_opts) do
      # A refine is the most expensive thing here — up to `--iterations` real LLM calls to arrive at
      # one skill. Losing that was the same bug as losing a propose, several times over.
      record = store_refinement(state, result, adapter)
      IO.puts(render_refinement(state, adapter) <> render_artifact(record))
      maybe_install_best(state, adapter, opts[:install])
      0
    else
      {:error, {:stack_mismatch, adapter, result}} ->
        IO.puts(:stderr, stack_mismatch_message(adapter, result))
        1

      {:error, reason} ->
        IO.puts(:stderr, "faber refine failed: #{humanize_error(reason)}")
        1
    end
  end

  # `--top N` for N > 1: draft one skill per top-N friction session, cluster the near-duplicates, and
  # LLM-merge each cluster behind the eval gate. Drafting many sessions at once is what MAKES the
  # near-duplicates, which is why the pipeline lives behind the count rather than behind a verb.
  defp do_run(:feedback, opts) do
    reports = opts |> scan_opts([:dir]) |> Faber.Feedback.report()

    cond do
      json?(opts) ->
        IO.puts(JSON.feedback(reports))

      reports == [] ->
        IO.puts("No Faber-installed skills found. Install one with `faber propose --install`.")

      true ->
        IO.puts(render_feedback(reports))
    end

    0
  end

  defp do_run(:sync, opts) do
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

  defp format_sync(agent, :drift),
    do: "#{agent}: #{Render.badge("DRIFT", :warn)} — run `faber sync --target #{agent}`"

  defp format_sync(agent, :absent),
    do: "#{agent}: no Faber block yet — run `faber sync --target #{agent}`"

  defp format_sync(agent, :modified),
    do: "#{agent}: block hand-edited — `faber sync --target #{agent} --force` to overwrite"

  defp format_sync(agent, {:error, :block_modified}),
    do: "#{agent}: block hand-edited — re-run with --force to overwrite"

  # Every other error shape routes through the shared mapping rather than growing a second set of
  # sync-specific sentences (`:block_modified` above keeps its own because it names a sync flag).
  defp format_sync(agent, {:error, reason}), do: "#{agent}: #{humanize_error(reason)}"
  defp format_sync(agent, other), do: "#{agent}: #{inspect(other)}"

  # Passthrough keys every session-reading command shares. `:dir` and `:rank_by` are NOT here:
  # they belong to one command each and are added by it.
  @scan_keys [:limit, :base, :min_messages, :db]

  # Every command that reads sessions builds its scan the same way — including the scope resolution
  # that makes them all mean "this project" by default — so it happens here once rather than in five
  # near-identical blocks that could drift apart on which flag they honor.
  defp scan_opts(opts, extra \\ []) do
    resolved =
      opts
      |> Keyword.take(@scan_keys ++ extra)
      |> put_if(:source, normalize_source(opts[:source]))
      |> put_if(:format, normalize_format(opts[:format]))

    # Resolved from the NORMALIZED opts, not the raw ones: the scope has to ask the format module
    # where transcripts live, and `Format.resolve/1` raises on the `--format` *string* argv carries.
    scope = Scope.resolve(Keyword.put(resolved, :all, opts[:all] == true))
    Keyword.put(resolved, :scope, scope)
  end

  # Two failures that used to render identically as "no session at rank 1": an EMPTY corpus (faber
  # found nothing at all — almost always the wrong root, and the user's actual first-run experience)
  # and a rank past the end of a real corpus. Only the second one is about the rank, and telling a
  # first-time user their rank is wrong sends them to fix the one thing that isn't.
  defp select_session([], _rank, scan_opts), do: {:error, {:no_sessions, scan_root(scan_opts)}}

  defp select_session(results, rank, _scan_opts) do
    case Enum.at(results, rank - 1) do
      %Scan.Result{} = result -> {:ok, result}
      nil -> {:error, {:rank_out_of_range, rank, length(results)}}
    end
  end

  # The root actually searched, so the message can name a directory rather than a flag. Resolved
  # through the format registry (not a literal) — `--base` overrides, else it's the format's own
  # default_base/0, which is the whole point of the message when the two disagree.
  defp scan_root(scan_opts) do
    scan_opts[:base] || Format.resolve(scan_opts).default_base()
  end

  # The single stack-match decision, including what `--force` means. propose/refine *gate* on it
  # (one session — a mismatch is a refusal); consolidate *partitions* on it (a batch — a mismatch is
  # a skip). Different consequences, but they must never disagree about the question itself, which
  # they did while consolidate asked it inline (audit item 9).
  #
  # The decision itself lives in `Faber.Propose` — the CLI is one selection site among several
  # (the dashboard is another), and a gate each caller re-implements is a gate the next caller
  # forgets.
  #
  # `!!force` is for the type, not the behaviour: `opts[:force]` is `true | nil` (OptionParser's
  # `:boolean` omits absent switches), and `stack_match?/3` already treats nil as falsy by falling
  # through to its catch-all clause. The coercion is what satisfies the `boolean()` spec.
  defp stack_match?(adapter, result, force), do: Propose.stack_match?(adapter, result, !!force)

  defp stack_gate(adapter, result, force), do: Propose.stack_gate(adapter, result, !!force)

  # ── propose ─────────────────────────────────────────────────────────────────

  defp propose_one(opts) do
    rank = opts[:rank] || 1

    # Score all sessions so `--rank N` selects from the TRUE friction ranking (a `:limit` here
    # would sample a subset and could miss the worst sessions). `--limit` still passes through.
    scan_opts = scan_opts(opts)

    # `--trigger` opts into the behavioral trigger-accuracy dimension (one keyless LLM call per
    # fixture). Off by default. In the loop (`Faber.Loop.refine/3` with `trigger: true`) the same
    # dimension is safe to optimize only because candidates are scored against the SEED's fixtures,
    # pinned — a candidate can't game the objective by rewriting its own exam (see
    # .claude/research/2026-06-26-behavioral-eval-trigger-accuracy.md and the Loop moduledoc).
    trigger? = opts[:trigger] == true

    with {:ok, adapter} <- Adapter.load(Faber.adapter_dir()),
         {:ok, result} <- select_session(Scan.run(scan_opts), rank, scan_opts),
         :ok <- stack_gate(adapter, result, opts[:force]),
         :ok <- dry_run_gate(opts, [result], adapter, propose_cost(trigger?)),
         {:ok, proposal} <- propose_with_status(result, adapter),
         {:ok, eval} <- Eval.score(proposal, adapter: adapter, trigger: trigger?) do
      # Filed before it is printed, not after: the print is what the user sees, the file is what
      # they keep.
      record = store_artifact(result, proposal, eval, adapter, :single)
      IO.puts(render_proposal(proposal, eval, adapter) <> render_artifact(record))
      maybe_install(proposal, adapter, opts[:install])
      0
    else
      {:dry_run, report} ->
        IO.puts(report)
        0

      {:error, {:stack_mismatch, adapter, result}} ->
        IO.puts(:stderr, stack_mismatch_message(adapter, result))
        1

      {:error, reason} ->
        IO.puts(:stderr, "faber propose failed: #{humanize_error(reason)}")
        1
    end
  end

  # `faber propose --hazard <kind>` — draft a HOOK for a frictionless hazard.
  #
  # Selection is by hazard class alone, which is why `--rank`/`--top` are refused rather than
  # combined: a hazard is what a session *risked*, not how hard it was, and the class this detects
  # produces no friction at all — so the session carrying it may rank last, or not place at all.
  # Ranking by friction and then looking for a hazard there would find nothing most of the time.
  # Instead: scan, then take the first session that HAS this hazard.
  defp propose_hazard(opts, kind) do
    scan_opts = scan_opts(opts)

    with {:ok, adapter} <- Adapter.load(Faber.adapter_dir()),
         {:ok, result, hazard} <- select_hazard(Scan.run(scan_opts), kind),
         :ok <- stack_gate(adapter, result, opts[:force]),
         :ok <- dry_run_gate(opts, [result], adapter, propose_cost(false)),
         {:ok, proposal} <- propose_hook_with_status(result, hazard, adapter),
         {:ok, eval} <- Eval.score(proposal, adapter: adapter) do
      record = store_artifact(result, proposal, eval, adapter, :single)
      IO.puts(render_proposal(proposal, eval, adapter) <> render_artifact(record))
      maybe_install_hook(proposal, adapter, opts[:install], opts[:force])
      0
    else
      {:dry_run, report} ->
        IO.puts(report)
        0

      {:error, {:no_such_hazard, kind}} ->
        IO.puts(
          :stderr,
          "faber propose: no session in this scan carries a `#{kind}` hazard.\n" <>
            "Known hazard classes: #{Enum.map_join(Hazard.known_kinds(), ", ", &to_string/1)}.\n" <>
            "Faber detects ONE class of frictionless hazard today — a clean scan here means that " <>
            "class wasn't found, not that the sessions are hazard-free."
        )

        1

      {:error, {:stack_mismatch, adapter, result}} ->
        IO.puts(:stderr, stack_mismatch_message(adapter, result))
        1

      {:error, reason} ->
        IO.puts(:stderr, "faber propose --hazard failed: #{humanize_error(reason)}")
        1
    end
  end

  # First session carrying `kind`, with the hazard summary that seeds the prompt. An unknown kind is
  # reported as "not found" like any other — `known_kinds/0` is in the message, so a typo and a
  # genuinely absent hazard are distinguishable by reading it.
  defp select_hazard(results, kind) do
    Enum.find_value(results, {:error, {:no_such_hazard, kind}}, fn result ->
      case Enum.find(result.hazards, &(to_string(&1.kind) == kind)) do
        nil -> nil
        hazard -> {:ok, result, hazard}
      end
    end)
  end

  defp propose_hook_with_status(result, hazard, adapter) do
    status("Proposing a hook for #{hazard.kind} (#{hazard.count}×) via #{impl_label()}…")
    Propose.propose_hook(result, hazard, adapter)
  end

  defp maybe_install_hook(_proposal, _adapter, install, _force) when install in [nil, false],
    do: :ok

  defp maybe_install_hook(proposal, adapter, true, force) do
    opts = [adapter: adapter] ++ if(force, do: [force: true], else: [])

    case Install.Hook.install(proposal, opts) do
      {:ok, %{script: script, settings: settings}} ->
        IO.puts("installed → #{script}\npointed at it → #{settings}")
        0

      # Same refusal, same words, as every other surface: a safety veto is not an overwrite
      # conflict, and `--force` must not read like the fix for it.
      {:error, {:vetoed, vetoes}} ->
        IO.puts(
          :stderr,
          "REFUSED — #{proposal.name} was not installed:\n" <>
            Enum.map_join(vetoes, "\n", &"  #{&1.check_type}: #{&1.evidence}") <>
            "\n\nThis is a safety refusal, not a score. `--force` overrides an existing install, " <>
            "never this."
        )

        1

      {:error, {:hand_edited, command}} ->
        IO.puts(
          :stderr,
          "faber: this hook's pointer in settings.json has been hand-edited since Faber wrote it:\n" <>
            "  #{command}\n" <>
            "Re-run with --force to replace it, or keep your edit and skip the install."
        )

        1

      {:error, reason} ->
        IO.puts(:stderr, "faber: hook install failed: #{humanize_error(reason)}")
        1
    end
  end

  defp propose_batch(opts, top) do
    scan_opts = scan_opts(opts)

    # `:threshold` here is Consolidate's CLUSTER threshold (token-Jaccard); the eval gate keeps
    # its own configured bar. `--trigger` forwards to the gate like `propose --trigger`.
    consolidate_opts =
      []
      |> put_if(:threshold, opts[:cluster_threshold])
      |> put_if(:trigger, opts[:trigger])

    with {:ok, adapter} <- Adapter.load(Faber.adapter_dir()),
         {:ok, sessions} <- consolidate_sessions(Scan.run(scan_opts), scan_opts, top) do
      {candidates, skipped} = Enum.split_with(sessions, &stack_match?(adapter, &1, opts[:force]))
      report_skipped(skipped)

      case dry_run_gate(opts, candidates, adapter, consolidate_cost(candidates)) do
        {:dry_run, report} ->
          IO.puts(report)
          0

        :ok ->
          consolidate_proposals(candidates, adapter, consolidate_opts, top)
      end
    else
      {:error, reason} ->
        IO.puts(:stderr, "faber propose failed: #{humanize_error(reason)}")
        1
    end
  end

  # ── dry run ────────────────────────────────────────────────────────────────

  # `--dry-run` is a GATE, deliberately sitting at the exact seam between the last free step (scan,
  # adapter load, stack match) and the first paid one (the `claude -p` draft). Everything it reports
  # is therefore the decision the real run would make, read off the same values — not a second
  # derivation that could quietly disagree with it. The CLI's answer to the dashboard's confirm(),
  # without a stdin prompt the fire-and-forget architecture has nowhere to put.
  defp dry_run_gate(opts, sessions, adapter, cost) do
    if opts[:dry_run] == true,
      do: {:dry_run, render_dry_run(sessions, adapter, cost)},
      else: :ok
  end

  defp render_dry_run(sessions, adapter, cost) do
    rows =
      sessions
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {r, i} ->
        "    #{i}. #{session(r)}  (#{r.fingerprint}, raw #{Render.raw_score(r.raw)})"
      end)

    """
    DRY RUN — nothing was drafted, nothing was filed, no LLM calls were spent.

      #{pluralize("session", sessions)} to draft (#{length(sessions)}):
    #{rows}
      adapter:   #{adapter.name}
      eval:      #{Eval.planned_engine(adapter: adapter)}
      backend:   #{impl_label()}
      LLM calls: #{cost}

    Re-run without --dry-run to spend it.\
    """
  end

  # One call drafts the skill. `--trigger` then scores routing with one call per fixture — and the
  # fixtures live IN the skill that hasn't been drafted yet, so the total is genuinely unknowable
  # here. Say that, rather than printing a confident number that a --trigger run would then exceed.
  defp propose_cost(false), do: "1 (the draft)"

  defp propose_cost(true),
    do:
      "1 (the draft) + one per fixture in it for --trigger (fixture count isn't known until drafted)"

  defp consolidate_cost(candidates) do
    "#{length(candidates)} (one draft each) + one per merged cluster " <>
      "(clusters aren't known until the drafts exist)"
  end

  defp stack_mismatch_message(adapter, result) do
    exts =
      result
      |> Propose.touched_extensions()
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

  defp pluralize(word, [_one]), do: word
  defp pluralize(word, _many), do: word <> "s"

  # ── errors ─────────────────────────────────────────────────────────────────

  @doc false
  # Render the error shapes the pipeline actually returns as the sentences docs/GUIDE.md §21 already
  # explains them with. A bare `{:claude_cli_unavailable, "claude"}` on someone's terminal is a
  # support question waiting to happen: the fix is one PATH export, and the tuple conveys that only
  # to a reader with the source open. Public (with @doc false) so the mapping is unit-testable, the
  # same reason `guarded/1` is.
  #
  # Unknown shapes still fall through to `inspect/1`. That fallback is the point: inventing a
  # friendly sentence for an error we haven't actually seen would trade an honest dump for a
  # confident guess, and a wrong explanation costs more debugging time than a raw tuple.
  @spec humanize_error(term()) :: String.t()
  def humanize_error(:not_found),
    do: "no proposal with that id. List what you have with `faber proposals`."

  def humanize_error(:missing_id),
    do: "an artifact id is required. List what you have with `faber proposals`."

  # Show the candidates rather than making the user re-run `proposals` and eyeball it: ids share a
  # session prefix, so this is the *expected* outcome of a short prefix, not a rare mistake.
  def humanize_error({:ambiguous, candidates}) do
    lines = Enum.map_join(candidates, "\n", fn r -> "  #{r.id}  #{r.name}" end)

    "that prefix matches #{length(candidates)} proposals:\n#{lines}\nUse more of the id."
  end

  def humanize_error({:no_sessions, root}),
    do: "no sessions found under #{root}. Three things usually cause this:\n" <> scan_causes()

  def humanize_error({:rank_out_of_range, rank, 1}),
    do: "no session at rank #{rank} — only 1 session matched."

  def humanize_error({:rank_out_of_range, rank, n}),
    do: "no session at rank #{rank} — only #{n} sessions matched."

  def humanize_error({:claude_cli_unavailable, bin}) when is_binary(bin),
    do:
      "the `#{bin}` CLI isn't on PATH. Install Claude Code, or point faber at it with " <>
        "`config :faber, :claude_bin, \"/path/to/claude\"`."

  def humanize_error({:claude_cli_unavailable, reason}),
    do:
      "could not start the `claude` CLI (#{inspect(reason)}). Is Claude Code installed and on " <>
        "PATH?"

  def humanize_error({:claude_cli_timeout, ms}),
    do:
      "the `claude` CLI didn't answer within #{ms}ms and was killed. Re-run, or raise " <>
        "`config :faber, :claude_timeout_ms`."

  def humanize_error({:claude_cli_exit, code, out}),
    do: "the `claude` CLI exited #{code}: #{first_line(out)}"

  def humanize_error({:claude_cli_parse, out}),
    do: "the `claude` CLI returned something faber could not read as JSON: #{first_line(out)}"

  def humanize_error({:exists, path}),
    do:
      "a skill is already installed at #{path}. Overwrite it with --force, or `faber refine` the " <>
        "installed one instead."

  def humanize_error({:invalid_name, name}),
    do: "#{inspect(name)} is not a usable skill name (letters, digits and dashes only)."

  def humanize_error({:invalid_adapter, reasons}) when is_list(reasons),
    do: "the adapter is invalid:\n" <> Enum.map_join(reasons, "\n", &"  - #{&1}")

  def humanize_error({:yaml_error, path, reason}),
    do: "#{path} is not valid YAML: #{inspect(reason)}"

  def humanize_error({:not_a_mapping, path, _other}),
    do: "#{path} must be a YAML mapping (`key: value`), not a list or a scalar."

  # Known agents come from Install's registry rather than a second list here, which would drift the
  # first time an agent is added (same reason normalize_format/1 defers to the format registry).
  def humanize_error({:unknown_agent, agent}),
    do:
      "unknown agent #{inspect(agent)} — known: " <>
        (Install.agent_context_files() |> Map.keys() |> Enum.sort() |> Enum.join(", ")) <> "."

  def humanize_error(:insufficient_fixtures_for_holdout),
    do:
      "--holdout needs at least 2 should_trigger AND 2 should_not_trigger fixtures to split them. " <>
        "Re-propose (the proposer normally emits 2+2), or drop --holdout."

  # The adapter's exec-in-place scorer: an adapter/machine problem, so point at the adapter's own
  # config rather than at faber.
  def humanize_error({:exec_in_place_timeout, ms}),
    do: "the adapter's eval scorer did not finish within #{ms}ms."

  def humanize_error({:exec_in_place_unavailable, reason}),
    do: "could not run the adapter's eval scorer (#{inspect(reason)}). Check `eval/eval.yaml`."

  def humanize_error({:exec_in_place_exit, code, out}),
    do: "the adapter's eval scorer exited #{code}: #{first_line(out)}"

  def humanize_error({:exec_in_place_root_missing, root}),
    do: "the adapter's eval root #{root} does not exist on this machine."

  def humanize_error(other), do: inspect(other)

  defp first_line(out) when is_binary(out) do
    out
    |> String.split("\n", trim: true)
    |> List.first("(no output)")
    |> String.slice(0, 200)
  end

  defp first_line(other), do: inspect(other)

  # The causes of an empty corpus, written once. `scan` renders them under its own table and
  # propose/refine render them via humanize_error/1 — the same user, the same wrong root, and
  # previously two different (or absent) explanations.
  #
  # propose/refine have no scope to hand over here, so they get the unscoped list. That is the
  # honest default rather than a shortcut: their `:no_sessions` error carries the root they
  # searched, which is the `--base`/`--format` story these lines tell.
  defp scan_causes, do: causes_block(nil)

  defp causes_block(scope), do: Enum.map_join(empty_causes(scope), "\n", &("  - " <> &1)) <> "\n"

  # ── status ─────────────────────────────────────────────────────────────────

  # Progress lines go to stderr, never stdout. A propose is one `claude -p` call — a minute of
  # total silence in which a run and a hang look identical. stderr because these are diagnostics,
  # not results: stdout stays a clean data stream for anything piping a command's output.
  @spec status(iodata()) :: :ok
  defp status(line) do
    if quiet?(), do: :ok, else: IO.puts(:stderr, line)
  end

  # The short backend name (`ClaudeCLI`) rather than `inspect/1`'s fully-qualified `Faber.LLM.
  # ClaudeCLI` — the module prefix is noise in a status line. String-split rather than
  # `Module.split/1`, which raises for a non-Elixir module.
  defp impl_label, do: Faber.LLM.impl() |> inspect() |> String.split(".") |> List.last()

  defp signal_label(%Scan.Result{dominant_signal: nil}), do: Render.none()
  defp signal_label(%Scan.Result{dominant_signal: s}), do: to_string(s)

  # Mirrors the dev mix task's pre-flight line (lib/mix/tasks/faber.propose.ex), which the release
  # CLI never had — the one surface where a user is most likely to be waiting on a cold LLM call.
  defp propose_with_status(result, adapter) do
    status(
      "Proposing for #{result.fingerprint} session (raw #{Render.raw_score(result.raw)}, " <>
        "dominant #{signal_label(result)}) via #{impl_label()}…"
    )

    Propose.propose(result, adapter)
  end

  defp refine_with_status(result, adapter, refine_opts) do
    max = refine_opts[:max_iterations]

    status(
      "Refining #{result.fingerprint} session (raw #{Render.raw_score(result.raw)}, " <>
        "dominant #{signal_label(result)}) via #{impl_label()} — up to " <>
        "#{max} #{refine_opts[:strategy]} iterations…"
    )

    # `max` is closed over rather than carried in the entry: the loop reports what happened, and the
    # bound is the caller's own opt — it has no business round-tripping through the journal.
    on_progress = fn entry -> status(refine_progress_line(entry, max)) end

    Loop.refine(result, adapter, Keyword.put(refine_opts, :on_progress, on_progress))
  end

  defp refine_progress_line(entry, max) do
    verdict = if entry.kept, do: "KEEP", else: "discard"

    note =
      case entry.reason do
        nil -> ""
        reason -> " (#{reason})"
      end

    "  iteration #{entry.iteration}/#{max}: composite #{Render.score(entry.new_composite)} #{verdict}#{note}"
  end

  defp consolidate_progress({:merging, %{index: i, total: n, members: members}}),
    do: status("merging cluster #{i}/#{n} — #{names(members)}…")

  # ── rendering ──────────────────────────────────────────────────────────────

  # One spec drives both the header and every row. A hand-aligned header string drifts from the pads
  # it labels the first time a column moves — and this table just gained four.
  #
  # `events` is the transcript line count (what the old `msgs` column actually showed); `turns` is
  # what a person typed. Showing only the former overstated human involvement by 20-70x.
  @scan_columns [
    {"#", 3, :right},
    {"friction(raw)", 13, :right},
    {"fingerprint", 12, :left},
    {"signal", 18, :left},
    {"events", 7, :right},
    {"turns", 6, :right},
    {"tools", 6, :right},
    {"errs", 5, :right},
    {"ctx", 5, :right},
    {"opp", 5, :right},
    {"t2", 3, :right}
  ]

  @scan_legend "friction(raw) = raw weighted friction (the rank metric); opp = missed-automation " <>
                 "score; ctx = peak context used; t2 = tier-2 eligible."

  # Everything the row spends before `session`, which is last and variable-width: the padded cells,
  # their separators, and the two-space gutter. Computed from the spec so adding a column can't
  # leave a stale literal behind.
  @scan_gutter Enum.sum(Enum.map(@scan_columns, fn {_l, w, _a} -> w end)) +
                 length(@scan_columns) - 1 + 2

  # A floor, because the arithmetic goes negative on a narrow terminal (the fixed columns alone
  # exceed 80). A clipped-but-present session label beats a column that vanishes.
  @min_session_width 12

  # An empty scan is the single most common first-run outcome, and "No sessions matched." told the
  # user nothing they could act on. The three causes are GUIDE §21's, and the format list comes from
  # the ingest registry so it can't drift behind a newly-added agent.
  defp render_table([], ms, scope),
    do:
      "#{Render.scope_line(scope)}\nNo sessions matched (scanned in #{ms}ms). " <>
        "Usually one of these:\n" <> causes_block(scope)

  defp render_table(results, ms, scope) do
    # Resolved once per table, not once per row: :io.columns/0 is a syscall, and a width that
    # changed mid-table would misalign it anyway.
    session_w = session_width()

    rows =
      results
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {r, i} -> scan_row(r, i, session_w) end)

    "#{Render.scope_line(scope)}\n#{scan_summary(results, ms, scope)}\n\n" <>
      "#{scan_header()}\n#{rows}\n\n#{@scan_legend}"
  end

  # `--min-messages` leads for a scoped scan and `--base`/`--format` lead for a global one, because
  # they are what actually went wrong in each case: inside a project whose directory we FOUND, the
  # root is provably right and only the filter can be hiding everything.
  defp empty_causes(%Scope{kind: :project}) do
    [
      "--min-messages is filtering every session out — try --min-messages 0",
      "this project's sessions are all shorter than the filter — `--all` ranks every project"
    ]
  end

  defp empty_causes(_scope) do
    formats = Format.known() |> Enum.map_join(", ", &to_string/1)

    [
      "--min-messages is filtering every session out — try --min-messages 0",
      "--base points at the wrong transcript root (docs/GUIDE.md §13 lists each format's default)",
      "--format doesn't match the agent whose sessions you want (known: #{formats})"
    ]
  end

  defp scan_header do
    @scan_columns
    |> Enum.map_join(" ", fn {label, w, align} -> pad_cell(label, w, align) end)
    |> Kernel.<>("  session")
  end

  defp scan_row(r, i, session_w) do
    values = [
      to_string(i),
      Render.raw_score(r.raw),
      to_string(r.fingerprint),
      signal_label(r),
      to_string(r.message_count),
      to_string(r.human_turns),
      to_string(r.tool_count),
      to_string(r.error_count),
      ctx_label(r.max_ctx_pct),
      Render.friction(r.opportunity),
      if(r.tier2, do: "✓", else: "")
    ]

    @scan_columns
    |> Enum.zip(values)
    |> Enum.map_join(" ", fn {{_label, w, align}, v} -> pad_cell(v, w, align) end)
    |> Kernel.<>("  " <> truncate(session(r), session_w))
  end

  # "across M projects" is dropped for a scoped scan: M is 1 by construction there, so printing it
  # would be padding a line whose whole job is to be scannable.
  defp scan_summary(results, ms, %Scope{kind: :project}),
    do: "#{length(results)} #{pluralize("session", results)} in #{ms}ms"

  defp scan_summary(results, ms, _scope) do
    projects =
      results |> Enum.map(&project_label(&1, &1.path)) |> Enum.uniq() |> length()

    "#{length(results)} #{pluralize("session", results)} across #{projects} " <>
      "#{if(projects == 1, do: "project", else: "projects")} in #{ms}ms"
  end

  defp pad_cell(s, w, :right), do: String.pad_leading(s, w)
  defp pad_cell(s, w, :left), do: String.pad_trailing(s, w)

  # `:io.columns/0` answers `{:error, :enotsup}` for a non-tty — piped to `head`, redirected to a
  # file, running in CI. That is not "assume 80": it means there is no width to fit, and clipping
  # would corrupt the output for the one consumer that can actually use the full name. So the cap
  # lifts entirely instead. Truncation exists to stop a terminal from WRAPPING a row; a pipe does
  # not wrap. (80 stays the floor for a tty that reports an unusably narrow width.)
  defp session_width do
    case :io.columns() do
      {:ok, cols} -> max(cols - @scan_gutter, @min_session_width)
      _ -> :infinity
    end
  end

  # Clip to `w`, marking the cut with `…`. A truncated name must LOOK truncated: silently dropping
  # the tail of a project path yields a label that reads as real and isn't.
  defp truncate(s, :infinity) when is_binary(s), do: s

  defp truncate(s, w) when is_binary(s) do
    if String.length(s) <= w, do: s, else: String.slice(s, 0, max(w - 1, 0)) <> "…"
  end

  # Mirrors the dashboard's ctx/1 — a session with no context reading is "—", not "0%", which would
  # read as "used no context" rather than "we don't know".
  defp ctx_label(nil), do: Render.none()
  defp ctx_label(pct) when is_number(pct), do: "#{round(pct)}%"

  # `passed: false` used to imply `composite < threshold`, so one message covered every refusal. The
  # safety veto broke that equivalence: a vetoed artifact can sit at 0.83 against a 0.75 threshold
  # and still be refused. Reporting that as "below threshold 0.75" is simply false, and false in the
  # worst place — it hides a SECURITY refusal behind a scoring complaint, and the number it prints
  # invites the reader to go tune the score until it clears.
  defp verdict(%{vetoed: [_ | _] = vetoed}) do
    Render.badge("REFUSED", :bad) <> " — " <> Enum.map_join(vetoed, "; ", & &1.evidence)
  end

  defp verdict(%{passed: true}), do: Render.badge("PASS", :ok)
  defp verdict(eval), do: Render.badge("below threshold #{eval.threshold}", :bad)

  # Kind-neutral (`render/2`): a hook's artifact is its script, and `render_skill_md/2` would raise on
  # one. The header names the kind for anything that isn't a skill, so a wall of shell isn't a
  # surprise — and the threshold shown is the hook gate's 0.90, straight off the eval.
  defp render_proposal(proposal, eval, adapter) do
    label =
      case proposal.kind do
        :skill -> proposal.name
        kind -> "#{proposal.name} (#{kind})"
      end

    """
    #{label} — composite #{Render.score(eval.composite)} (#{verdict(eval)})

    #{Propose.render(proposal, adapter)}
    """
  end

  defp maybe_install(_proposal, _adapter, install) when install in [nil, false], do: :ok

  defp maybe_install(proposal, adapter, true) do
    # `propose --install` and `install <id>` are the same operation on the same bytes — the rendered
    # SKILL.md — so they go through one function. Two paths would mean the diff-first guard applies
    # to one and not the other, which is exactly the kind of drift that makes a blind overwrite
    # possible again.
    _ = install_skill(proposal.name, Propose.render_skill_md(proposal, adapter), [])
    :ok
  end

  # Never a blind overwrite. An existing skill under the same name may be hand-edited, or may be a
  # better version than the one being installed — so the conflict prints what would change and
  # refuses, and the user decides. This is `terraform plan`'s bargain, and the reason `--force`
  # exists rather than being the default.
  defp install_skill(name, md, opts) do
    case Install.install({name, md}, Keyword.take(opts, [:dir, :force])) do
      {:ok, path} ->
        IO.puts("installed → #{path}")
        0

      # Not a scoring complaint and not an overwrite conflict, so it must not read like either —
      # `--force` is the reflex for both of those and it will not help here, by design.
      {:error, {:vetoed, vetoes}} ->
        IO.puts(
          :stderr,
          "REFUSED — #{name} was not installed:\n" <>
            Enum.map_join(vetoes, "\n", &"  #{&1.check_type}: #{&1.evidence}") <>
            "\n\nThis is a safety refusal, not a score. `--force` overrides an existing install, " <>
            "never this."
        )

        1

      {:error, {:exists, path}} ->
        IO.puts(:stderr, render_install_conflict(name, md, path))
        1

      {:error, reason} ->
        IO.puts(:stderr, "faber install failed: #{humanize_error(reason)}")
        1
    end
  end

  defp render_install_conflict(name, md, path) do
    """
    #{name} is already installed at #{path}.
    #{render_drift(path)}
    #{diff_or_identical(path, md)}

    Replace it with --force, or `faber refine` the installed one instead.
    """
  end

  # The diff shows WHAT differs; this says WHOSE change it is, which is the part that decides
  # whether --force is safe. Replacing Faber's own output costs nothing recoverable — replacing
  # someone's hand-edits destroys work that exists nowhere else.
  defp render_drift(path) do
    if Install.drift?(path) do
      "\n#{Render.badge("DRIFT", :warn)} — this skill has been hand-edited since Faber installed it. --force discards\n" <>
        "those edits permanently; they are not in the proposal store.\n"
    else
      ""
    end
  end

  defp diff_or_identical(path, md) do
    case File.read(path) do
      {:ok, ^md} ->
        "The installed skill is byte-identical to this proposal — nothing would change."

      {:ok, installed} ->
        "Installed (-) vs this proposal (+):\n\n#{text_diff(installed, md)}"

      {:error, reason} ->
        "Could not read the installed skill to compare (#{:file.format_error(reason)})."
    end
  end

  # Lines of context kept either side of a change.
  @diff_context 3

  # `List.myers_difference/2` is stdlib — no dep for something this small, per the minimal-deps rule
  # (Owl in P4 is the one dep this plan is allowed, and it isn't a differ).
  defp text_diff(old, new) do
    old
    |> String.split("\n")
    |> List.myers_difference(String.split(new, "\n"))
    |> Enum.flat_map(fn {op, lines} -> Enum.map(lines, &{op, &1}) end)
    |> collapse_unchanged()
    |> Enum.map_join("\n", &diff_line/1)
  end

  # A SKILL.md is mostly unchanged text; printing all of it buries the three lines that differ. Runs
  # of equal lines longer than 2×context collapse to a count.
  defp collapse_unchanged(tagged) do
    tagged
    |> Enum.chunk_by(fn {op, _line} -> op == :eq end)
    |> Enum.flat_map(fn
      [{:eq, _} | _] = run -> collapse_run(run)
      changed -> changed
    end)
  end

  defp collapse_run(run) when length(run) <= 2 * @diff_context + 1, do: run

  defp collapse_run(run) do
    hidden = length(run) - 2 * @diff_context

    Enum.take(run, @diff_context) ++
      [{:skip, "⋯ #{hidden} unchanged #{if hidden == 1, do: "line", else: "lines"}"}] ++
      Enum.take(run, -@diff_context)
  end

  defp diff_line({:eq, line}), do: "  #{line}"
  defp diff_line({:del, line}), do: "- #{line}"
  defp diff_line({:ins, line}), do: "+ #{line}"
  defp diff_line({:skip, note}), do: "  #{note}"

  # ── artifacts ──────────────────────────────────────────────────────────────

  # Every paid outcome reaches disk BEFORE it is printed. This is Phase 2's whole point: a live
  # `consolidate --top 10` spent ~10 LLM calls, produced 4 eval-passing skills (two merges at
  # composite 0.8016), printed a 7-line summary, and lost every byte the moment the process exited.
  # The merges especially — they are drawn from several sessions at once, so no `propose --rank N`
  # can reproduce them; the artifact is the only copy there will ever be.
  #
  # Best-effort, deliberately: `Store.put/2` logs its own failure, and a store that cannot write is
  # a lost artifact, never a failed command. Refusing to print output the user has already paid for
  # because we could not also file it would destroy the very thing this exists to protect.
  defp store_artifact(key_or_result, proposal, eval, adapter, outcome, source_sessions \\ nil) do
    attrs = %{
      name: proposal.name,
      md: Propose.render_skill_md(proposal, adapter),
      eval: eval || %{},
      adapter: adapter.name,
      outcome: outcome,
      source_sessions: source_sessions
    }

    case Store.put(key_or_result, attrs) do
      {:ok, record} -> record
      # `:disabled` is the configured-off store (the test suite), not a failure — say nothing.
      {:error, :disabled} -> nil
      {:error, _reason} -> nil
    end
  end

  # Mirrors `Store`'s own session_key/1 — the session id is the identity, the path the fallback —
  # for the consolidate path, which holds proposals rather than the `%Scan.Result{}` they came from.
  # A merged proposal's source carries `session_ids` (plural, the union of its originals').
  defp proposal_sessions(%Proposal{source: source}) when is_map(source) do
    cond do
      is_list(source[:session_ids]) and source[:session_ids] != [] -> source[:session_ids]
      is_binary(source[:session_id]) -> [source[:session_id]]
      is_binary(source[:path]) -> [source[:path]]
      true -> []
    end
  end

  defp proposal_sessions(_proposal), do: []

  # An artifact whose session is unknown has nowhere to be keyed, so it is not stored — but that is
  # a fact worth saying out loud rather than a silent drop, since the whole promise here is "nothing
  # paid for is lost".
  defp store_proposal(proposal, eval, adapter, outcome) do
    case proposal_sessions(proposal) do
      [] ->
        status("could not file #{proposal.name}: its source session is unknown")
        nil

      [primary | _] = sessions ->
        store_artifact(primary, proposal, eval, adapter, outcome, sessions)
    end
  end

  # The loop tracks its best as a proposal when it has one; a content-only run has no proposal to
  # render a SKILL.md from, so there is nothing to file.
  defp store_refinement(%Loop.State{best_proposal: %Proposal{} = p} = state, result, adapter),
    do: store_artifact(result, p, refinement_eval(state), adapter, :single)

  defp store_refinement(_state, _result, _adapter), do: nil

  # `best_eval` is the full eval map when the eval_fn supplied one (`{:ok, comp, meta}`); otherwise
  # the composite the ratchet kept is genuinely all we know. Record that rather than inventing the
  # rest of the shape.
  defp refinement_eval(%Loop.State{best_eval: eval}) when is_map(eval), do: eval
  defp refinement_eval(%Loop.State{best_composite: c}), do: %{composite: c}

  defp store_outcomes(outcomes, adapter) do
    outcomes
    |> Enum.flat_map(fn
      # A singleton was never merged and never gated, so it has no eval of its own to record.
      {:kept, p} ->
        [store_proposal(p, nil, adapter, :kept)]

      # `eval` here IS the merged skill's score, so it belongs to the merged skill.
      {:merged, merged, eval, _originals} ->
        [store_proposal(merged, eval, adapter, :merged)]

      # ...and here it is NOT. This eval scored the MERGE that failed the gate; the originals are
      # what survived, and attaching the merge's composite to each would claim they scored something
      # they never scored. Their own scores aren't in this outcome, so record none.
      {:kept_originals, originals, _merge_eval} ->
        Enum.map(originals, &store_proposal(&1, nil, adapter, :kept_original))

      # The merge LLM call failed — but each original is still a real draft that cost real tokens,
      # which is exactly the thing not to throw away because a later step broke.
      {:error, originals, _reason} ->
        Enum.map(originals, &store_proposal(&1, nil, adapter, :kept_original))
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp render_artifacts([]), do: ""

  defp render_artifacts(records) do
    lines = Enum.map_join(records, "\n", fn r -> "  #{r.id}  #{r.name}" end)

    "\n\n#{length(records)} #{pluralize("artifact", records)} written to " <>
      "#{Faber.proposals_dir()}:\n#{lines}\n\nInspect one with `faber show <id>`."
  end

  defp render_artifact(nil), do: ""

  # The full id, not an abbreviation. Ids are two 12-hex hashes and their FIRST segment is the
  # session — so every proposal from one session shares a prefix, and a git-style short form would
  # be ambiguous exactly where it's most used (re-proposing the same session). Printing it whole is
  # unambiguous and still copy-pasteable; `resolve_id/1` is what lets you type fewer characters.
  defp render_artifact(%{id: id}),
    do: "\nartifact #{id}\n  faber show #{id}  ·  faber install #{id}"

  # ── proposals / show ───────────────────────────────────────────────────────

  defp list_proposals(opts) do
    records = Store.list()

    cond do
      # An empty store in JSON is `{"count": 0, "proposals": []}` — a valid answer, not the prose
      # explaining how to get one. The human path keeps the prose.
      json?(opts) -> IO.puts(JSON.proposals(records, installed_names(opts[:dir])))
      records == [] -> IO.puts(empty_store_message())
      true -> IO.puts(render_proposals(records, opts[:dir]))
    end

    0
  end

  # The only thing that ever deletes a proposal, and only because a human typed --prune. Reports
  # exactly what went, by name: "pruned 12 proposals" with no names is indistinguishable from having
  # deleted the wrong twelve.
  defp prune_proposals(keep) do
    case Store.prune(keep) do
      [] ->
        IO.puts("Nothing to prune — #{length(Store.list())} proposals, keeping #{keep}.")
        0

      dropped ->
        lines = Enum.map_join(dropped, "\n", fn r -> "  #{r.id}  #{r.name}" end)

        IO.puts(
          "Pruned #{length(dropped)} #{pluralize("proposal", dropped)}, kept the #{keep} " <>
            "newest:\n#{lines}"
        )

        0
    end
  end

  # `Store.find/1` already distinguishes not-found from ambiguous; this only adds the guard for an
  # id that never arrived (defence in depth — `parse_with_id/3` refuses that case first).
  defp resolve_id(nil), do: {:error, :missing_id}
  defp resolve_id(id) when is_binary(id), do: Store.find(id)

  defp empty_store_message do
    if Store.enabled?() do
      "No proposals yet. `faber propose` or `faber consolidate` writes one per drafted skill\n" <>
        "to #{Faber.proposals_dir()}."
    else
      "The proposal store is disabled (`config :faber, :proposal_store, false`), so nothing is\n" <>
        "being kept. Enable it to stop paying for the same skill twice."
    end
  end

  @proposals_columns [
    {"id", 25, :left},
    {"skill", 30, :left},
    {"composite", 9, :right},
    {"outcome", 14, :left},
    {"engine", 22, :left},
    {"src", 3, :right}
  ]

  defp render_proposals(records, dir) do
    installed = installed_names(dir)

    header =
      @proposals_columns
      |> Enum.map_join(" ", fn {label, w, align} -> pad_cell(label, w, align) end)
      |> Kernel.<>("  installed")

    rows = Enum.map_join(records, "\n", &proposals_row(&1, installed))

    "#{length(records)} #{pluralize("proposal", records)} in #{Faber.proposals_dir()}\n\n" <>
      "#{header}\n#{rows}\n\nsrc = sessions this was drawn from. `faber show <id>` for the full skill."
  end

  defp proposals_row(record, installed) do
    values = [
      record.id,
      truncate(to_string(record.name), 30),
      Render.score(record.eval[:composite]),
      to_string(record.outcome),
      truncate(to_string(record.eval[:engine] || "—"), 22),
      to_string(length(record.source_sessions))
    ]

    @proposals_columns
    |> Enum.zip(values)
    |> Enum.map_join(" ", fn {{_l, w, align}, v} -> pad_cell(v, w, align) end)
    |> Kernel.<>("  #{if(record.name in installed, do: "✓", else: "")}")
  end

  # `list_faber_installed/1`, not `list_installed/1`: the generic primitive would enumerate skills
  # Faber never created and claim them as ours (the provenance rule — see .claude/solutions/
  # 2026-06-25-sync-pointer-over-claim-provenance.md).
  defp installed_names(dir) do
    dir
    |> then(
      &if(is_binary(&1),
        do: Install.list_faber_installed(&1),
        else: Install.list_faber_installed()
      )
    )
    |> MapSet.new(& &1.name)
  end

  defp render_show(record) do
    """
    #{record.name} — #{record.outcome}, composite #{Render.score(record.eval[:composite])} \
    (#{record.eval[:engine] || "engine unrecorded"})
    id #{record.id}
    adapter #{record.adapter || "—"} · created #{record.created_at}
    #{render_sources(record)}
    #{render_dimensions(record.eval[:dimensions])}
    #{String.duplicate("─", 72)}
    #{record.md}
    """
  end

  defp render_sources(%{source_sessions: sessions}) do
    "sessions #{Enum.join(sessions, ", ")}"
  end

  defp render_dimensions(dims) when is_map(dims) and map_size(dims) > 0 do
    lines =
      dims
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Enum.map_join("\n", fn {name, d} ->
        "  #{String.pad_trailing(to_string(name), 16)} #{Render.score(dimension_score(d))}"
      end)

    "\ndimensions:\n#{lines}"
  end

  defp render_dimensions(_), do: ""

  # A dimension's score survives the JSON round-trip under a string key (only the eval's TOP-level
  # keys are atomized — see the store's @eval_keys), so read both rather than assuming either.
  defp dimension_score(%{score: s}), do: s
  defp dimension_score(%{"score" => s}), do: s
  defp dimension_score(_), do: nil

  # ── consolidate ─────────────────────────────────────────────────────────────

  # An empty corpus is not "no proposals to consolidate" — nothing was ever drafted, because nothing
  # was found. Same distinction select_session/3 draws for propose/refine.
  defp consolidate_sessions([], scan_opts, _top),
    do: {:error, {:no_sessions, scan_root(scan_opts)}}

  defp consolidate_sessions(results, _scan_opts, top), do: {:ok, Enum.take(results, top)}

  defp report_skipped([]), do: :ok

  defp report_skipped(skipped) do
    status(
      "skipping #{length(skipped)} stack-mismatched #{pluralize("session", skipped)} " <>
        "(#{Enum.map_join(skipped, ", ", &session/1)}) — --force includes them"
    )
  end

  # Draft one proposal per candidate session (reporting per-session failures without aborting
  # the batch), then cluster + merge + gate the survivors and print one line per outcome.
  defp consolidate_proposals(candidates, adapter, consolidate_opts, top) do
    total = length(candidates)

    {proposals, failures} =
      candidates
      |> Enum.with_index(1)
      |> Enum.reduce({[], []}, fn {r, i}, {oks, errs} ->
        status("drafting #{i}/#{total} #{session(r)}…")

        case Propose.propose(r, adapter) do
          {:ok, p} -> {[p | oks], errs}
          {:error, reason} -> {oks, [{r, reason} | errs]}
        end
      end)

    failures
    |> Enum.reverse()
    |> Enum.each(fn {r, reason} ->
      IO.puts(:stderr, "propose failed for #{session(r)}: #{humanize_error(reason)}")
    end)

    case Enum.reverse(proposals) do
      [] ->
        IO.puts(:stderr, "faber: no proposals to consolidate (top #{top} sessions)")
        1

      proposals ->
        outcomes =
          Consolidate.run(
            proposals,
            adapter,
            Keyword.put(consolidate_opts, :on_progress, &consolidate_progress/1)
          )

        # Filed before printed. THIS is the line whose absence cost 4 eval-passing skills and ~10
        # LLM calls in a single live run.
        records = store_outcomes(outcomes, adapter)
        IO.puts(render_outcomes(outcomes) <> render_artifacts(records))
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
    do: "  #{Render.badge("kept", :neutral)}            —       #{p.name} (singleton cluster)"

  defp render_outcome({:merged, merged, eval, originals}),
    do:
      "  #{Render.badge("MERGED", :ok)}          #{Render.score(eval.composite)}  #{merged.name} ← #{names(originals)}"

  defp render_outcome({:kept_originals, originals, eval}),
    do:
      "  #{Render.badge("kept-originals", :warn)}  #{Render.score(eval.composite)}  merge below gate — #{names(originals)}"

  defp render_outcome({:error, originals, reason}),
    do:
      "  #{Render.badge("error", :bad)}           —       #{names(originals)}: #{humanize_error(reason)}"

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
          "#{Render.score(e.new_composite)}  #{e.description}#{note}"
      end)

    """
    #{state.skill || "skill"} — refined #{Render.score(start)} → #{Render.score(state.best_composite)} \
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
    do: "\nholdout: validation scoring failed — #{humanize_error(reason)}\n"

  defp render_holdout(%{composite: comp, behavioral: behavioral, fixtures: n}) do
    "\nholdout: composite #{Render.score(comp)}, behavioral #{Render.score(behavioral)} " <>
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
          # Truncated, not just padded: pad_trailing/2 leaves an over-long name at full length, so
          # one 40-char skill wraps the row and every column after it stops lining up.
          "  " <> String.pad_trailing(truncate(r.skill, 32), 32),
          String.pad_leading(to_string(r.sessions), 8),
          String.pad_leading(to_string(r.sessions_used), 5),
          String.pad_leading(Render.rate(r.usage_rate), 6),
          String.pad_leading(Render.friction(r.friction_with), 12),
          String.pad_leading(Render.friction(r.friction_without), 5),
          "   #{feedback_badge(r.verdict)}"
        ]
        |> Enum.join(" ")
      end)

    # The four `t:Faber.Feedback.report/0` verdicts. `:active` is the only good news; `:unused` is
    # the one that asks you to do something. `:no_sessions`/`:low_usage` are "not enough evidence
    # yet" — neutral, not a complaint about the skill.
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

  defp feedback_badge(:active), do: Render.badge("active", :ok)
  defp feedback_badge(:unused), do: Render.badge("unused", :warn)
  defp feedback_badge(other), do: Render.badge(to_string(other), :neutral)

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
    case f && Format.cast(f) do
      {:ok, format} -> format
      _ -> nil
    end
  end

  defp put_if(opts, _key, nil), do: opts
  defp put_if(opts, key, value), do: Keyword.put(opts, key, value)

  defp version do
    case Application.spec(:faber, :vsn) do
      vsn when is_list(vsn) -> List.to_string(vsn)
      _ -> "dev"
    end
  end

  # Per-subcommand help is *sliced out of* usage/0 rather than kept as a second copy per command:
  # duplicated help text drifts from the flags the first time one changes, and `parse_sub/3` is
  # already the single source of truth for what a subcommand accepts. An unrecognized subcommand
  # (or a block that can't be found) falls back to the full manual — help must never print nothing.
  #
  # This does couple to usage/0's layout, so cli_test.exs ("every subcommand slices a non-empty help
  # block naming itself") asserts exactly that for every subcommand; reformat the heredoc and the
  # test says so, instead of `faber scan --help` quietly going blank.
  defp usage(nil), do: usage()

  defp usage(sub) when is_atom(sub) do
    case usage_block(sub) do
      [] ->
        usage()

      block ->
        (["faber #{version()} — #{sub}", "", "Usage:"] ++ block ++ usage_footer(block))
        |> Enum.join("\n")
        |> Kernel.<>("\n")
    end
  end

  # Carry the --source/--format footer only for the subcommands that take them, so `faber scan
  # --help` still explains what `--source ccrider` means while `faber serve --help` isn't padded
  # with flags it doesn't accept.
  defp usage_footer(block) do
    if Enum.any?(block, &(&1 =~ ~r/--source|--format/)) do
      usage()
      |> String.split("\n")
      |> Enum.drop_while(&(not String.starts_with?(&1, "Sources (--source)")))
      |> then(&["" | &1])
    else
      []
    end
  end

  # A block runs from `  faber <sub> …` up to (not including) the next `  faber …` line — that is,
  # the command's own line plus its indented continuation/annotation lines.
  defp usage_block(sub) do
    starts = ~r/^  faber #{Regex.escape(to_string(sub))}\b/
    next = ~r/^  faber \S/

    usage()
    |> String.split("\n")
    |> Enum.drop_while(&(not Regex.match?(starts, &1)))
    |> case do
      [] -> []
      [line | rest] -> [line | Enum.take_while(rest, &(not Regex.match?(next, &1)))]
    end
    |> Enum.reverse()
    |> Enum.drop_while(&(String.trim(&1) == ""))
    |> Enum.reverse()
  end

  defp usage do
    """
    faber #{version()} — local-first improvement engine for AI coding agents

    Usage:
      faber scan [--limit N] [--rank-by raw|rate] [--source S] [--format F] [--db PATH]
                 [--base DIR] [--all] [--json] [--min-messages N]
                                                    Rank session friction for the project you're in
                                                    (--all: every project on this machine;
                                                     --base: transcript root override;
                                                     --json: raw values + the full signal vector;
                                                     --min-messages: skip shorter sessions)
      faber propose [--rank N | --top N] [--hazard KIND] [--cluster-threshold F] [--install]
                    [--force] [--trigger]
                    [--dry-run] [--source S] [--format F] [--db PATH] [--base DIR] [--all]
                    [--min-messages N]              Draft + eval a skill from your friction
                                                    (--hazard KIND: draft a HOOK instead, for a
                                                     frictionless hazard — a dangerous command shape
                                                     a session ran without struggling, so it scores
                                                     zero friction and no ranking would find it.
                                                     Selects the first session carrying that class,
                                                     so it combines with neither --rank nor --top.
                                                     `faber scan --json` lists the hazards found
                                                     per session; today: pipe_masks_exit;
                                                     --top N: draft the top-N sessions, cluster
                                                     near-duplicates and LLM-merge each cluster —
                                                     every merge must pass the eval gate or the
                                                     originals are kept (--cluster-threshold F:
                                                     token-Jaccard to share a cluster, default 0.3);
                                                     --rank N: draft one session instead — the two
                                                     cannot be combined;
                                                     --dry-run: print the sessions, adapter, eval
                                                     engine and LLM calls it WOULD spend, then
                                                     exit 0 having spent none;
                                                     --force: skip the stack-match gate;
                                                     --all: rank across every project, not just
                                                     the one you're in;
                                                     --trigger: add the behavioral trigger-accuracy
                                                     dimension — one keyless LLM call per fixture)
      faber refine [--rank N] [--strategy reflect|regenerate] [--iterations N] [--patience N]
                   [--target F] [--min-improvement F] [--trigger] [--trigger-samples N]
                   [--holdout] [--install] [--force] [--source S] [--format F] [--db PATH]
                   [--base DIR] [--all] [--min-messages N]
                                                    Self-improve a skill: propose → eval → keep
                                                    the best, looping (default: 5 reflective
                                                    iterations, keyless via claude -p).
                                                    (--trigger: also optimize routing recall,
                                                     scored on the seed's pinned fixtures;
                                                     --holdout: report a held-out validation
                                                     score; --install: install the final best)
      faber consolidate [...]                       DEPRECATED — this is `faber propose --top N`
                                                    now (default 5). It still runs, forwarding
                                                    every flag unchanged.
      faber proposals [--prune] [--keep N] [--dir PATH] [--json]
                                                    List every skill faber has drafted and kept
                                                    (#{Faber.proposals_dir()}) — id, composite,
                                                    outcome, scoring engine, whether it's installed
                                                    (--prune: delete all but the newest --keep N,
                                                     default 50 — the ONLY thing that ever removes
                                                     a proposal, and only when you ask)
      faber show <id> [--json]                      Print one proposal's SKILL.md plus its
                                                    per-dimension eval breakdown and provenance
                                                    (<id> may be any unambiguous prefix)
      faber install <id> [--force] [--dir PATH]     Install a proposal as a skill. If one is already
                                                    installed under that name, prints a diff and
                                                    refuses — --force replaces it
      faber feedback [--dir PATH] [--source S] [--format F] [--db PATH] [--base DIR] [--all]
                     [--json] [--min-messages N]    The outer loop: for every Faber-installed
                                                    skill, report whether sessions since install
                                                    actually used it and how friction compares —
                                                    verdicts flag skills to refine or retire
                                                    (--all: judge usage across every project)
      faber serve [--port P] [--no-open]            Start the dashboard UI in your browser
                                                    (also serves the read-only MCP server at /mcp)
      faber sync [--target claude,codex] [--check] [--force] [--dir PATH]
                                                    Register installed skills in each agent's
                                                    context file (managed block; --check: report
                                                    drift only, no write)
      faber help | --version

    Scope: commands that read sessions default to the project you're standing in (walking up to the
    git root), and say so on their first line. --all ranks every project on the machine; --base DIR
    reads exactly that root. A directory with no recorded sessions falls back to --all and says so.

    Global: --quiet suppresses status/progress lines (stderr) and keeps results (stdout).

    Sources (--source): files (default) walks the agent's transcript dir; ccrider reads ccrider's
    SQLite index (--db, default ~/.config/ccrider/sessions.db). Or set config :faber, :ingest_source.

    Formats (--format): claude (default), codex, cline, gemini, opencode — each reads that agent's
    own transcript location. The non-Claude formats are files-only (ccrider indexes Claude content);
    opencode reads its SQLite store via the sqlite3 CLI.
    """
  end
end
