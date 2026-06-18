import Config

# LLM client for the skill proposer (M3). Override the model per provider; a live call needs
# the provider API key in the environment (e.g. ANTHROPIC_API_KEY).
config :faber, :llm, Faber.LLM.ReqLLM
config :faber, :llm_model, "anthropic:claude-sonnet-4-6"

# Python eval sidecar (M4): interpreter + package dir. uv is optional; plain python3 works
# because the sidecar is stdlib + PyYAML only.
config :faber, :python, System.get_env("FABER_PYTHON", "python3")

import_config "#{config_env()}.exs"
