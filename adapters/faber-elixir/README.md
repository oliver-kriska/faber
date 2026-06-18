# faber-elixir — reference adapter

The flagship Faber adapter for **Elixir / Phoenix** projects, and the proof that the
adapter abstraction works: it is assembled by *referencing* the
[`claude-elixir-phoenix` plugin](../../HANDOFF.md) — Faber reads it; it never writes back
(the zero-diff premise, see `docs/ADAPTER_CONTRACT.md`).

## Layout

| Path | Role | Source in the plugin |
|---|---|---|
| `faber.adapter.yaml` | manifest | — |
| `detect/` | friction signatures | `session-*` skills, `compute-metrics.py` |
| `laws/` | Iron Laws → skill content + checks | `CLAUDE.md` Iron Laws section |
| `investigate/` | debugging playbooks | `investigate`, `n1-check`, `ecto-constraint-debug`, … |
| `eval/` | domain matchers + trigger fixtures | `lab/eval/` |
| `templates/` | skill/agent/hook scaffolds | plugin `skills/` & `agents/` structure |

**Status:** M0 skeleton — subdirectories carry placeholder READMEs describing what they
hold; M1 fills them. See each subdirectory's `README.md`.
