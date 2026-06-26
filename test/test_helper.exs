# The `:sidecar` tests shell out to python3 (the eval sidecar) for native↔Python parity; the
# `:ccrider` and `:opencode` tests shell out to the sqlite3 CLI to read a fixture SQLite DB (ccrider's
# session index / an OpenCode `opencode.db`). All are excluded from the default run so `mix test` is
# hermetic (no interpreter/CLI required); run them with `mix test.full` (alias for `mix test --include
# sidecar --include ccrider --include opencode`) in CI.
#
# `:live` shells out to the local `claude -p` CLI and makes a REAL model call (your Claude Code
# subscription, no API key) — slow and non-hermetic, so it's excluded from both `mix test` and
# `mix test.full`. Run it explicitly with `mix test.live` (alias for `--include live`).
#
# `:live_api` calls the real Anthropic API via the ReqLLM backend — it costs money and needs a key,
# so it's excluded from everything above too. Run it with the env loaded:
#   set -a; . ./.env; set +a   &&   mix test.live.api   (alias for `--include live_api`)
ExUnit.configure(exclude: [:sidecar, :ccrider, :opencode, :live, :live_api])
ExUnit.start()
