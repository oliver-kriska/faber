import Config

config :faber, FaberWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  secret_key_base: "kZ3pQ7mN1rT5wY9bD2fH6jL0sV4xC8aE3gI7kM1oQ5uW9yA2cF6hJ0lN4pR8tX2zB6devDEV",
  debug_errors: true,
  code_reloader: false,
  # Pin origins to loopback: a DNS-rebinding page (attacker.com resolving to 127.0.0.1) must not
  # be able to open the LiveView socket and drive events (the Propose button spends LLM tokens).
  check_origin: ["//localhost", "//127.0.0.1"]

config :logger, :console, format: "[$level] $message\n"
config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime
