import Config

# Production runtime config. For the single-binary distribution this is a LOCAL app (the dashboard
# binds loopback only), so — unlike a server deploy — we don't demand secrets from the environment:
# the secret_key_base is generated once and persisted under ~/.faber, and the port has a sane
# default. Override with SECRET_KEY_BASE / PORT / FABER_HOME when desired.
if config_env() == :prod do
  # config/prod.exs ships the release quiet (framework chatter off). This is the way back in when
  # debugging one: `FABER_LOG_LEVEL=debug faber serve` restores the per-event narration. Setting it
  # at all also re-attaches Phoenix.Logger — you're asking for the framework's view, and a bare
  # level bump wouldn't bring back MOUNT/HANDLE EVENT on its own. (Plug.Telemetry's "GET /" pair
  # stays off regardless: endpoint.ex reads that via compile_env, which no env var can revisit.)
  #
  # Matched against a fixed list rather than String.to_existing_atom/1 on raw input — a typo must
  # not crash boot, and an arbitrary env value must not reach the atom table.
  case System.get_env("FABER_LOG_LEVEL") do
    nil ->
      :ok

    level when level in ~w(emergency alert critical error warning notice info debug none) ->
      config :logger, level: String.to_existing_atom(level)
      config :phoenix, :logger, true

    other ->
      IO.puts(:stderr, "faber: ignoring FABER_LOG_LEVEL=#{other} — not a valid Logger level")
  end

  config_dir = System.get_env("FABER_HOME") || Path.join(System.user_home() || ".", ".faber")
  File.mkdir_p!(config_dir)
  # The secret is a credential — keep the dir and file private (0700/0600), not world-readable.
  File.chmod(config_dir, 0o700)
  secret_path = Path.join(config_dir, "secret_key_base")

  # A non-empty persisted secret; nil if absent or blank (so a truncated file regenerates).
  persisted =
    if File.exists?(secret_path) do
      case String.trim(File.read!(secret_path)) do
        "" -> nil
        secret -> secret
      end
    end

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") || persisted ||
      (
        secret = Base.url_encode64(:crypto.strong_rand_bytes(48), padding: false)
        File.write!(secret_path, secret)
        secret
      )

  # Tighten perms whether we just wrote it or it predates this fix.
  if File.exists?(secret_path), do: File.chmod(secret_path, 0o600)

  port = String.to_integer(System.get_env("PORT") || "4710")

  config :faber, FaberWeb.Endpoint,
    # Loopback only — the dashboard has no auth (local-first). Do not bind 0.0.0.0 here.
    url: [host: "localhost", port: port, scheme: "http"],
    # `startup_log: false` (Bandit) + `log_access_url: false` (Phoenix) suppress the framework's
    # two boot lines. `faber serve` already prints its own "Faber UI → <url> (Ctrl-C to stop)",
    # and the framework's pair says the same thing twice while straddling it.
    http: [ip: {127, 0, 0, 1}, port: port, startup_log: false],
    log_access_url: false,
    secret_key_base: secret_key_base,
    # Pin origins to loopback (any port — `faber serve --port` is user-chosen): a DNS-rebinding
    # page resolving to 127.0.0.1 must not be able to open the socket and drive Propose events.
    check_origin: ["//localhost", "//127.0.0.1"],
    server: true
end
