# Review — faber-python adapter + domain-free detection

**Scope:** `git diff 183fb3a^ HEAD` — the two commits (Phase 0 `183fb3a` + Phase 1+2 `07c364b`),
27 files, +1420/−89. Engine: `detect.ex`, `adapter.ex`, `propose.ex`, `scan.ex`. Pack:
`adapters/faber-python/`. Tests: 4 files + fixture. Docs: contract v0.2, README.

**Verdict: ✅ PASS WITH WARNINGS** — 0 blockers, 0 Iron Law violations, full suite green. Six
non-blocking findings (1 security-medium, 1 idiom-warning, 4 test-quality), all optional polish.

> **RESOLVED (follow-up commit).** All findings W1–W6 + S1–S2 addressed. Empirical note on W1:
> with `Regex.escape` applied, `Regex.compile!` does **not** actually raise on malformed UTF-8 /
> NUL string input (Elixir's default regex mode accepts them), so the crash vector was largely
> theoretical for *string* namespaces. The genuine edge — a **non-binary** namespace making
> `Regex.escape` raise — is now handled both at load (`Adapter.validate/1` rejects
> non-compilable `skill_namespaces`/`file_globs`) and at runtime (`skill_namespace_regex/1`
> filters non-binaries and fails closed to a never-match regex). New tests cover both paths.
> Suite after fixes: `mix test` 277 / `mix test.full` 282, format + compile clean.

---

## Requirements Coverage (REQ_SOURCE: plan faber-python-adapter)

**14 MET · 2 PARTIAL · 1 UNCLEAR · 1 DEFERRED — no genuine gaps.**

- Every Phase 0/1/2 deliverable is present in the diff: contract v0.2 (§4.1 keys + §3
  `example_step` + §9 note), the three new `Adapter` struct fields, `Detect.fingerprint/2` +
  `opportunity/2` with the nil-default parity path, `Scan` `:adapter` threading, the
  `example_step/1` seam, the migrated `faber-elixir` heuristics, the parity describe block, the
  full `faber-python` pack, the 7-test integration file, and the zero-diff documentation.
- **2 PARTIAL** (P1-T2 laws, P1-T3 playbooks) are **grep artifacts** — the files exist with the
  right content (134-line laws.yaml; 7 playbooks); the verifier's count check was a tooling
  limitation, not a missing deliverable.
- **1 UNCLEAR** (P2-T6 test counts) — not confirmable from a static diff, but the
  verification-runner independently **confirmed live: 275 / 280 passed**.
- **1 DEFERRED** (P2-T4 optional keyless live propose) — intentional, not a gap.

## Verification (live run)

| Command | Result |
|---|---|
| `mix format --check-formatted` | ✅ OK |
| `mix compile --warnings-as-errors` | ✅ OK |
| `mix test` | ✅ 275 passed, 7 excluded |
| `mix test.full` (incl. native↔sidecar parity) | ✅ 280 passed, 2 excluded |

Credo / Dialyzer / Sobelow are not configured in this project (expected). The
`faber schedule: run #1 crashed — :killed` log line is a pre-existing intentional kill test.

---

## Findings

### Blockers
None.

### Warnings

**W1 — [security, Medium] `Regex.compile!` from adapter data can raise mid-scan.**
`Faber.Detect.skill_namespace_regex/1` (detect.ex:580-581, **new**) builds
`Regex.compile!("(?:#{alt}):…", "i")` from adapter `skill_namespaces`. `Adapter.validate/1`
only checks "list of strings" — a pack with malformed UTF-8 / a NUL byte makes `compile!`
**raise during a scan** instead of being rejected at `load/1`. `Regex.escape/1` *is* applied
(no metachar injection — confirmed), so this is a robustness/DoS-fail-open gap, not code-exec.
The same class exists in `Adapter.glob_regex/1` (adapter.ex:158, **pre-existing**, out of this
diff). Real-world severity is low today (packs are local, trusted repo files) but the contract
envisions community packs. *Fix:* use `Regex.compile/2` failing closed to a never-match regex,
and add a compile check in `validate/1` so bad packs fail at load.

**W2 — [idiom] vocab accessors use `Map.get/3 || []` on a struct.**
`fingerprint_rules/1`, `opportunity_rules/1`, `skill_namespaces/1` (detect.ex) do
`Map.get(adapter, :field) || []`. Correct in practice (the struct default is `[]`), but it
obscures the nil-vs-empty distinction and defeats the compiler's struct-field checker. *Fix:*
add a `%Faber.Adapter{field: v}` pattern-matched clause beside the existing `nil` clause and
drop the `Map.get` fallback.

**W3 — [test] parity test compares two live calls.**
`detect_test.exs` "faber-elixir adapter parity" asserts
`Detect.fingerprint(events, adapter) == Detect.fingerprint(events)`. This guards adapter↔default
**divergence** (valuable) but not a **joint regression** (both paths breaking identically stays
green). *Partially mitigated* — `faber_python_test.exs` and the "adapter-driven" block do carry
absolute snapshots (`%{type: "maintenance"}`). *Fix:* add one snapshot assertion to a probe in
the parity block too.

**W4 — [test] redundant hardcoded fixture-path equality.**
`faber_python_test.exs:47` `assert paths == ["/Users/x/Projects/pyapp/src/parser.py"]` couples
the test to exact fixture content; the behavioral claim is already proven by the two
`matches_session?` assertions that follow. *Fix:* drop the equality assert.

**W5 — [test] fragile count assertions.**
`faber_python_test.exs:31-32` `length(py.laws) == 15` / `length(py.playbooks) == 7` break on any
pack addition. *Fix:* assert a specific known entry (id/skill) instead of (or alongside) counts.

**W6 — [test] `verify.unless_used` default not directly asserted.**
The `verify` opportunity rule omits `unless_used` in YAML and defaults to `true` — a meaningful
contract guarantee that is never directly tested for that rule.

### Suggestions

- **S1 — [security, Low]** ReDoS on adapter namespace alternation — pattern shape isn't
  catastrophic (no nested quantifier); only cap `skill_namespaces` length if packs ever arrive
  over a network.
- **S2 — [test]** `propose_test.exs:297` uses relative `"adapters/faber-elixir"`; the rest of
  the suite uses `Path.expand(…, __DIR__)` — make it consistent.

---

## Notes

- **Design points confirmed correct** by elixir-reviewer: `Map.update` (not `update!`) for novel
  adapter fingerprint types; the deterministic tie-break (`@fingerprint_order ++ Enum.sort(extra)`)
  with full parity; the `unless_used` guard semantics with `investigate: false` as an explicit
  decision.
- **Privacy moat intact** (security-analyzer): no new `Logger`/`IO.inspect` in `detect.ex`;
  everything returned is aggregates (counts/scores/short skill names), never raw transcript text
  or internal paths.
- **W1 + W2** are the same root theme the codebase already values: validate adapter packs at the
  boundary (`load/1`) rather than trusting them downstream.
