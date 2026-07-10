# Faber — Project Health Audit (2026-07-10)

**Scope:** whole-app correctness, simplicity, and efficiency review of all Elixir modules
(57 files, ~9,000 LOC). Follow-up to the 2026-06-26 architecture review
(`.claude/plans/review/reviews/architecture-review.md`).
**Method:** 5 parallel specialists (architecture, idioms/correctness, OTP, performance, tests),
each seeded with the prior review to verify fixed-vs-open and hunt only new issues. Key findings
re-verified against source by the synthesizer.
**Baseline:** `mix compile --warnings-as-errors` clean; `mix test` 372 passed / 0 failed.

> **Remediation (same day, commits e5cd183…b26104d):** all 7 new findings, all still-open prior
> findings, all 4 suggestions, and the untested error branches were fixed across 12 verified
> commits — every bug fix started from a red test reproducing the finding. Per-finding status
> is annotated inline below. Final state: `mix test` 396 passed, `mix test.full` 409 passed,
> `mix test.live` (real `claude -p` end-to-end) 397 passed, `--warnings-as-errors` clean.

## Verdict: ✅ SOUND — one real correctness bug, one real OOM vector, otherwise polish

| Category | Score | Grade | Notes |
|---|---|---|---|
| Architecture | 85 | B+ | DAG shape intact (5 benign runtime cycles, 0 compile cycles); loop.ex cohesion drift |
| Correctness/Idioms | 82 | B | 1 new bug (ignored `Git.commit` failure); new O(n²) in consolidate |
| OTP/Processes | 90 | A- | 1 warning (CLI dispatch exit-passthrough); wedge guard empirically verified |
| Performance | 78 | B- | OpenCode unbounded DB read; reflect+trigger doubles LLM spend |
| Tests | 90 | A- | 372 hermetic tests, behavior doubles not mocks; a few error branches uncovered |
| **Overall** | **85** | **B+** | |

Full per-dimension reports: `.claude/audit/reports/{arch-review,idioms-review,otp-review,perf-audit,test-audit}.md`

---

## Status of the 2026-06-26 review findings

**Fixed since then (6):**
- `/mcp` CSRF/DNS-rebind — `check_origin` pinned to loopback (`runtime.exs:42`).
- Dashboard `propose` event — server-side `allow_propose?/0` gate added.
- Float `==` cross-runtime assert → fixed.
- Gemini `Scan.run/1` e2e test → added.
- `ReqLLM` zero hermetic coverage → fixed.
- Subprocess timeouts for every external binary → `Faber.Subprocess` added and threaded through
  claude_cli/sidecar/ccrider/git (closes a real robustness gap).

**Still open (unchanged at audit time — ALL FIXED in the remediation):** `Loop.Server` bare
linked `Task.async` (Theme 3 — see below) → fixed (commit 6); Elixir-flavored engine defaults in
`detect.ex:85-107` (Theme 1) → fixed, defaults neutralized + `tools:` vocab (commit 11);
`adapter.ex:346` `acc ++` O(n²) → fixed (commit 5); `eval.ex:91-92` double `adapter_eval` →
fixed (commit 5); `cli.ex:173` bare `spawn` → `Task.start` (commit 2); `detect.ex` 724-LOC split
→ done, facade + 4 domain modules (commit 10). `ccrider.ex:49` SQL interpolation stays accepted
as-is (documented out of scope).

---

## New findings (ranked)

### 1. ✅ FIXED (e5cd183) — `Loop.keep/5` discards `Git.commit/3` failure → in-memory best diverges from disk — `lib/faber/loop.ex:209` *(verified)*

> Fixed as planned: failed commit routes to `reject/6`; `Git.commit/3` treats byte-identical
> keeps as a successful no-op (`git diff --quiet --cached`) and `git reset`s the stage on
> failure so revert-from-index restores HEAD content (a second bug the red test exposed).
> Regression tests: failed-commit keep + identical-content keep in `loop_test.exs`.

