defmodule Faber.Loop.Server do
  @moduledoc """
  GenServer wrapper around `Faber.Loop.run/1` for on-demand / overnight runs under
  `Faber.Loop.Supervisor`.

  The loop runs once in `handle_continue` and the server then holds the final `%Faber.Loop.State{}`
  for querying. Because the run happens in the continue, a `status/1` or `await/2` call is served
  only after it finishes — `await/2` blocks until the loop terminates and returns the result.
  Restart is `:temporary`: a finished or crashed loop is not re-run automatically.
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
  def status(server), do: GenServer.call(server, :status, :infinity)

  @doc "Block until the loop finishes and return `{:ok, %Faber.Loop.State{}}`."
  @spec await(GenServer.server(), timeout()) :: {:ok, Loop.State.t()}
  def await(server, timeout \\ 60_000), do: GenServer.call(server, :await, timeout)

  @impl true
  def init(loop_opts) do
    {:ok, %{loop_opts: loop_opts, result: nil}, {:continue, :run}}
  end

  @impl true
  def handle_continue(:run, state) do
    {:noreply, %{state | result: Loop.run(state.loop_opts)}}
  end

  @impl true
  def handle_call(:status, _from, %{result: nil} = state), do: {:reply, :running, state}
  def handle_call(:status, _from, %{result: r} = state), do: {:reply, r.status, state}
  def handle_call(:await, _from, %{result: r} = state), do: {:reply, {:ok, r}, state}
end
