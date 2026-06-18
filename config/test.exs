import Config

# Tests never hit a live LLM: the stub returns deterministic structured proposals.
config :faber, :llm, Faber.LLM.Stub

# The dashboard scans the committed fixtures (fast, deterministic) instead of the real
# ~/.claude history, so the LiveView test is hermetic.
config :faber, :dashboard_scan_opts, base: "test/fixtures", min_messages: 0

# Endpoint runs without binding a port; Phoenix.LiveViewTest drives it in-process.
config :faber, FaberWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "kZ3pQ7mN1rT5wY9bD2fH6jL0sV4xC8aE3gI7kM1oQ5uW9yA2cF6hJ0lN4pR8tX2zB6testTST",
  server: false

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
