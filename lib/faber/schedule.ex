defmodule Faber.Schedule do
  @moduledoc """
  **Stage 6 — scheduled / overnight runs.** A timer-driven driver that runs the whole pipeline
  unattended: `Scan` → `Propose` → `Eval` (→ optional `Install`) on the top-ranked sessions, on a
  fixed interval.

  Deliberately **DB-less and Oban-free** — the spine has no Ecto/Postgres, so scheduling is a
  plain `GenServer` + `Process.send_after/3`. It is **started inert**: the supervision tree always
  boots one, but it does nothing unless `config :faber, :schedule` sets `enabled: true`. Faber
  takes no autonomous action by default.

  ## Configuration

      config :faber, :schedule,
        enabled: true,
        every_ms: :timer.hours(8),
        initial_delay_ms: :timer.minutes(1),   # optional; defaults to every_ms
        max_run_ms: :timer.minutes(30),        # kill a run that exceeds this (wedge guard)
        adapter_dir: "adapters/faber-elixir",
        top: 3,                                 # how many top-ranked sessions to propose for
        install: false,                         # install skills that pass the eval bar?
        scan: [limit: 400, min_messages: 4]

  Each run is logged with a one-line summary. `run_once/1` is the pure pipeline driver (no timer,
  no process) and is what the GenServer invokes on every tick — call it directly to run the
  pipeline synchronously. A run never overlaps the previous one (a tick that fires while a run is
  still in flight is skipped and rescheduled).
  """

  use GenServer
  require Logger

  alias Faber.{Adapter, Eval, Install, Propose, Scan}

  @hours8 60 * 60 * 8 * 1000

  # ── client API ─────────────────────────────────────────────────────────────

  @doc "Start the scheduler. `opts` override `config :faber, :schedule` (plus optional `:name`)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Scheduler status: `:enabled`, `:running`, completed `:runs`, `:every_ms`, `:last_summary`."
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc "Trigger a pipeline run immediately (asynchronously). Ignored if a run is already in flight."
  @spec run_now(GenServer.server()) :: :ok
  def run_now(server \\ __MODULE__), do: GenServer.cast(server, :run_now)

  @doc """
  Run the full pipeline once, synchronously, and return a summary. Pure of timers/processes — this
  is what every tick invokes. Returns `%{scanned: n, proposals: [%{name, composite, passed,
  installed}]}` (or `%{error: reason}` if the adapter fails to load).
  """
  @spec run_once(keyword()) :: map()
  def run_once(opts \\ []) do
    adapter_dir = opts[:adapter_dir] || Faber.adapter_dir()
    top = opts[:top] || 3
    scan_opts = opts[:scan] || [limit: 400, min_messages: 4]
    llm_opts = Keyword.take(opts, [:llm, :model, :stub_response])

    case Adapter.load(adapter_dir) do
      {:ok, adapter} ->
        results = scan_opts |> Scan.run() |> Enum.take(top)

        %{
          scanned: length(results),
          proposals: Enum.map(results, &propose_one(&1, adapter, opts, llm_opts))
        }

      {:error, reason} ->
        %{scanned: 0, proposals: [], error: reason}
    end
  end

  defp propose_one(result, adapter, opts, llm_opts) do
    with {:ok, proposal} <- Propose.propose(result, adapter, llm_opts),
         {:ok, eval} <- Eval.score(proposal, [adapter: adapter] ++ llm_opts) do
      %{
        name: proposal.name,
        composite: eval.composite,
        passed: eval.passed,
        installed: maybe_install(proposal, eval, adapter, opts)
      }
    else
      {:error, reason} -> %{error: inspect(reason)}
    end
  end

  # Only install when explicitly opted in AND the skill cleared its stack's eval bar. Install with
  # the adapter so the file written to disk is the same artifact the eval gated.
  defp maybe_install(proposal, %{passed: true}, adapter, opts) do
    if opts[:install] do
      match?({:ok, _}, Install.install(proposal, Keyword.put(opts, :adapter, adapter)))
    else
      false
    end
  end

  defp maybe_install(_proposal, _eval, _adapter, _opts), do: false

  # ── server ───────────────────────────────────────────────────────────────-

  @impl true
  def init(opts) do
    cfg = Keyword.merge(Application.get_env(:faber, :schedule, []), opts)

    state = %{
      enabled: Keyword.get(cfg, :enabled, false),
      every_ms: Keyword.get(cfg, :every_ms, @hours8),
      max_run_ms: Keyword.get(cfg, :max_run_ms, :timer.minutes(30)),
      notify: Keyword.get(cfg, :notify),
      job_opts: Keyword.drop(cfg, [:enabled, :every_ms, :initial_delay_ms, :max_run_ms, :notify]),
      timer: nil,
      running: false,
      task: nil,
      runs: 0,
      last_summary: nil
    }

    first_delay = Keyword.get(cfg, :initial_delay_ms, state.every_ms)
    {:ok, schedule_next(state, first_delay)}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, Map.take(state, [:enabled, :running, :runs, :every_ms, :last_summary]), state}
  end

  @impl true
  def handle_cast(:run_now, %{running: true} = state) do
    Logger.info("faber schedule: run_now ignored — a run is already in flight")
    {:noreply, state}
  end

  def handle_cast(:run_now, state), do: {:noreply, start_job(state)}

  @impl true
  def handle_info(:tick, %{running: true} = state) do
    # Don't overlap runs: skip this tick and try again next interval.
    {:noreply, schedule_next(state, state.every_ms)}
  end

  def handle_info(:tick, state), do: {:noreply, start_job(state)}

  def handle_info({ref, summary}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    Logger.info("faber schedule: run ##{state.runs + 1} complete — #{summarize(summary)}")
    {:noreply, finish_run(state, summary)}
  end

  # async_nolink: a job that crashes (an exit/throw the job body didn't catch) arrives as a DOWN
  # instead of killing the scheduler. Record it as a failed run and keep ticking.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    summary = %{scanned: 0, proposals: [], error: {:job_crashed, reason}}
    Logger.error("faber schedule: run ##{state.runs + 1} crashed — #{inspect(reason)}")
    {:noreply, finish_run(state, summary)}
  end

  # Wedge guard: a run that outlives :max_run_ms (a hung subprocess despite the per-call
  # timeouts, a pathological scan) is killed and recorded as a failed run — without this,
  # `running: true` would stick forever and every future tick would be silently skipped.
  # `Task.shutdown` may race a just-finished task and hand us its reply; treat that as a
  # normal completion.
  def handle_info({:run_deadline, ref}, %{task: %Task{ref: ref} = task} = state) do
    case Task.shutdown(task, :brutal_kill) do
      {:ok, summary} ->
        Logger.info("faber schedule: run ##{state.runs + 1} complete — #{summarize(summary)}")
        {:noreply, finish_run(state, summary)}

      _ ->
        Logger.error(
          "faber schedule: run ##{state.runs + 1} exceeded max_run_ms (#{state.max_run_ms}ms) — killed"
        )

        {:noreply, finish_run(state, %{scanned: 0, proposals: [], error: :run_timeout})}
    end
  end

  # A deadline for an already-completed run — the current task (if any) has a different ref.
  def handle_info({:run_deadline, _stale_ref}, state), do: {:noreply, state}

  def handle_info(_msg, state), do: {:noreply, state}

  # ── internals ──────────────────────────────────────────────────────────────

  defp start_job(state) do
    Logger.info("faber schedule: starting pipeline run ##{state.runs + 1}")
    job_opts = state.job_opts

    # async_nolink under a Task.Supervisor: the job runs crash-isolated so a throw/exit becomes a
    # DOWN message here rather than killing the long-lived scheduler. rescue/catch still convert
    # the common failure into a clean summary so a single bad session doesn't even count as a crash.
    task =
      Task.Supervisor.async_nolink(__MODULE__.TaskSupervisor, fn ->
        try do
          run_once(job_opts)
        rescue
          e -> %{scanned: 0, proposals: [], error: Exception.message(e)}
        catch
          kind, reason -> %{scanned: 0, proposals: [], error: {kind, reason}}
        end
      end)

    Process.send_after(self(), {:run_deadline, task.ref}, state.max_run_ms)
    %{state | running: true, task: task}
  end

  # Record a completed run, notify any test/observer, and reschedule.
  defp finish_run(state, summary) do
    if state.notify, do: send(state.notify, {:faber_schedule, :run_complete, summary})
    state = %{state | running: false, task: nil, runs: state.runs + 1, last_summary: summary}
    schedule_next(state, state.every_ms)
  end

  # Single timer at all times: cancel any pending tick before arming a new one. Inert when disabled.
  defp schedule_next(%{enabled: false} = state, _delay) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: nil}
  end

  defp schedule_next(state, delay) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :tick, delay)}
  end

  defp summarize(%{error: reason}), do: "error: #{inspect(reason)}"

  defp summarize(%{scanned: n, proposals: props}) do
    passed = Enum.count(props, &(Map.get(&1, :passed) == true))
    installed = Enum.count(props, &(Map.get(&1, :installed) == true))
    "#{n} scanned, #{length(props)} proposed, #{passed} passed, #{installed} installed"
  end
end
