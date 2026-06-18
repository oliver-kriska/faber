defmodule FaberWeb do
  @moduledoc """
  Web interface (M6) — entrypoint definitions for the dashboard.

  `use FaberWeb, :live_view` / `:router` / `:html` pull in the right imports so the web modules
  stay terse. Deliberately minimal: no controllers/JSON/gettext — the dashboard is a single
  LiveView over `Faber.Scan`.
  """

  def static_paths, do: ~w(assets)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView

      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      import Phoenix.HTML
      alias Phoenix.LiveView.JS

      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: FaberWeb.Endpoint,
        router: FaberWeb.Router,
        statics: FaberWeb.static_paths()
    end
  end

  @doc "Dispatch `use FaberWeb, :which` to the matching helper."
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
