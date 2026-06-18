# Faber M3–M6 — Consolidated Review

**Scope:** M3–M6 diff (`e1db06c..HEAD`) — 54 files, +3,855 lines. Skill proposer (M3),
eval gate + native/sidecar engines (M4), self-improving loop (M5), LiveView dashboard (M6),
plus the keyless `claude -p` backend and the development-findings work.

**Agents:** elixir-reviewer · otp-advisor · liveview-architect · security-analyzer ·
testing-reviewer · iron-law-judge · verification-runner · requirements-verifier (8/8 completed).

---

## Verdict: ⚠️ REQUIRES CHANGES

The suite is green and every milestone requirement is met, but three independent specialists
converged on the same structural defect — **synchronous work blocking a process that promises
to be responsive** — and the elixir reviewer found a crash path on the loop's public API. None
break the happy path today; all bite the moment the loop server or dashboard is driven for real.

| Dimension | Result |
|-----------|--------|
| Verification (compile/format/test) | ✅ 79 Elixir + 16 Python pass; `--warnings-as-errors` clean; formatted |
| Requirements coverage | ✅ 18 MET · 0 UNMET (P5-T1 "suite green" UNCLEAR → confirmed MET by verification-runner) |
| Code quality / OTP / LiveView | ⚠️ 3 runtime BLOCKERs + 2 test-confidence BLOCKERs |
| Security (local-first threat model) | ✅ no BLOCKERs; argv-list subprocess calls; privacy posture verified |

---

## Requirements Coverage (plan `.claude/plans/m3-m6/plan.md`)

**18 MET · 0 PARTIAL · 0 UNMET · 2 UNCLEAR → resolved MET.** The verifier could not assert
P5-T1 ("full suite green") from static review; the verification-runner then executed it: **79
Elixir + 16 Python tests pass, compile clean, format clean.** No unmet requirements ⇒ the
verdict is driven purely by code quality, not by missing scope.

Note: `Faber.LLM.ClaudeCLI` (the `claude -p` backend) and the native eval engine are **bonus**
work beyond the plan — both implemented, wired, and tested.

---

## BLOCKERS — runtime (3)

