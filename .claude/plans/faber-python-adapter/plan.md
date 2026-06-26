# Plan — A1: `faber-python` adapter + domain-free detection (full scope)

**Date:** 2026-06-26
**Goal:** Prove Faber's engine is domain-free by standing up a **second adapter (`faber-python`)** that
generates, evals, **and detects** friction correctly — with **zero stack-specific `lib/faber` diffs**
(only *generic* engine mechanisms may change). Decisions locked: stack = **faber-python**; scope =
**full** (generation + eval + domain-free detection).

## Scoping findings (the "why")

Audited `lib/faber` for Elixir leaks. Eval is clean (generic matchers). Two leaks block a clean 2nd adapter:

- **Leak 1 (content, trivial):** `propose.ex:100` hardcodes an Elixir example in the system prompt
  (`"… with \`mix test path:line\`"`). Shows for every adapter.
- **Leak 2 (detection, the real work):** `Scan.run/1` is **not adapter-aware** — the adapter loads
  `detect/signatures.yaml` into the struct but the scan path ignores it. `detect.ex` hardcodes:
  - `fingerprint/1` bonuses: `["mix deps","mix hex"]`→maintenance, `["gh pr","gh issue"]`→review.
  - `opportunity/1`: maps friction → **plugin skill names** (`["mix test","mix compile"]`≥3→`verify`,
    `["gh pr"]`≥2→`pr-review`, >50 tools→`plan`, >10 edits→`review`, retry→`investigate`).
  - skill-usage extraction regex `~r/(?:phx|ecto|lv):/`.
  These are Elixir/plugin-specific baked into the engine. Friction *ranking* survives (signals are
  generic) but *fingerprint + opportunity* output is Elixir-only.

