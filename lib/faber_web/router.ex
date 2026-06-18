defmodule FaberWeb.Router do
  use FaberWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {FaberWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/", FaberWeb do
    pipe_through(:browser)

    live("/", DashboardLive, :index)
  end
end
