# Test Audit — Faber (2026-07-10)

Scope: prior findings triage (`.claude/plans/review/reviews/testing.md`, 2026-06-26) plus new
coverage for `lib/faber/loop.ex` growth, `lib/faber/consolidate.ex`, `lib/faber/feedback.ex`,
`lib/faber/subprocess.ex`, `lib/faber/schedule.ex` wedge guard, `lib/mix/tasks/faber.refine.ex`,
and the `lib/faber_web/live/dashboard_live.ex` propose-gate fix. `mix test` baseline: 372 passed,
14 excluded, 0 failed.

## Prior findings (2026-06-26) — status

- W1 (`eval_test.exs` exact float `==`) — **fixed**: comment added justifying exact equality
  (`test/faber/eval_test.exs:298-300`), no `assert_in_delta` needed per the explanation.
- W2 (`schedule_test.exs` `async: false` over-conservative) — **still open**, and now *correctly*
  conservative: the wedge-guard tests added since (`max_run_ms`, `HangLLM`) exercise real timers
  and a hung `Process.sleep(:infinity)` task; async would risk cross-test timer interference. Not
  a regression — reclassify as won't-fix.
- W3 (`refute_receive` 300ms window) — **still open**, unchanged at `schedule_test.exs:162,183`.
- W4 (egress-tracer boilerplate duplicated) — **still open**: `test/faber/no_egress_test.exs`
  (129 lines) and `test/faber/mcp/no_egress_test.exs` (104 lines) still duplicate
  `collect/1`/`drain/1`/`flush_trace_delivery/0`/`dump/1`; no `test/support/egress_tracer.ex`
  was extracted.
- W5 (`cli_test.exs` on_exit registered after `put_env`) — **still open**, same pattern at
  `test/faber/cli_test.exs:103-107`.
- W6 (Gemini missing `Scan.run` e2e test) — **fixed**: `test/faber/ingest_gemini_test.exs:228-231`
  now has an `"end-to-end scan"` describe block mirroring Codex.
- S1 (`Faber.LLM.ReqLLM` zero hermetic coverage) — **fixed**: `test/faber/llm_req_llm_test.exs:22`
  and `:65` add "no network" describe blocks for call-building and error passthrough.
- S2 (`Ccrider` no hermetic behaviour-contract test) — **still open**: the only Ccrider test
  (`test/faber/ingest_source_test.exs:46-48`) still carries `@describetag :ccrider` (needs
  `sqlite3`); no `FakeSource`-style hermetic double was added.
- S3 (dashboard loop/refine action untested) — **N/A**: no loop/refine control was added to
  `DashboardLive`; the only new dashboard behavior (propose gating) is covered, see below.
- S4 (property-based tests for matchers) — **still open**, not attempted.

## New issues

### Warnings

- **`lib/faber/schedule.ex:164-179` (race-handling branch untested)** — `handle_info({:run_deadline,
  ref}, ...)` has two branches: `Task.shutdown` returns `{:ok, summary}` (the task actually
  finished right as the deadline fired — treated as normal completion) and the kill branch
  (`_` → `:run_timeout`). `test/faber/schedule_test.exs:191-208` only exercises the kill branch
  via `HangLLM`. The race branch (and the sibling `{:run_deadline, stale_ref}` clause for a
  deadline message belonging to an already-completed run) has no test, despite the code comment
  explicitly calling out the race as the reason the clause exists. Add a test that starts a job
  whose task finishes just before `:max_run_ms` (e.g. `max_run_ms: 50` against a task that sleeps
  40ms) and assert `summary.error` is NOT `:run_timeout`; separately, `send(pid, {:run_deadline,
  make_ref()})` after a run completes and assert state/behavior is unchanged (covers the stale-ref
  clause directly since triggering it naturally is racy).

- **`lib/faber/feedback.ex:84` (`:low_usage` verdict unexercised)** — `verdict/2` has four clauses
  (`:no_sessions`, `:unused`, `:low_usage` when `used/n < 0.1`, `:active`); `test/faber/feedback_test.exs`
  covers three of the four but never constructs a report where the skill fires in >0% but <10% of
  sessions. Add a case with e.g. 1 used / 11 sessions and assert `verdict: :low_usage`.