### BL1 · Loop.Server runs the loop synchronously in `handle_continue` → `await`/`status` deadlock
`lib/faber/loop/server.ex:35-38` · *(otp-advisor B1, corroborated by elixir-reviewer W#4)*

`handle_continue(:run, ...)` calls `Loop.run/1` inline, freezing the GenServer mailbox for the
entire run. The public `await/2` (default 60 s) and `status/1` then block until timeout — and a
50-iteration LLM run can take hours, so `await/2` **always** times out. Fix: run the loop in a
`Task.async`, hold awaiters in a `waiters` list, reply from `handle_info({ref, result}, …)`, and
add a `{:DOWN, …}` clause. Crash-isolation (`:temporary` child) is preserved. Skeleton in `otp.md`.

### BL2 · DashboardLive calls `Scan.run` synchronously in mount + rescan → blocks the LiveView
`lib/faber_web/live/dashboard_live.ex:15-26` · *(liveview-architect BLOCKER)*

The `connected?` guard is correct, but the connected mount still runs `Scan.run` (fan-out over
up to 400 sessions) inline before any frame reaches the client — the "scanning sessions…" state
added for UX never actually paints. Fix: `assign_async/3` in mount, `start_async/3` in rescan,
derive display assigns in `handle_async/3`. Full mount/rescan rewrite in `liveview.md`.

### BL3 · `refine/3` crashes on propose failure (bare `{:ok, seed}` match)
`lib/faber/loop.ex:249` · *(elixir-reviewer B1)*

`{:ok, seed} = Propose.propose(...)` raises `MatchError` whenever the LLM returns `{:error, _}`
— a real path now that the default backend is the `claude` CLI subprocess (can be missing / exit
non-zero). The crash takes down `Loop.Server`. Fix: `case` on the tagged tuple, propagate
`{:error, _}` to the caller (`mix faber.propose` has no guard either).

## BLOCKERS — test confidence (2)

### BL4 · The `refine/3` test is structurally vacuous
`test/faber/loop_test.exs:186-198` · *(testing-reviewer B2)*

`Sidecar.Stub` always returns `0.9` and `LLM.Stub` always returns identical content, so
`0.9 > 0.9` is false every iteration and `:stuck` is **guaranteed regardless of whether keep/revert
works**. The test would pass even if `refine/3` were broken. Combined with BL3 (an actual crash
in that exact function), the loop's core logic is effectively untested. Fix: use a sequencing
eval stub (like the `Loop.run/1` tests' `scorer/1`) so real keep/revert transitions are asserted.

### BL5 · native↔sidecar parity test never runs in normal CI
`test/faber/eval_test.exs:71-94` · *(testing-reviewer B1)*

The only test exercising the real Python sidecar is `@tag :sidecar`-gated. If the native and
Python engines drift, CI stays green. Fix: add a `mix test --include sidecar` step (e.g. a
`test.full` alias) and document it, or run unconditionally if Python is always present in CI.

---

## WARNINGS (9, deconflicted)

| # | Finding | Location | Raised by |
|---|---------|----------|-----------|
| W1 | **Sidecar exit code discarded** — `{out, _code}`; a non-zero exit with parseable partial stdout is trusted. Match `{out, 0}`/`{out, code}` (ClaudeCLI & Git already do). | `lib/faber/sidecar/system.ex:31` | otp, elixir, security, iron-laws (×4) |
| W2 | **git path-scope not enforced** — `paths` spliced raw into argv; the moduledoc's "can never touch unrelated files" invariant is false (a `-A`, absolute, or `../` element escapes; empty list → `git add` stages the whole repo). Add `Path.safe_relative` + reject `-`/absolute + `--` separator. Live risk only if paths ever come from an adapter/LLM. | `lib/faber/loop/git.ex:14-23` | security, elixir |
| W3 | **`faber.propose` missing `Mix.Task.run("app.config")`** before `ensure_all_started(:req_llm)` — `:faber` env keys (`:llm`, `:eval_threshold`…) may not resolve in all MIX_ENVs. | `lib/mix/tasks/faber.propose.ex:43` | iron-laws (High), elixir |
| W4 | **`Journal.read/1` uses `Jason.decode!`** — one truncated JSONL line (crash mid-append) breaks the whole read. Use `flat_map` + `Jason.decode/1`, skip bad lines. | `lib/faber/loop/journal.ex:51` | elixir |
| W5 | **`File.write!` in the loop** raises out of `Loop.run/1` on any FS blip, killing the run. Use `File.write/2` → discard. (Mitigated once BL1 moves the loop into a Task.) | `lib/faber/loop.ex:193,199` | otp |
| W6 | **`user_prompt/2` discards `%Adapter{}`** — the user half of the proposer prompt has no stack context despite the moduledoc. Either wire in `adapter.name`/playbooks or rename `_adapter` + comment the intent. | `lib/faber/propose.ex:111` | elixir |
| W7 | **Temp file world-readable** in `System.tmp_dir!` with default umask — mild TOCTOU/info-leak on shared/CI hosts; negligible on a single-user laptop. `File.chmod 0600` or `[:write, :exclusive]`. | `lib/faber/sidecar/system.ex:45-52` | security |
| W8 | **Untested loop error paths** — `eval_fn` error and `propose_fn` error mid-iteration (both → `discard`) are never exercised. Add one test each. | `test/faber/loop_test.exs` | testing |
| W9 | **LiveView polish** — `length(@results)` recomputed every render (store as `@shown`); no `<.flash_group>` / `fetch_live_flash`, so future `put_flash` is silently dropped. | `dashboard_live.ex:47`, `layouts.ex`, `router.ex` | liveview |

---

## SUGGESTIONS (compressed)

- **S1 · `rescan` has no auth/rate guard** — any connected socket triggers a full scan. Acceptable
  for a localhost-only tool; add a guard/debounce before any network exposure. *(iron-laws, liveview, security)*
- **S2 · OTP polish** — `status/1` `:infinity` → bounded timeout; start `PubSub` before `Loop.Supervisor`;
  predictable temp-file name → random. *(otp S1–S3)*
- **S3 · Elixir style** — `Eval.engine/1` `cond` → `if`; `revert/5` and `discard/5` are identical (merge
  with a reason atom or comment the intent). *(elixir #7, #8)*
- **S4 · test polish** — `DashboardLiveTest` can be `async: true`; move inline `defmodule FailingLLM` out
  of the test body; run parity on a bad fixture too; clean up the Python round-trip temp file; add an
  empty-file `score_session` case. *(testing W4, W6, W5, S2, S3)*

---

## Filtered out (anti-noise)

- testing W7 self-retracted (the `iteration == 5` assertion it asked for is already present).
- liveview "defer ordering" and "streams vs assigns" — both confirmed **correct as written**, no change.
- security findings 4–8 (model-output parsing, dev/test secrets, `check_origin: false`, CSRF/headers,
  privacy) — all assessed **CLEAN / ACCEPTABLE** for the local-first model; not carried as actions.

---

## What's solid (not noise — worth stating)

Supervision tree correct (`Loop.Server` `:temporary` under a `DynamicSupervisor`, started empty);
no `String.to_atom` on dynamic input; no `raw/1`; all three `System.cmd` boundaries use the argv-list
form (no shell injection); `connected?` mount guard correct; privacy verified end-to-end (only
`Scan.Result` aggregates reach the LLM — no transcript bodies); native↔sidecar engines agree within 0.05.
