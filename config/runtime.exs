import Config

# Production runtime config. For the single-binary distribution this is a LOCAL app (the dashboard
# binds loopback only), so — unlike a server deploy — we don't demand secrets from the environment:
# the secret_key_base is generated once and persisted under ~/.faber, and the port has a sane
# default. Override with SECRET_KEY_BASE / PORT / FABER_HOME when desired.
if config_env() == :prod do
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
    http: [ip: {127, 0, 0, 1}, port: port],
    secret_key_base: secret_key_base,
    check_origin: false,
    server: true
end
