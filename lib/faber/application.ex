defmodule Faber.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # On-demand homes for autoresearch loop runs (M5). Started empty; loops are launched
      # explicitly via Faber.Loop.Supervisor.start_loop/1, never at boot.
      Faber.Loop.Supervisor
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Faber.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
