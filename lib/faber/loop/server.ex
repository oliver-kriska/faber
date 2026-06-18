defmodule Faber.Loop.Server do
  @moduledoc """
  GenServer wrapper around `Faber.Loop.run/1` for on-demand / overnight runs under
  `Faber.Loop.Supervisor`.

  The loop runs in a linked `Task` so the server's mailbox stays responsive: `status/1` returns
  `:running` immediately while the loop is in flight (then the final `:complete` / `:stuck`), and
  `await/2` parks the caller and is replied to the moment the loop finishes — it never blocks the
  GenServer itself. Restart is `:temporary`: a finished or crashed loop is not re-run
  automatically. If the loop Task crashes, the link propagates and the server crashes too, which
  the `:temporary` strategy leaves down — correct crash-isolation.
  """

  use GenServer, restart: :temporary

  alias Faber.Loop

  @doc "Start a loop server. `opts` are the `Faber.Loop.run/1` options (plus optional `:name`)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {gen_opts, loop_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, loop_opts, gen_opts)
  end

  @doc "Current status: `:running` until the loop finishes, then `:complete` / `:stuck`."
  @spec status(GenServer.server()) :: atom()
  def status(server), do: GenServer.call(server, :status)

  @doc """
  Block until the loop finishes and return `{:ok, %Faber.Loop.State{}}`.

  Defaults to `:infinity` because an autoresearch run can take hours; pass a finite timeout if you
  want a bound. The server replies as soon as the loop Task completes — it is not itself blocked
  while waiting.
  """
  @spec await(GenServer.server(), timeout()) :: {:ok, Loop.State.t()}
  def await(server, timeout \\ :infinity), do: GenServer.call(server, :await, timeout)

  @impl true
  def init(loop_opts) do
    {:ok, %{loop_opts: loop_opts, result: nil, task: nil, waiters: []}, {:continue, :run}}
  end

  @impl true
  def handle_continue(:run, state) do
    task = Task.async(fn -> Loop.run(state.loop_opts) end)
    {:noreply, %{state | task: task}}
  end

  @impl true
  def handle_call(:status, _from, %{result: nil} = state), do: {:reply, :running, state}
  def handle_call(:status, _from, %{result: r} = state), do: {:reply, r.status, state}

  def handle_call(:await, _from, %{result: r} = state) when not is_nil(r),
    do: {:reply, {:ok, r}, state}

  def handle_call(:await, from, %{result: nil} = state),
    do: {:noreply, %{state | waiters: [from | state.waiters]}}

  @impl true
  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    Enum.each(state.waiters, &GenServer.reply(&1, {:ok, result}))
    {:noreply, %{state | result: result, task: nil, waiters: []}}
  end

  # The loop Task is linked, so a crash takes the server down before this fires for an abnormal
  # exit; the :normal DOWN after a clean run is flushed in the success clause above. Catch-all
  # keeps any stray message from logging an unhandled-message warning.
  def handle_info(_msg, state), do: {:noreply, state}
end
