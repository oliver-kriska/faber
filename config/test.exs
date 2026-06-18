import Config

# Tests never hit a live LLM: the stub returns deterministic structured proposals.
config :faber, :llm, Faber.LLM.Stub
