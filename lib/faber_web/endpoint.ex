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
