defmodule Faber.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # In the single-binary distribution the argv selects a subcommand (nil in dev/test/iex). The
    # web endpoint starts only when there's a UI to serve, so a one-shot `faber scan` never binds a
    # port; the port override (serve --port) is applied before the endpoint child is built.
    command = Faber.CLI.command()
    Faber.CLI.maybe_apply_port(command)

    children =
      [
        # PubSub first — anything below may broadcast on it.
        {Phoenix.PubSub, name: Faber.PubSub},
        # On-demand homes for autoresearch loop runs (M5). Started empty; loops are launched
        # explicitly via Faber.Loop.Supervisor.start_loop/1, never at boot.
        Faber.Loop.Supervisor,
        # Crash-isolated home for the scheduler's pipeline jobs (async_nolink): a job that throws
        # or exits must NOT take down the long-lived scheduler. Must start before Faber.Schedule.
        {Task.Supervisor, name: Faber.Schedule.TaskSupervisor},
        # Scheduled/overnight pipeline runs (M5). Started INERT — does nothing unless
        # `config :faber, :schedule` sets `enabled: true`. No autonomous action by default.
        Faber.Schedule
      ] ++ web_children(command)

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Faber.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      # Run the CLI command once the tree (incl. endpoint for `serve`) is up. One-shot commands
      # halt the VM; `serve` returns and the listening endpoint keeps it alive. `nil` → no-op.
      Faber.CLI.dispatch(command)
      {:ok, pid}
    end
  end

  # Web dashboard (M6). Start it for normal app boot (dev/test, `mix phx.server`) and for the
  # `serve` command; omit it for one-shot CLI commands so they don't bind a port.
  defp web_children(nil), do: [FaberWeb.Endpoint]
  defp web_children({:serve, _opts}), do: [FaberWeb.Endpoint]
  defp web_children(_one_shot), do: []
end
