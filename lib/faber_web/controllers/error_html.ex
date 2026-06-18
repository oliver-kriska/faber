defmodule FaberWeb.ErrorHTML do
  @moduledoc "Bare error rendering — returns the status phrase (e.g. \"Not Found\")."
  use FaberWeb, :html

  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