**Design principle:** the engine keeps its current built-ins as the **generic fallback** (no adapter
⇒ today's behavior, byte-for-byte), and an **optional adapter overrides** the command/skill vocab.
Backward-compatible; `faber-elixir` parity must not regress.

## Phase 0 — contract + generic engine (NO python yet)

- [x] **P0-T1** Extend `docs/ADAPTER_CONTRACT.md` §4 `detect/`: add `fingerprints` (command/keyword →
  type + weight) and `opportunities` (command-pattern + threshold → suggested skill name) sub-schemas,
  and a `skill_namespaces` list (replaces the `phx|ecto|lv` regex). Bump contract to v0.2 (§9), keep
  v0.1 packs valid (all new keys optional). — Added §4.1 + `metadata.example_step` (§3) + v0.2 note (§9).
- [x] **P0-T2** `Faber.Adapter`: parse the new `detect/` sub-sections into the struct
  (`fingerprint_rules`, `opportunity_rules`, `skill_namespaces`); default `[]`. Loader test. — `read_detect/1`
  reads the file once; `fingerprint_rule`/`opportunity_rule` parsers + light validation; 3 loader tests.
- [x] **P0-T3** Genericize **Leak 1**: add optional manifest field (e.g. `example_step`) the proposer
  injects; fall back to a stack-neutral phrasing ("Run the failing test in isolation"). `propose.ex`. —
  `example_step/1` reads `metadata.example_step`; faber-elixir manifest restates the `mix test path:line` example.
- [x] **P0-T4** Make detection adapter-driven (**Leak 2**): thread an optional `:adapter` through
  `Scan.run/1` → `Detect.fingerprint/2` + `Detect.opportunity/2`. When present, drive command-bonuses,
  opportunity rules, and skill-namespace extraction from the adapter; when absent, use the current
  hardcoded lists verbatim (extract them into named module attrs = the generic default). — Defaults in
  `@default_fingerprint_rules`/`@default_opportunity_rules`/`@default_skill_namespaces`; nil ⇒ defaults, adapter ⇒ its vocab.
- [x] **P0-T5** Migrate `faber-elixir`'s heuristics INTO `adapters/faber-elixir/detect/signatures.yaml`
  (mix/gh commands, the 5 opportunity→skill rules, `phx|ecto|lv` namespaces). Prove **parity**: the
  m2 native↔sidecar parity tests + scan ranking on the fixtures are unchanged. — Parity test asserts
  `fingerprint/opportunity(events, adapter) == (events)` across 9 probe sessions; `mix test.full` green.
- [x] **P0-T6** `mix test` + `mix test.full` green; `compile --warnings-as-errors`. Commit Phase 0
  (generic engine + contract v0.2) as its own unit — it stands alone, no python.

## Phase 1 — author the `faber-python` pack (pure declarative)

- [x] **P1-T1** `adapters/faber-python/faber.adapter.yaml` — `file_globs` (`**/*.py`, `pyproject.toml`,
  `requirements*.txt`, `setup.cfg`, `setup.py`), `agent_targets: [claude-code]`, `contract: 0.2`,
  `metadata.example_step` (`pytest -x path::test`).
- [x] **P1-T2** `laws/laws.yaml` — 15 PEP 8/idiom non-negotiables: type hints, no bare `except:`, no
  mutable default args, context managers, `pathlib`, comprehensions, `logging` not `print`, `is None`,
  no wildcard imports, f-strings, pinned venv deps, verify-before-done. (Hand-curated; sources in README.)
- [x] **P1-T3** `investigate/playbooks.yaml` — 7 playbooks: tracebacks bottom-up,
  `ImportError`/`ModuleNotFoundError`, venv/interpreter mismatch, `pytest -x --pdb` isolation,
  `ruff`/`mypy` triage, profile-before-optimize, bytes↔str.
- [x] **P1-T4** `detect/signatures.yaml` — 6 generic friction signals + python `fingerprints`
  (`pip`/`poetry`/`uv`→maintenance; `gh pr`→review) + `opportunities` (`pytest`/`ruff`/`mypy` ≥3 →
  `verify`) + `skill_namespaces: [py]` + `eval/eval.yaml` (vendored, structural+trigger).
- [x] **P1-T5** `templates/skill.md.tmpl` + `manifest.yaml` — Python idiom (frontmatter, Iron Laws,
  numbered Workflow, do/don't Patterns, ```python fenced example). Mirrors the faber-elixir gating fixes.
- [x] **P1-T6** `README.md` (main + per subdir) documenting the hand-curated, non-extracted provenance
  (PEP 8/257/484, stdlib + tool docs) — no single upstream plugin.

## Phase 2 — prove domain-independence + verify

- [x] **P2-T1** A python session **fixture** (`test/fixtures_python/python_session.jsonl` — isolated dir
  so it doesn't out-rank the Elixir fixtures in shared dir-scans) exhibiting friction (repeated `pytest`
  failures, `pip install` loops).
- [x] **P2-T2** Tests (`test/faber/faber_python_test.exs`, 7): `faber-python` loads; `matches_session?`
  matches the `.py` session not the elixir one; detect fingerprints it python-flavored via the adapter
  (maintenance vs bug-fix adapter-free); propose+eval produce a valid eval-passing python skill (Stub +
  native eval).
- [x] **P2-T3** **Zero-diff assertion:** `git diff <phase-0> -- lib/faber/ python/` is empty — adding
  faber-python required no engine/sidecar change. Documented in `adapters/faber-python/README.md`.
- [ ] **P2-T4** (optional, keyless) live propose — SKIPPED: Stub + native eval already prove the
  pipeline end-to-end; keyless `claude -p` run deferred (budget/time), not needed for the thesis.
- [x] **P2-T5** Updated `README.md` Status (two adapters; engine proven domain-free) + `HANDOFF.md`
  (§6 converse test + A1 milestone; note: HANDOFF.md is gitignored, edited locally only).
- [x] **P2-T6** Full verify: `mix test` 275 / `mix test.full` 280 / `format` / `compile
  --warnings-as-errors` all green. Commit per phase (Phase 0 = 183fb3a; Phase 1+2 = this commit).

## Risks

1. **Regressing `faber-elixir` detection** when moving heuristics to signatures (P0-T5). *Mitigation:*
   the m2 parity tests + fixture scan rankings are the guard; the no-adapter path stays byte-identical.
2. **Contract churn** (v0.1→v0.2). *Mitigation:* all new `detect/` keys optional; v0.1 packs unaffected.
3. **Hand-curated python knowledge** (no zero-diff upstream like the plugin). *Mitigation:* that's fine —
   the thesis is "engine domain-free", not "every adapter is auto-extracted"; document provenance.
4. **Opportunity→skill names** are agent/ecosystem-specific. *Mitigation:* make them pure adapter data;
   faber-python may legitimately have fewer/different opportunity rules.

## Definition of done

`adapters/faber-python/` generates + evals + detects friction for a python session, `faber-elixir`
behavior is unchanged, and the only `lib/faber` diffs are the **generic** adapter-awareness + the
prompt-example seam (provable by diff). Two adapters, one domain-free engine.
