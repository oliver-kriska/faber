defmodule Faber.Loop.Server do
  @moduledoc """
  GenServer wrapper around `Faber.Loop.run/1` for on-demand / overnight runs under
  `Faber.Loop.Supervisor`.

  The loop runs in a supervised, **unlinked** task (`Task.Supervisor.async_nolink` under
  `Faber.Loop.TaskSupervisor` — the same crash-isolation pattern as `Faber.Schedule`), so the
  server's mailbox stays responsive: `status/1` returns `:running` immediately while the loop is
  in flight (then `:complete` / `:stuck`, or `:crashed` / `:timeout`), and `await/2` parks the
  caller and is replied to the moment the loop finishes. A crash arrives here as a `:DOWN`
  message instead of killing the server, so waiters get `{:error, {:crashed, reason}}` rather
  than an exit — and on OTP shutdown the task is wound down by its own supervisor instead of a
  link killing it mid `git commit` (which used to leave a dirty index). Restart is `:temporary`:
  a finished, crashed, or timed-out loop is not re-run automatically.

  `:max_run_ms` (default `:infinity` — an autoresearch run may legitimately take hours) is the
  wedge guard mirroring `Faber.Schedule`: a run that outlives it is brutally killed and recorded
  as `{:error, :run_timeout}`, so a hung loop can't park `await/2` callers forever.
  """

  use GenServer, restart: :temporary

  alias Faber.Loop

  @doc """
  Start a loop server. `opts` are the `Faber.Loop.run/1` options, plus the server's own
  `:name` and `:max_run_ms`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {server_opts, loop_opts} = Keyword.split(opts, [:name, :max_run_ms])
    gen_opts = Keyword.take(server_opts, [:name])
    max_run_ms = Keyword.get(server_opts, :max_run_ms, :infinity)
    GenServer.start_link(__MODULE__, {loop_opts, max_run_ms}, gen_opts)
  end

  @doc """
  Current status: `:running` until the loop finishes, then `:complete` / `:stuck` — or
  `:crashed` (the loop raised/exited) / `:timeout` (killed by `:max_run_ms`).
  """
  @spec status(GenServer.server()) :: atom()
  def status(server), do: GenServer.call(server, :status)

  @doc """
  Block until the loop finishes and return `{:ok, %Faber.Loop.State{}}` — or
  `{:error, {:crashed, reason}}` / `{:error, :run_timeout}` when it didn't finish cleanly.

  Defaults to `:infinity` because an autoresearch run can take hours; pass a finite timeout if
  you want a bound. The server replies as soon as the loop task settles — it is not itself
  blocked while waiting.
  """
  @spec await(GenServer.server(), timeout()) :: {:ok, Loop.State.t()} | {:error, term()}
  def await(server, timeout \\ :infinity), do: GenServer.call(server, :await, timeout)

  @impl true
  def init({loop_opts, max_run_ms}) do
    state = %{
      loop_opts: loop_opts,
      max_run_ms: max_run_ms,
      result: nil,
      task: nil,
      waiters: []
    }

    {:ok, state, {:continue, :run}}
  end

  @impl true
  def handle_continue(:run, state) do
    task =
      Task.Supervisor.async_nolink(Faber.Loop.TaskSupervisor, fn ->
        Loop.run(state.loop_opts)
      end)

    if state.max_run_ms != :infinity do
      Process.send_after(self(), {:run_deadline, task.ref}, state.max_run_ms)
    end

    {:noreply, %{state | task: task}}
  end

  @impl true
  def handle_call(:status, _from, %{result: nil} = state), do: {:reply, :running, state}
  def handle_call(:status, _from, %{result: {:ok, r}} = state), do: {:reply, r.status, state}

  def handle_call(:status, _from, %{result: {:error, :run_timeout}} = state),
    do: {:reply, :timeout, state}

  def handle_call(:status, _from, %{result: {:error, _}} = state),
    do: {:reply, :crashed, state}

  def handle_call(:await, _from, %{result: result} = state) when not is_nil(result),
    do: {:reply, result, state}

  def handle_call(:await, from, %{result: nil} = state),
    do: {:noreply, %{state | waiters: [from | state.waiters]}}

  @impl true
  def handle_info({ref, loop_state}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, settle(state, {:ok, loop_state})}
  end

  # async_nolink: a loop that raises/exits arrives as a DOWN instead of killing the server —
  # record it and reply to the waiters, leaving the server queryable.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    {:noreply, settle(state, {:error, {:crashed, reason}})}
  end

  # Wedge guard (mirrors Faber.Schedule): a run that outlives :max_run_ms is killed and recorded,
  # so await/2 callers aren't parked forever behind a hung subprocess. `Task.shutdown` may race a
  # just-finished task and hand us its reply; treat that as a normal completion.
  def handle_info({:run_deadline, ref}, %{task: %Task{ref: ref} = task} = state) do
    case Task.shutdown(task, :brutal_kill) do
      {:ok, loop_state} -> {:noreply, settle(state, {:ok, loop_state})}
      _ -> {:noreply, settle(state, {:error, :run_timeout})}
    end
  end

  # A deadline for an already-settled run — the current task (if any) has a different ref.
  def handle_info({:run_deadline, _stale_ref}, state), do: {:noreply, state}

  def handle_info(_msg, state), do: {:noreply, state}

  defp settle(state, result) do
    Enum.each(state.waiters, &GenServer.reply(&1, result))
    %{state | result: result, task: nil, waiters: []}
  end
end