`Git.commit/3` returns `:ok | {:error, term()}`; `keep/5` ignores it. The git-mode invariant
("HEAD always holds the current best skill", `git.ex` moduledoc) breaks silently on any commit
failure (lock contention, timeout, hook, nothing-to-commit): the working tree holds the new
content, `state.best_content`/`best_composite` record it as kept, but HEAD does not advance. The
next `reject/5` runs `git checkout --`, silently restoring stale HEAD content to disk while state
still claims the newer content — final artifact on disk ≠ `state.best_content`, no error surfaced.
**Fix:** treat a failed commit as a failed keep (route to `reject/5` with
`"commit failed: #{inspect(reason)}"`); concrete patch in `idioms-review.md`.

### 2. ✅ FIXED (a958369) — OpenCode ingest reads the ENTIRE DB into memory: no size cap, no session scoping — `lib/faber/ingest/format/opencode.ex:54,69,86-120`

> Fixed as planned: per-session pseudo-path handles (`<db>#<session_id>`) from `discover/1`,
> `WHERE m.session_id = …` scoping, 50 MB output cap failing closed, degraded whole-DB handle
> only when `sqlite3` is missing. `Scan.run` now yields one Result per OpenCode session.

`discover/1` yields one handle (the whole DB); `@query` joins all sessions/messages/parts with no
LIMIT; `Subprocess.run(sqlite3 -json …)` buffers the full stdout as one binary, then decodes it
whole. The size-cap sweep (commit 282a497) covered 4/5 formats — OpenCode is the gap, and it's the
highest-volume read (a multi-hundred-MB DB can balloon to GBs of JSON in RAM → realistic OOM).
Side effect: the whole OpenCode history scores as a *single session*, defeating the
`Task.async_stream` fan-out. **Fix:** one handle per session (`SELECT id FROM session`) +
`WHERE m.session_id = …`, exactly as `Source.Ccrider` already does; stopgap: byte-cap the payload
so it fails closed like cline/gemini.

### 3. ✅ FIXED (573b076) — `:reflect` + `trigger: true` re-scores the unchanged best every iteration → ~2× LLM spend — `lib/faber/loop.ex:477-500,547-557`

> Fixed as planned: `State.best_eval` caches the best's full eval (seeded in `init`, refreshed
> on keep via the new `{:ok, comp, meta}` eval_fn 3-tuple, backward compatible); reflect
> feedback reads the cache. Count-based regression test pins N+1 evals (was 2N+1).

`reflection_feedback/3` calls `Eval.score/2` on the current best each iteration to derive
weakest-dimension feedback; with trigger enabled that's `trigger_samples` (3) × fixtures real LLM
calls per iteration for content that only changes on a keep — over a 50-iteration plateau, dozens
to hundreds of avoidable model calls. **Fix:** cache the best's eval `dimensions` on `State`
(set in `init/1` and `keep/5`), read the cache in `reflection_feedback`.

### 4. ✅ FIXED (3fce23c) — `Loop.Server` shutdown can still interrupt a git commit; no wedge guard — `lib/faber/loop/server.ex:46`

Unchanged from Theme 3 of the prior review, sharper now: the crash-propagation design is fine and
documented (OTP auditor concurs), but on supervisor shutdown the linked task dies mid-run —
possibly mid `git commit` (dirty index, half-written journal). And unlike `Faber.Schedule`
(`schedule.ex:150-211`), which now implements the exact needed pattern
(`Task.Supervisor.async_nolink` + `:run_deadline` wedge guard + `:DOWN` handling — empirically
verified by `schedule_test.exs:187-217`), `Loop.Server` has no runaway kill switch at all
(`await` defaults to `:infinity`). **Fix:** copy the `Schedule` pattern; the reference
implementation is in the same lib tree.

> Fixed as planned: `Task.Supervisor.async_nolink` under a new `Faber.Loop.TaskSupervisor`,
> `:DOWN` → `:crashed` terminal state replied to waiters, optional `:max_run_ms` deadline with
> the completed-vs-stale-ref race handling. Crash/timeout/wedge tests added.

### 5. ✅ FIXED (b981cbb) — CLI dispatch catches raises but not exits/throws — `lib/faber/cli.ex:170-185`

`Faber.Subprocess` deliberately re-raises abnormal task exits via `exit(reason)`; `dispatch/1`
only `rescue`s. An escaped exit means `System.halt/1` never runs — a scripted `faber scan` hangs
instead of exiting non-zero. **Fix:** add `catch kind, reason` alongside the `rescue`.

