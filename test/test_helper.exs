# The `:sidecar` tests shell out to python3 (the eval sidecar) for native↔Python parity. They are
# excluded from the default run so `mix test` is hermetic (no interpreter required); run them with
# `mix test.full` (alias for `mix test --include sidecar`) in CI to catch engine drift.
ExUnit.configure(exclude: [:sidecar])
ExUnit.start()
