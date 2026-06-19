import Config

# LLM client for the skill proposer (M3). Default to the keyless Claude Code CLI backend
# (`claude -p`, uses existing auth, no API key). Opt into the network path with
# `config :faber, :llm, Faber.LLM.ReqLLM` + a provider key (e.g. ANTHROPIC_API_KEY).
config :faber, :llm, Faber.LLM.ClaudeCLI
config :faber, :llm_model, "anthropic:claude-sonnet-4-6"

# Eval engine (M4). Native Elixir structural scoring by default — no python3 needed on the hot
# path. Switch to `:sidecar` for the Python matcher port (parity / future GEPA + trigger eval).
config :faber, :eval_engine, :native

# Ingest format / source agent (M2). Claude Code transcripts by default. Cross-agent formats
# (Codex/OpenCode/Pi) plug in behind `Faber.Ingest.Format` once their transcript specs are pinned.
# Override per call with `Scan.run(format: :claude)` or globally here.
config :faber, :ingest_format, :claude

# Python eval sidecar (M4): interpreter + package dir. uv is optional; plain python3 works
# because the sidecar is stdlib + PyYAML only.
config :faber, :python, System.get_env("FABER_PYTHON", "python3")

# Scheduled/overnight pipeline runs (M5). DISABLED by default — Faber takes no autonomous action
# unless you opt in. Enable to periodically scan → propose → eval (and optionally install passing
# skills) with no human in the loop:
#
#   config :faber, :schedule,
#     enabled: true,
#     every_ms: :timer.hours(8),
#     adapter_dir: "adapters/faber-elixir",
#     top: 3,
#     install: false
config :faber, :schedule, enabled: false

# Web dashboard (M6). No Ecto — the dashboard scans the filesystem read-only. Assets are
# vendored UMD builds (no esbuild/tailwind build step).
config :faber, FaberWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [html: FaberWeb.ErrorHTML], layout: false],
  pubsub_server: Faber.PubSub,
  live_view: [signing_salt: "Fb2xQ9pK"]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
