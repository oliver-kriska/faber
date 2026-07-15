import Config

config :faber, FaberWeb.Endpoint,
  # 4010, not Phoenix's default 4000: that port is contended by every other Phoenix app on this
  # machine, and Tidewave's MCP URL below hard-codes whatever we pick here.
  http: [ip: {127, 0, 0, 1}, port: 4010],
  secret_key_base: "kZ3pQ7mN1rT5wY9bD2fH6jL0sV4xC8aE3gI7kM1oQ5uW9yA2cF6hJ0lN4pR8tX2zB6devDEV",
  debug_errors: true,
  code_reloader: false,
  # Pin origins to loopback: a DNS-rebinding page (attacker.com resolving to 127.0.0.1) must not
  # be able to open the LiveView socket and drive events (the Propose button spends LLM tokens).
  check_origin: ["//localhost", "//127.0.0.1"]

# Deliberately NO `server: true`: `mix faber.scan` and friends boot the same app, and a bound
# listener here would make every mix task die on :eaddrinuse whenever the dashboard is running.
# `mix phx.server` (or `iex -S mix phx.server`) opts the listener in — that's the dev entrypoint
# for the dashboard and for Tidewave's MCP.

config :logger, :console, format: "[$level] $message\n"
config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime

# Annotate rendered HEEx with its source file/line so Tidewave (and browser devtools) can map a
# DOM node back to the template that produced it. Dev-only — it inflates the markup.
config :phoenix_live_view,
  debug_heex_annotations: true,
  debug_attributes: true
