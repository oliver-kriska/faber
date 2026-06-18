# faber-elixir — reference adapter

The flagship Faber adapter for **Elixir / Phoenix** projects, and the proof that the
adapter abstraction works: it is assembled by *referencing* the
[`claude-elixir-phoenix` plugin](../../HANDOFF.md) — Faber reads it; it never writes back
(the zero-diff premise, see `docs/ADAPTER_CONTRACT.md`).

## Layout

| Path | Role | Source in the plugin |
|---|---|---|
| `faber.adapter.yaml` | manifest | — |
| `detect/signatures.yaml` | 6 friction signatures | `session-scan` scoring-guide / `compute-metrics.py` |
| `laws/laws.yaml` | 26 Iron Laws | `CLAUDE.md` "Iron Laws Enforcement" section |
| `investigate/playbooks.yaml` | 6 debugging playbooks | `investigate`, `n1-check`, `ecto-constraint-debug`, `call-tracing`, `narrow-bare-rescue`, `perf` |
| `eval/eval.yaml` | eval reference (**exec-in-place**) | `lab/eval/` (run rooted at the plugin) |
| `templates/skill.md.tmpl` + `manifest.yaml` | skill scaffold | plugin `skills/` structure |

**Status:** M1 populated — every subdirectory carries its extracted content (bulk form per
`ADAPTER_CONTRACT.md` §5.1), assembled **by reference** with zero diffs to the plugin. See
`EXTRACTION_PROBE.md` for the entanglement findings and why `eval/` is exec-in-place. Each
subdirectory's `README.md` describes the contract for that stage.
