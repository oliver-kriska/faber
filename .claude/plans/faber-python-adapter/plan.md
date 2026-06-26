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

- [ ] **P0-T1** Extend `docs/ADAPTER_CONTRACT.md` §4 `detect/`: add `fingerprints` (command/keyword →
  type + weight) and `opportunities` (command-pattern + threshold → suggested skill name) sub-schemas,
  and a `skill_namespaces` list (replaces the `phx|ecto|lv` regex). Bump contract to v0.2 (§9), keep
  v0.1 packs valid (all new keys optional).
- [ ] **P0-T2** `Faber.Adapter`: parse the new `detect/` sub-sections into the struct
  (`fingerprint_rules`, `opportunity_rules`, `skill_namespaces`); default `[]`. Loader test.
- [ ] **P0-T3** Genericize **Leak 1**: add optional manifest field (e.g. `example_step`) the proposer
  injects; fall back to a stack-neutral phrasing ("Run the failing test in isolation"). `propose.ex`.
- [ ] **P0-T4** Make detection adapter-driven (**Leak 2**): thread an optional `:adapter` through
  `Scan.run/1` → `Detect.fingerprint/2` + `Detect.opportunity/2`. When present, drive command-bonuses,
  opportunity rules, and skill-namespace extraction from the adapter; when absent, use the current
  hardcoded lists verbatim (extract them into named module attrs = the generic default).
- [ ] **P0-T5** Migrate `faber-elixir`'s heuristics INTO `adapters/faber-elixir/detect/signatures.yaml`
  (mix/gh commands, the 5 opportunity→skill rules, `phx|ecto|lv` namespaces). Prove **parity**: the
  m2 native↔sidecar parity tests + scan ranking on the fixtures are unchanged.
- [ ] **P0-T6** `mix test` + `mix test.full` green; `compile --warnings-as-errors`. Commit Phase 0
  (generic engine + contract v0.2) as its own unit — it stands alone, no python.

## Phase 1 — author the `faber-python` pack (pure declarative)

- [ ] **P1-T1** `adapters/faber-python/faber.adapter.yaml` — `file_globs` (`**/*.py`, `pyproject.toml`,
  `requirements*.txt`, `setup.cfg`), `agent_targets: [claude-code]`, `example_step` (e.g. `pytest -x
  path::test`).
- [ ] **P1-T2** `laws/laws.yaml` — PEP 8/duck-typing non-negotiables: type hints on public fns, no bare
  `except:`, no mutable default args, `pathlib` over `os.path`, context managers for resources,
  prefer comprehensions, `logging` not `print`. (Hand-curated; cite sources in README.)
- [ ] **P1-T3** `investigate/playbooks.yaml` — `ImportError`/`ModuleNotFoundError`, reading tracebacks
  bottom-up, `pytest -x --pdb`, venv/interpreter mismatch, `ruff`/`mypy` triage.
- [ ] **P1-T4** `detect/signatures.yaml` — generic friction signals + python `fingerprints`
  (`pip install`/`poetry add`/`uv add`→maintenance; `gh pr`→review stays generic) + `opportunities`
  (`pytest` fails ≥3 → a python verify-style skill) + `skill_namespaces` (the user's python skill ns,
  if any) + an `eval/eval.yaml` (native default to start).
- [ ] **P1-T5** `templates/skill.md.tmpl` + `manifest.yaml` — Python idiom (frontmatter, Iron Laws,
  numbered Workflow, do/don't Patterns, ```python fenced example). Mirror the faber-elixir gating fixes.
- [ ] **P1-T6** `README.md` per subdir documenting the (hand-curated, non-extracted) provenance — unlike
  faber-elixir there's no single upstream plugin; note the sources used.

## Phase 2 — prove domain-independence + verify

- [ ] **P2-T1** A python session **fixture** (`test/fixtures/python_session.jsonl`) exhibiting friction
  (repeated `pytest` failures, `pip install` loops) for deterministic detect/scan tests.
- [ ] **P2-T2** Tests: `faber-python` loads; `Adapter.matches_session?` matches a `.py` session, not the
  elixir one; detect fingerprints the python fixture as python-flavored via the adapter; propose+eval
  produce a valid, eval-passing python skill (Stub + the native eval).
- [ ] **P2-T3** **Zero-diff assertion:** confirm adding `faber-python` required *no* python-specific
  `lib/faber` change beyond Phase 0's generic mechanisms (grep the diff; document in the adapter README).
- [ ] **P2-T4** (optional, keyless) live propose with `faber-python` on the fixture via `claude -p` to
  eyeball a real python skill.
- [ ] **P2-T5** Update `README.md` Status (two adapters; engine proven domain-free) + `HANDOFF.md`.
- [ ] **P2-T6** Full verify (`mix test` / `test.full` / format / compile) + commit per phase.

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
