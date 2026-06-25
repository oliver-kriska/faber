defmodule Faber.MCP.Tools.GetSkill do
  @moduledoc """
  Fetch the full `SKILL.md` body of an installed skill by name. Use after `faber_list_skills` to read
  a skill's instructions. The name is resolved against the *installed* skills only, so it can never
  read a file outside the skills directory.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias Faber.Install

  schema do
    field(:name, {:required, :string},
      description:
        "The skill's name (its directory under the skills dir, e.g. \"investigate-retry-loops\")."
    )
  end

  @impl true
  def execute(%{name: name}, frame) do
    # Resolve against the discovered Faber-installed listing (never a caller-supplied path) →
    # traversal-proof, and scoped to skills Faber installed (matching this tool's contract).
    case Enum.find(Install.list_faber_installed(), &(&1.name == name)) do
      %{path: path} ->
        # A clean tool error (not a 500) if the file vanished between listing and read (TOCTOU).
        case File.read(path) do
          {:ok, body} ->
            {:reply, Response.text(Response.tool(), body), frame}

          {:error, reason} ->
            {:reply,
             Response.error(
               Response.tool(),
               "Could not read skill #{inspect(name)} (#{:file.format_error(reason)})"
             ), frame}
        end

      nil ->
        {:reply,
         Response.error(
           Response.tool(),
           "No installed skill named #{inspect(name)}. Call faber_list_skills to see what's available."
         ), frame}
    end
  end
end
