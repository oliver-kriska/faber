import Config

# Default to the keyless Claude Code CLI backend in dev: no API key, uses your existing auth.
# Switch to Faber.LLM.ReqLLM (and set ANTHROPIC_API_KEY) for the network path.
config :faber, :llm, Faber.LLM.ClaudeCLI

config :faber, FaberWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  secret_key_base: "kZ3pQ7mN1rT5wY9bD2fH6jL0sV4xC8aE3gI7kM1oQ5uW9yA2cF6hJ0lN4pR8tX2zB6devDEV",
  debug_errors: true,
  code_reloader: false,
  check_origin: false

config :logger, :console, format: "[$level] $message\n"
config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime
