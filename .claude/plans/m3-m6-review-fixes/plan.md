# Plan: M3–M6 Review Fixes

**Source:** `.claude/plans/m3-m6/reviews/faber-m3-m6-review.md` (verdict: REQUIRES CHANGES)
**Status:** COMPLETE — all phases done; 83 hermetic / 84 full Elixir + 16 Python green
**Created:** 2026-06-18

Every finding from the consolidated review maps to exactly one task below. Severity order:
runtime blockers → test-confidence blockers → warnings → suggestions. Suggestions (Phase 4)
are optional polish and may be deferred without blocking the milestone.

**Baseline (must stay green after every phase):**

```sh
mix format
mix compile --warnings-as-errors
mix test
cd python && python3 -m unittest discover -s tests   # 16 tests
```

---

## Phase 1 — Runtime BLOCKERs

- [x] [P1-T1][otp] **BL1 — Loop.Server: run the loop in a Task, not in `handle_continue`.** — `Task.async` in `handle_continue`; `%{result, task, waiters}` state; `:await` parks in `waiters`, replied from `handle_info({ref, result}, %Task{ref: ref})` (+ demonitor flush, `_msg` catch-all); `await/2` default → `:infinity`. 79 tests green.
  `lib/faber/loop/server.ex:35-38`. Replace the synchronous `Loop.run/1` with `Task.async`.
  Keep `%{result, waiters, task}` state. `handle_call(:await, from, %{result: nil})` parks the
  caller in `waiters`; `handle_info({ref, result}, ...)` demonitors, replies to all waiters,
  stores result. Add `handle_info({:DOWN, ref, :process, _, reason}, ...)` and a `_msg` catch-all.
  `status/1` returns `:running | {:complete, result}` immediately. Confirm `:temporary` child +
  DynamicSupervisor isolation still hold (Task is linked through the GenServer).
  *Verify:* loop_test Server case asserts `await` returns after ≥1 real iteration (see P2-T1/W3).

- [x] [P1-T2][liveview] **BL2 — DashboardLive: make the scan async.** — seed assigns in mount; connected mount + rescan → `start_async(:scan, …)`; `handle_async(:scan, {:ok, results}/{:exit, _})`; `@shown` replaces `length(@results)` in render; connected test now asserts loading state then `render_async/1`.
  `lib/faber_web/live/dashboard_live.ex:15-26`. Hoist `scan_opts()` out of the socket closure.
  Connected mount → `assign_async(:_scan, fn -> {:ok, %{...derived assigns...}} end)` after seeding
  `scanned: false`. `handle_event("rescan", ...)` → `start_async/3` (keeps prior results visible).
  Add `handle_async(:_scan, {:ok, data}, socket)` and `handle_async(:_scan, {:exit, reason}, ...)`.
  Use the recommended mount/rescan from `reviews/liveview.md` as the reference implementation.
  *Verify:* `dashboard_live_test` — disconnected GET still shows "scanning sessions"; connected
  `live/2` renders the table after the async resolves (`render_async/1` may be needed).

- [x] [P1-T3][elixir] **BL3 — `refine/3`: respect the `{:error, _}` tuple from `Propose.propose`.** — seed propose now `case`d (extracted `run_refinement/4`); returns `{:error, reason}` instead of `MatchError`; spec → `State.t() | {:error, term()}`. `mix faber.propose` call site already guarded by its `with`/`else`.
  `lib/faber/loop.ex:249`. Replace `{:ok, seed} = Propose.propose(...)` with a `case` that returns
  `{:error, _}` on failure instead of raising `MatchError`. Also guard the call site in
  `lib/mix/tasks/faber.propose.ex` so a propose error prints a clean message, not a crash.
  *Verify:* new test — `refine/3` with an LLM stub returning `{:error, :unavailable}` returns
  `{:error, _}` and does NOT crash the process (ties to BL4).

## Phase 2 — Test-confidence BLOCKERs

- [x] [P2-T1][testing] **BL4 — Replace the vacuous `refine/3` test with a sequencing stub.** — added nested `SeqSidecar` (reads scores from a `:seq_agent` Agent via opts) + `FailingLLM`; refine test now asserts a real keep→revert→stuck (best 0.6, 1 keep / 3 reverts) + a `{:error, :llm_unavailable}` no-crash case. Added a multi-iteration `Loop.Server` test (testing W3).
  `test/faber/loop_test.exs:186-198`. The current stubs (`Sidecar.Stub`=0.9, `LLM.Stub`=constant)
  make `:stuck` inevitable regardless of logic. Use a sequencing eval stub (like the `Loop.run/1`
  tests' `scorer/1` cell) so the test actually exercises a keep→improve→revert transition and
  asserts `best_composite`/history reflect real keep/revert decisions. Pair with the BL3 error-path
  assertion so a propose failure is covered too.

- [x] [P2-T2][testing] **BL5 — Make native↔sidecar parity run in CI.** — `:sidecar` was never excluded (so it silently ran in every `mix test`, needing python3); now excluded by default in `test_helper.exs`, run via the new `mix test.full` alias (+ `def cli` preferred_envs). Parity now runs on two inputs (good + bad, folds testing W5). Documented in CLAUDE.md + README. `mix test` → 80 (hermetic), `mix test.full` → 81.
  `test/faber/eval_test.exs:71-94` is `@tag :sidecar`-gated. Add a `mix test.full` alias (or a
  `test --include sidecar` step) in `mix.exs`, document it in `CLAUDE.md`/README, and run parity
  on TWO inputs (good + bad/edge) rather than one (folds in testing W5).

## Phase 3 — WARNINGs

- [x] [P3-T1][elixir] **W1 — Sidecar: match the exit code.** `lib/faber/sidecar/system.ex:31`.
  `case System.cmd(...) do {out, 0} -> Jason.decode(out)…; {out, code} -> {:error, {:sidecar_exit, code, out}} end`.
  (ClaudeCLI and Git already do this — bring sidecar to parity.) *Flagged by 4/8 agents.*

- [x] [P3-T2][security] **W2 — Git: enforce the path-scope invariant.** `lib/faber/loop/git.ex:14-23`.
  Validate each path with `Path.safe_relative/2`, reject absolute paths and any element starting
  with `-`, add a `"--"` separator before add paths (`["add", "--" | safe]`), and short-circuit on
  an empty path list (`commit(_dir, [], _msg) -> :ok`) so `git add` never stages the whole repo.
  Then the moduledoc's "can never touch unrelated files" claim is actually true.

- [x] [P3-T3][elixir] **W3 — `faber.propose`: load app config.** `lib/mix/tasks/faber.propose.ex:43`.
  Add `Mix.Task.run("app.config")` before `Application.ensure_all_started(:req_llm)` so `:faber`
  env keys resolve in all MIX_ENVs. Do NOT use `app.start` (would bind the endpoint port).

- [x] [P3-T4][elixir] **W4 — `Journal.read/1`: tolerate corrupt lines.** `lib/faber/loop/journal.ex:51`.
  Swap `Enum.map(&Jason.decode!/1)` for `Enum.flat_map` + `Jason.decode/1`, skipping `{:error, _}`
  lines so a truncated append (from a crash) doesn't break the whole read.

- [x] [P3-T5][otp] **W5 — Loop: don't let an FS blip kill the run.** `lib/faber/loop.ex:193,199`.
  Replace `File.write!` with `File.write/2`, propagate `{:error, reason}` through `handle_candidate`
  → `discard`. (Severity drops once BL1 moves the loop into a Task, but make it explicit.)

- [x] [P3-T6][elixir] **W6 — Proposer: decide on adapter context in the user prompt.** — `user_prompt/2` now binds `%Adapter{}` and leads with the stack name/version; test asserts it.
  `lib/faber/propose.ex:111`. Either wire `adapter.name`/playbook refs into `user_prompt/2`
  (preferred — matches the moduledoc) OR rename to `_adapter` with a comment that stack context
  lives only in the system prompt. Pick one and make the code honest. *Decision: wire it in.*

- [x] [P3-T7][security] **W7 — Sidecar temp file perms.** `lib/faber/sidecar/system.ex:45-52`.
  Create with `[:write, :exclusive]` (or `File.chmod(path, 0o600)` immediately after write) so the
  friction JSON isn't world-readable on shared/CI hosts. Negligible on a laptop, cheap to fix.

- [x] [P3-T8][testing] **W8 — Cover the loop error paths.** `test/faber/loop_test.exs`.
  Add a test where `eval_fn` returns `{:error, :timeout}` mid-iteration (asserts `kept: false`,
  reason =~ "eval failed") and one where `propose_fn` returns `{:error, :llm_unavailable}` (asserts
  the discard reason in history). Currently only `{:ok, _}` and scorer-exhaustion paths run.

- [x] [P3-T9][liveview] **W9 — LiveView polish.** `dashboard_live.ex:47`, `layouts.ex`, `router.ex`.
  Store the shown count as `@shown` instead of `length(@results)` in render; add `<.flash_group>`
  to the root layout and `plug :fetch_live_flash` to the `:browser` pipeline so future `put_flash`
  isn't silently dropped.

## Phase 4 — SUGGESTIONS (optional polish — defer-able)

- [x] [P4-T1][liveview] **S1 — `rescan` guard.** — `:scanning` assign; rescan ignored while in flight + button `disabled={@scanning}`; moduledoc note re: `on_mount` before network exposure. `dashboard_live.ex:23`. Add a debounce/`disable`
  while a scan is in flight (the async refactor in BL2 already gives the in-flight signal); add a
  code comment that the endpoint must not be network-exposed without an `on_mount` auth guard.

- [x] [P4-T2][otp] **S2 — OTP polish.** — PubSub started before Loop.Supervisor; `status/1` already bounded (5s) since BL1; temp name already random (W7). `loop/server.ex:25` bounded `status/1` timeout (not `:infinity`);
  `application.ex:13-16` start `PubSub` before `Loop.Supervisor`; `sidecar/system.ex:51` use a random
  temp-file name (`:crypto.strong_rand_bytes`) instead of the predictable `unique_integer`.

- [x] [P4-T3][elixir] **S3 — Elixir style.** — `Eval.engine/1` `cond`→`if`; `revert/5`+`discard/5` merged into `reject/5`. `eval.ex:53` `cond` → `if`; merge the identical
  `revert/5` and `discard/5` (`loop.ex:175-186`) into one `reject/5` taking a `:revert | :discard`
  reason, or comment the intentional duplication.

- [x] [P4-T4][testing] **S4 — Test polish.** — dashboard_test `async: true`; propose_test `FailingLLM` → namespaced module; python round-trip temp `unlink` in `finally`; empty-file `score_session` test. `dashboard_live_test` → `async: true`; move the inline
  `defmodule FailingLLM` (`propose_test.exs:106`) to `test/support/`; clean up the Python round-trip
  temp file (`test_roundtrip.py:69`); add an empty-file `score_session/1` case.

---

## Explicitly deferred / closed (no task)

These review items need no code change — recorded so coverage is complete:

- **Security findings 4–8** (model-output parsing, dev/test secrets, `check_origin: false`,
  CSRF/headers, privacy) — assessed CLEAN/ACCEPTABLE for the local-first threat model.
  *Forward-looking note (not now):* move `signing_salt` to `runtime.exs` env **before** any prod
  web surface ships.
- **liveview "defer ordering" + "streams vs assigns"** — confirmed correct as written.
- **testing W7** — self-retracted (the `iteration == 5` assertion already exists).

---

## Verification & sequencing notes

- Phases 1–3 each end with the full baseline (format / compile-WAE / `mix test` / python tests).
- P1-T1 (BL1) and P2-T1 (BL4) are coupled — the new Server test (W3) and the sequencing-stub
  refine test should be written together once the Task-based server lands.
- P1-T2 (BL2) may require `render_async/1` in `dashboard_live_test`; adjust the two existing tests.
- Suggested commits: one per blocker (P1), one for the test-confidence pair (P2), one per warning
  or a small grouped commit for the trivial ones (P3), Phase 4 optional. Conventional-commit
  messages + the `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` trailer.
  Do NOT push.

## Risks

- **assign_async + LiveViewTest:** the connected-render test currently asserts the table is present
  synchronously. After BL2 the table arrives via async — the test must `render_async/1` or assert on
  the loading state first. Low risk, but it touches both existing dashboard tests.
- **Server API shape change:** BL1 changes `status/1`'s return contract (`:running | {:complete, _}`).
  No external consumers today (only tests + future dashboard wiring), so safe to change now.
