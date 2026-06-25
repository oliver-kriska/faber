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

  # Read-only MCP server (Anubis) over streamable HTTP. No browser pipeline (no CSRF/HTML) — the
  # transport speaks JSON-RPC and manages its own sessions. The endpoint binds loopback only, so this
  # is a localhost, single-user surface. The Faber.MCP.Server process is supervised under `serve`
  # (see Faber.Application.web_children/1).
  forward("/mcp", Anubis.Server.Transport.StreamableHTTP.Plug, server: Faber.MCP.Server)
end
