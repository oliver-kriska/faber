defmodule FaberWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :faber

  @session_options [
    store: :cookie,
    key: "_faber_key",
    signing_salt: "Fb2xQ9pK",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]
  )

  # Serve the vendored UMD assets (priv/static/assets/*).
  plug(Plug.Static,
    at: "/",
    from: :faber,
    gzip: false,
    only: FaberWeb.static_paths()
  )

  # Dev-only runtime introspection (mix.exs pins `only: :dev`), mounted at /tidewave/mcp. The guard
  # is compile-time: in prod/test the module doesn't exist, so the plug is never inserted and the
  # shipped binary carries no arbitrary-code-eval surface.
  #
  # Position is load-bearing and Tidewave raises if you get it wrong: it must see the raw request
  # body, so it has to precede Plug.Parsers. Static comes first only so asset requests never enter
  # it; everything Tidewave doesn't own passes straight through to the plugs below.
  if Code.ensure_loaded?(Tidewave) do
    plug(Tidewave)
  end

  plug(Plug.RequestId)

  # `log: false` in prod (see config/prod.exs): `faber serve` logs to the user's terminal, where
  # Plug.Telemetry's "GET / … Sent 200 in 41ms" pair is aggregator-shaped noise rather than
  # anything a local CLI user asked for. Dev keeps it at :info.
  plug(Plug.Telemetry,
    event_prefix: [:phoenix, :endpoint],
    log: Application.compile_env(:faber, :request_logging, :info)
  )

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(FaberWeb.Router)
end
