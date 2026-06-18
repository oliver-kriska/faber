# faber-elixir — Extraction Probe (M1 start)

> Does the central premise hold: can `faber-elixir` be assembled **purely by referencing**
> the `claude-elixir-phoenix` plugin, with **zero diffs** to the plugin repo?
>
> **Verdict: the zero-diff premise HOLDS.** Nothing in any of the five subdirectories
> requires editing the plugin. But "by referencing" splits into two regimes — four
> subdirectories reference *content* cleanly; `eval/` must reference an *executable package
> in place* rather than vendoring individual files. That is a contract refinement (§7
> below), not a violation of the premise.

Probed against `/Users/oliverkriska/Projects/elixir-live-claude-engineer` on 2026-06-18.
No files in the plugin repo were modified.

## Source-by-source findings

### `laws/` ← Iron Laws — **clean (content reference)**

- **Source:** the "Iron Laws Enforcement" section of the plugin's `CLAUDE.md` (26 laws:
  LiveView / Ecto / Oban / Security / OTP / Verification / Code Style).
- **Coupling:** none structural. The laws are a cleanly delineated prose section.
- **Entanglement (minor):** they are *not a standalone artifact* — they live inside a
  ~36 KB `CLAUDE.md`, and a **second representation** is injected at runtime via the
  plugin's `SubagentStart` hook. Extraction picks one source of truth (the `CLAUDE.md`
  section) and splits it into per-law files. No plugin edit required.

### `detect/` ← `session-*` skills + `compute-metrics.py` — **clean (content reference)**

- **Source:** `.claude/skills/session-scan|session-deep-dive|session-trends` (each a
  self-contained `SKILL.md` + `references/`), plus `references/compute-metrics.py`
  (friction / opportunity / fingerprint scoring).
- **Coupling:** self-contained. `session-scan/SKILL.md` references its script by a
  *relative* glob (`**/session-scan/references/compute-metrics.py`); no absolute or
  plugin-internal paths.
- **Entanglement (runtime dep, not structural):** the skills require the **ccrider MCP**
  for session discovery. Faber would carry that same external dependency. No plugin edit.

### `investigate/` ← investigation skills — **clean (content reference)**

- **Source:** `investigate`, `ecto-constraint-debug`, `n1-check`, `call-tracing`,
  `narrow-bare-rescue`, `perf` (all under `plugins/elixir-phoenix/skills/`).
- **Coupling:** prose playbooks; referenceable as content. No plugin edit.

### `templates/` ← plugin `skills/` & `agents/` structure — **clean (content reference)**

- **Source:** the shape of the plugin's own `SKILL.md` / agent / hook files.
- **Coupling:** these are conventions to mirror, not files to import. No plugin edit.

### `eval/` ← `lab/eval/` — **ENTANGLED: needs exec-in-place, not file vendoring**

This is the one real finding. The Python eval code **cannot be lifted file-by-file**:

1. **Package-relative imports.** `scorer.py` does `from lab.eval.schemas import …` and
   `from lab.eval.dimensions import …`; `trigger_scorer.py` does
   `from lab.eval.matchers import …` and `from lab.eval.triggers.deviation_classifier
   import …`. Pulling `matchers.py` out drags the whole `lab.eval` package
   (`schemas.py`, `dimensions/`, `triggers/`).
2. **`__file__`-relative hardcoded paths.** `matchers.py` and `scorer.py` compute
   `PLUGIN_ROOT = …/plugins/elixir-phoenix` and read `evals/` relative to their own
   on-disk location — they **assume they live inside the plugin repo tree**.
3. **Run rooted at the repo.** `run_eval.sh` does `cd "$PROJECT_ROOT"` then
   `python3 -m lab.eval.scorer`. It only works with cwd = plugin repo root. (`lab/` has
   no `__init__.py`; it resolves as a module run from the root.)

**Consequence:** vendoring `eval/` into the adapter would require *patching* those import
roots and `__file__` paths — i.e. a maintenance fork of the plugin's eval framework. That
does not edit the plugin, but it abandons "referencing." The clean alternative that keeps
both *zero-diff* and *referencing* is to **run the upstream eval package in place**: the
adapter manifest points Faber's sidecar at the plugin repo as the eval root and invokes
`python3 -m lab.eval.scorer` there.

## Contract refinement this implies (for M1 proper)

`docs/ADAPTER_CONTRACT.md` §7 currently assumes `eval/` holds matcher/fixture files. Add a
second, declared **eval reference mode** so an adapter can reference an external eval
package instead of vendoring it:

```yaml
# in eval/eval.yaml (proposed)
mode: exec-in-place            # vs the default: vendored
root: "${source_repo}"         # cwd / PYTHONPATH for the run
entrypoint: "python3 -m lab.eval.scorer"
trigger_entrypoint: "python3 -m lab.eval.trigger_scorer"
requirements: ["PyYAML>=6.0.3,<7.0"]
```

- `mode: vendored` (default) — matcher/fixture files live in `eval/`, run by the sidecar.
  Right for new adapters authored from scratch.
- `mode: exec-in-place` — the sidecar shells out to `entrypoint` with cwd/PYTHONPATH =
  `root`. Right for referencing an existing, repo-rooted eval framework like the plugin's.
  Keeps the plugin at zero diffs and avoids a fork.

## Bottom line

| Subdir | Reference regime | Plugin edit needed? |
|---|---|---|
| `laws/` | content (split one CLAUDE.md section) | no |
| `detect/` | content (+ ccrider runtime dep) | no |
| `investigate/` | content | no |
| `templates/` | content (mirror conventions) | no |
| `eval/` | **exec-in-place** (package is repo-rooted) | no |

The extraction premise **holds**: `faber-elixir` is buildable with zero diffs to the
plugin. The only adjustment is recognizing that the eval framework is referenced as a
*runnable package rooted at the plugin*, not as loose files — which the contract should
make a first-class mode rather than an exception.