- **`lib/faber/feedback.ex:114-120` (`session_after?/2` File.stat error path unexercised)** — the
  permissive fallback for a vanished/unstatable transcript (`{:error, _} -> true`) has no test.
  Construct a `Scan.Result` whose `path` doesn't exist and assert the session still counts.

- **`lib/faber/loop.ex:437-448` (`attach_holdout/3` error branch unexercised)** — when
  `trigger_holdout: true` and `Eval.score/2` on the validation half fails, the code stores
  `%{error: reason}` into `state.holdout`. All `trigger_holdout` tests in `test/faber/loop_test.exs`
  exercise only the success path. Add a case with a sidecar/eval double that errors specifically
  on the holdout-scoring call and assert `state.holdout == %{error: reason}`.

### Suggestions

- **`lib/faber/consolidate.ex:104-110` (`Eval.gate` error path only reached transitively)** —
  `run/3`'s `{:error, reason} -> {:error, members, reason}` is exercised in
  `test/faber/consolidate_test.exs:134-139`, but only via the *merge* LLM call failing before
  `Eval.gate` is even invoked. The sibling case — merge succeeds, then `Eval.gate` itself returns
  `{:error, _}` (e.g. sidecar unreachable) — is untested. Low priority: same shape as the merge
  failure test and `Eval.gate`'s own error path is presumably covered elsewhere.

- **`lib/mix/tasks/faber.refine.ex` has no direct test** — the mix task wrapper (`Mix.Task.run("app.config")`,
  `Application.ensure_all_started(:req_llm)`, argv→`Faber.CLI.parse`→`run`, and the
  `exit({:shutdown, status})` mapping on non-zero) is untested; `Faber.CLI.run(:refine, ...)`
  itself is well covered (`test/faber/cli_test.exs:124-132`). Consistent with `faber.propose.ex`
  and `faber.scan.ex`, neither of which has a task-level test either — not a regression, just
  worth naming since it's the newest of the three and mix tasks in general are the one dispatch
  layer with zero coverage in this project.

- **`config/dev.exs:10`, `config/runtime.exs:43` (`check_origin` pin has no regression test)** —
  the WebSocket-hijack fix (commit `7fa4968`) pins `check_origin` to loopback; this is declarative
  endpoint config with no assertion anywhere that it stays pinned. A one-line test
  (`assert Application.get_env(:faber, FaberWeb.Endpoint)[:check_origin] == [...]` or reading
  `config/runtime.exs` at compile time) would catch an accidental revert to `false`. Low priority —
  config drift here is easy to catch in code review too.

## Areas confirmed clean

- `Faber.Subprocess` (`test/faber/subprocess_test.exs`) — full behavior coverage: pass-through,
  no-timeout default, prompt kill-and-return, System.cmd raise passthrough, non-zero exit.
- `Faber.Consolidate` cluster/merge/run — clustering (grouping, threshold, empty input), merge
  (singleton short-circuit, multi-proposal via LLM + provenance), and the full run pipeline
  (merge+pass, merge+gate-fail keeps originals, merge LLM failure keeps originals) are all
  exercised against real behaviour doubles, not mock-call assertions.
- `Faber.Loop` new surface (`trigger_holdout`, seed-pinned behavioral recall, `:reflect` strategy,
  anti-gaming guard, `Loop.Server`) — unusually thorough: a dedicated `GamingLLM` double proves
  candidates can't self-score on rewritten fixtures, a `ReflectiveLLM` double proves feedback
  actually improves the real (native, deterministic) eval score, and `Server` async-completion
  timing is bounded rather than blocking.
- `FaberWeb.DashboardLive` propose-gate fix (`test/faber_web/dashboard_live_env_test.exs:42-57`) —
  both the UI-hide and the server-side raw-event refusal are asserted, matching the "hidden button
  is not the boundary" framing in the commit.
- Subprocess timeout wiring at each call site (`ClaudeCLI`, `Loop.Git`, sidecar) has direct tests
  mapping the specific error tuples (`llm_claude_cli_test.exs`); the scheduler wedge guard's
  primary kill path is tested end-to-end with a real hung task, not a mocked timeout.
- No `Process.sleep` in test bodies, no Mox/global-mode misuse, `async: true` is the default with
  justified exceptions (schedule, dashboard-env). Hand-rolled behaviour doubles throughout are used
  to drive real pipeline code, not asserted-upon-directly as call spies — this project doesn't have
  an over-mocking problem.
