# The `:sidecar` tests shell out to python3 (the eval sidecar) for native↔Python parity; the
# `:ccrider` tests shell out to the sqlite3 CLI to read a fixture ccrider DB. Both are excluded from
# the default run so `mix test` is hermetic (no interpreter/CLI required); run them with
# `mix test.full` (alias for `mix test --include sidecar --include ccrider`) in CI.
#
# `:live` shells out to the local `claude -p` CLI and makes a REAL model call (your Claude Code
# subscription, no API key) — slow and non-hermetic, so it's excluded from both `mix test` and
# `mix test.full`. Run it explicitly with `mix test.live` (alias for `--include live`).
ExUnit.configure(exclude: [:sidecar, :ccrider, :live])
ExUnit.start()
