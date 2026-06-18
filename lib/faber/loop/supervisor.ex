defmodule Faber.Loop.Supervisor do
  @moduledoc """
  `DynamicSupervisor` for autoresearch loop runs. Loops are started on demand (never at boot) —
  this just provides supervised, crash-isolated homes for `Faber.Loop.Server` processes so one
  runaway loop can't take down the spine.
  """

  use DynamicSupervisor

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @doc "Start a supervised loop run. `loop_opts` are forwarded to `Faber.Loop.Server`."
  @spec start_loop(keyword()) :: DynamicSupervisor.on_start_child()
  def start_loop(loop_opts) do
    DynamicSupervisor.start_child(__MODULE__, {Faber.Loop.Server, loop_opts})
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
