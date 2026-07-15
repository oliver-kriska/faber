import Config

# Tests never hit a live LLM: the stub returns deterministic structured proposals.
config :faber, :llm, Faber.LLM.Stub

# The dashboard scans the committed fixtures (fast, deterministic) instead of the real
# ~/.claude history, so the LiveView test is hermetic.
config :faber, :dashboard_scan_opts, base: "test/fixtures", min_messages: 0

# The scan cache is a VM-global ETS table, so leaving it on would silently couple every async test
# that scans. It buys nothing here either — the fixture corpus is tiny. `Faber.Scan.Cache`'s own
# tests turn it back on explicitly against a tmp dir. Off by default keeps the rest of the suite
# scoring from source, exactly as it did before the cache existed.
config :faber, :scan_cache, false

# Same reasoning for the proposal store: persisting to a fixed dir is global state, and the async
# dashboard tests drive the propose path. Left on, one test's stored proposal would surface in
# another's render depending on ordering. `Faber.ProposalStoreTest` turns it on against a tmp dir.
config :faber, :proposal_store, false

# Faber's state dir, redirected so no test can touch the developer's real ~/.faber. Individual
# tests override it per-case; this is the backstop if one forgets.
config :faber, :home_dir, Path.expand("../tmp/faber_test_home", __DIR__)

# Skills dir, redirected the same way: the dashboard reads it on mount (to show which sessions
# already have a Faber skill installed), so an unredirected default would read the developer's real
# ~/.claude/skills. Empty by default ⇒ no session reads as installed. The installed-marker test
# points this at a seeded tmp dir per-case.
config :faber, :skills_dir, Path.expand("../tmp/faber_test_skills", __DIR__)

# Endpoint runs without binding a port; Phoenix.LiveViewTest drives it in-process.
config :faber, FaberWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "kZ3pQ7mN1rT5wY9bD2fH6jL0sV4xC8aE3gI7kM1oQ5uW9yA2cF6hJ0lN4pR8tX2zB6testTST",
  server: false

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