> Fixed as planned: dispatch body extracted into public `guarded/1` with `rescue` + `catch
> kind, reason` (unit-tested for raise/exit/throw → status 1); bare `spawn` → `Task.start`.

### 6. ✅ FIXED (5239961) — `Consolidate.cluster/2` rebuilds the whole cluster list per proposal (O(n²) `++` in reduce) — `lib/faber/consolidate.ex:51-58`

New code reintroducing the exact anti-pattern still open in `adapter.ex:346`. Small inputs today;
fix now before it's copied again (find-or-append via `Enum.find_index` + `List.update_at`, or a
map accumulator; patch in `idioms-review.md`).

> Fixed as planned (find-or-place + prepend-then-reverse, deterministic output preserved);
> same commit fixed `adapter.ex` `validate_entries` prepend and the `eval.ex` double
> `adapter_eval` bind.

### 7. ✅ FIXED (7137369) — `Faber.Feedback` duplicates `Install`'s `.faber.json` marker convention — `lib/faber/feedback.ex:100-110` vs `lib/faber/install.ex:168-170`

Two modules independently hardcode the marker filename + dirname relationship. If `Install` ever
moves the marker, `Feedback` silently degrades to its "count every session" fallback — a quiet
correctness regression no test would catch. **Fix:** public `Faber.Install.installed_at/1`;
`Feedback` calls it (also dedupes the Jason/DateTime parsing). — *Fixed as planned, including
the cross-module test (Feedback reads the timestamp Install actually wrote).*

### Suggestions (simplicity/structure) — all done in the remediation

- ✅ **`loop.ex` cohesion drift (276→582 LOC)** → `Faber.Loop.Reflect` extracted (commit 9,
  60d3525), wired to the `best_eval` cache from finding 3.
- ✅ **`Consolidate` has no entry point** → `faber consolidate` CLI command (commit 12,
  b26104d): scan → propose top-N → cluster → gated merge, one line per outcome; GUIDE §11.
- ✅ **Detect recomputes shared intermediates** → `Detect.analyze/2` single-pass + the
  detect.ex split into `Detect.{Friction,Fingerprint,Opportunity,Context}` behind a facade
  (commit 10, cc5d177); `Scan.score_session` uses it.
- ✅ **Untested error branches** → covered (commit 8, 607c6f9): schedule deadline-race +
  stale-ref (deterministic via `:sys.suspend` + gated LLM double), feedback `:low_usage` +
  vanished-transcript fallback, `attach_holdout` error branch, and a `runtime.exs` regression
  test pinning `check_origin` to loopback.

### Cleared (empirically, not by inspection)

- `Subprocess`'s `Task.yield || Task.shutdown(:brutal_kill)` timeout contract reproduced correct
  in a live `elixir` session (OTP auditor).
- `Schedule`'s wedge guard proven by a real hung-job test (`schedule_test.exs:187-217`).
- No over-mocking, no `Process.sleep`, behavior doubles drive real pipeline code; `async: true`
  default with justified exceptions.
- Whole-tree sweeps for `Enum.reduce`+`++`, broad rescues, and dynamic `String.to_atom` found
  nothing beyond the items above.

---

## Suggested order of attention — ✅ all completed (2026-07-10, commits e5cd183…b26104d)

1. ✅ **`keep/5` commit-failure handling** (finding 1) — the one real correctness bug; small patch.
2. ✅ **OpenCode per-session scoping** (finding 2) — real OOM vector + restores fan-out; the
   ccrider pattern to copy already exists.
3. ✅ **Best-eval caching in reflect mode** (finding 3) — direct token-cost reduction on every
   refine run.
4. ✅ **`Loop.Server` → Schedule pattern + CLI `catch`** (findings 4, 5) — robustness pair.
5. ✅ Batch the small stuff: consolidate/adapter `++` fixes, `Install.installed_at/1`,
   `eval.ex` double-call, `Task.start` swap — plus the four untested error branches.
6. ✅ Longer-term: extract `Loop.Reflect`, neutralize the engine's Elixir-flavored defaults
   (prior Theme 1 — closed: neutral defaults + contract §4.1 `tools:` vocab, Tidewave moved to
   the pack, adapter-selected outputs verified byte-identical), split `detect.ex`.
