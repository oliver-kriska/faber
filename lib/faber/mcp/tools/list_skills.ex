defmodule Faber.MCP.Tools.ListSkills do
  @moduledoc """
  List the skills Faber has installed (name + one-line description). Use this to see which reusable
  skills are already available before proposing a new one or fetching a skill's full body with
  `faber_get_skill`.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias Faber.Install

  schema do
    %{}
  end

  @impl true
  def execute(_params, frame) do
    skills =
      Install.list_installed()
      |> Enum.map(&%{name: &1.name, description: &1.description})

    {:reply, Response.json(Response.tool(), %{count: length(skills), skills: skills}), frame}
  end
end
