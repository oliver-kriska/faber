# `detect/` — friction signatures + detection vocab

`signatures:` documents the engine's generic friction model (retry loops, corrections, error
ratio, approach changes, compactions, interrupts) with Python-flavored examples — these are
agent-level signals, identical across stacks.

The contract §4.1 keys are what make detection **Python-flavored**:

- `fingerprints` — `pip`/`poetry`/`uv` install → `maintenance`; `gh pr`/`issue` → `review`.
- `opportunities` — repeated `pytest`/`ruff`/`mypy` → `verify`; plus the generic
  retry→`investigate`, many-tools→`plan`, `gh pr`→`pr-review`, many-edits→`review`.
- `skill_namespaces` — `["py"]` (a placeholder for a `py:`-namespaced skill pack), in contrast
  to faber-elixir's `phx|ecto|lv`.

Without these keys the engine would fall back to its Elixir/plugin defaults; supplying them is
how the same engine fingerprints a Python session as Python. **No host-language code.**
