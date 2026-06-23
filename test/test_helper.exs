# The `:sidecar` tests shell out to python3 (the eval sidecar) for native↔Python parity; the
# `:ccrider` tests shell out to the sqlite3 CLI to read a fixture ccrider DB. Both are excluded from
# the default run so `mix test` is hermetic (no interpreter/CLI required); run them with
# `mix test.full` (alias for `mix test --include sidecar --include ccrider`) in CI.
ExUnit.configure(exclude: [:sidecar, :ccrider])
ExUnit.start()
