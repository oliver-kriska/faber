# Test Review: test/faber/{propose,eval,eval_native,llm_claude_cli,loop,scan}_test.exs · test/faber_web/dashboard_live_test.exs · python/tests/{test_score,test_roundtrip}.py

## Summary

The suite is well-structured and covers the happy path thoroughly. All Elixir tests correctly
use `async: true` (or justify `async: false`), no bare `Process.sleep`, no Ecto Sandbox
violations (no DB), and stubs properly implement `@behaviour`. The main weaknesses are:
false-confidence from a fully-canned stub that can never diverge from "pass", a parity test
that is skipped in normal CI, missing edge-case paths (eval failure mid-loop, proposal error
mid-loop, `Server.await` timeout), and a few loop-logic gaps.

---

## Iron Law Violations

None.

---

## Issues Found

### Blockers

**B1 — `eval_test.exs:71-94` — native↔sidecar parity test is gated `@tag :sidecar` and never
runs in normal CI.**

The test that gives the parity guarantee (`Faber.EvalTest`, `"score/2 (real python sidecar)"`)
is tag-guarded. If the native and Python engines drift, CI stays green. This is the only test
that exercises the real `Faber.Sidecar` in the Elixir suite. Without it running, the `engine:
:native` path is the only one validated end-to-end.

Fix: add `mix test --include sidecar` as a required step in `mix test` (a separate alias, e.g.
`mix test.full`) and document it in `CLAUDE.md`; or run it unconditionally if Python is always
present in CI.

---

**B2 — `loop_test.exs:186-198` — `refine/3` test passes on broken eval because `Faber.Sidecar.Stub` always returns 0.9 and the stub LLM is deterministic.**

`Sidecar.Stub` always returns `composite: 0.9`. `LLM.Stub` always produces the same content.
Every call to `propose_fn` generates identical content, so `composite > best_composite` is
`0.9 > 0.9` — false on every subsequent iteration (strict improvement required). The test
asserts `state.status == :stuck` and `best_composite == 0.9`. This passes even if `Faber.Eval`
or `Faber.Loop.refine/3` is completely broken internally — the stuck state follows inevitably
from the stub characteristics, not from the logic under test. The `:patience: 3` cap is the
only real assertion.

Fix: use a sequencing eval stub (as the direct `Loop.run/1` tests do with `scorer/1`) to
verify that actual keep/revert transitions happen inside `refine/3`, not merely that it
terminates.

---

### Warnings

**W1 — `loop_test.exs` — `eval_fn` error path inside an iteration not tested.**

The `handle_candidate/4` branch `{:error, reason} → discard(...)` (loop.ex:132-139) is not
covered. All `eval_fn` calls in the test suite either return `{:ok, composite}` or exhaust the
scorer (`:exhausted`). The `:exhausted` error will hit the `discard` branch but no test
asserts on it explicitly (the scorer is just depleted at loop termination, never mid-run).

Fix: add a test where `eval_fn` returns `{:error, :timeout}` on iteration 2 and verify the
entry is `kept: false` with `reason =~ "eval failed"`.

---

**W2 — `loop_test.exs` — `propose_fn` error path not covered.**

`step/1` (loop.ex:113) handles `{:error, reason}` from `propose_fn` via `discard`. No test
exercises this branch.

Fix: one test with a `propose_fn` that returns `{:error, :llm_unavailable}` and assert the
history entry carries the discard reason.

---

**W3 — `loop_test.exs:201-219` — `Server.await` timeout path not tested; race possible.**

The `Loop.Server` test starts the server, immediately calls `Server.await(pid)`, and asserts
`:complete`. Because `seed composite (0.96) >= target (0.95)`, the loop exits before even
running a step — `handle_continue` completes synchronously before `await` is called. This
means the GenServer's "loop is running when await is called" path (`:running` state with
queued callers) is never exercised. Additionally, `Server.await/2` uses `timeout: :infinity`
internally but the test passes no timeout, risking a hang on broken code.

Fix: add a test where the server runs ≥1 iteration (seed below target), and assert `:ok,
state` arrives after completion. Add a test or comment confirming what happens when the server
is still `:running` at await time.

---

**W4 — `dashboard_live_test.exs` — `async: false` with no comment; it could be `async: true`.**

`DashboardLiveTest` uses `async: false`. There is no shared global state (no DB, no
Application.put_env, no Mox global, no port binding since `server: false`). Phoenix.LiveViewTest
with an in-process endpoint is safe under `async: true`.

Fix: change to `async: true` and add a comment if there is a hidden reason.

---

**W5 — `eval_test.exs:83-94` — the sidecar parity tolerance (0.05) is arbitrary and untested against worst-case inputs.**

`assert_in_delta native.composite, sidecar.composite, 0.05` uses the best-case fixture
(full `GOOD_SKILL` equivalent from `LLM.Stub`). A bad skill is never run through both engines.
The delta could mask a systematic bias.

Fix: run parity on at least two inputs (good + bad/edge), or document why a single fixture
suffices.

---

**W6 — `propose_test.exs:105-113` — inline `defmodule FailingLLM` inside a test.**

Defining a module inside a test body is an anti-pattern: the module is globally registered for
the process lifetime of the test VM, risks name collisions if the test is re-run, and pollutes
the atom table. With `async: true`, parallel test runs can collide if the module name is
constant.

Fix: move `FailingLLM` to a module-level private definition, or to `test/support/`, or use a
`Mox`-style approach if a mock library is available. At minimum add a unique suffix
(`FailingLLM#{System.unique_integer()}`) — though that's not idiomatic Elixir.

---

**W7 — `loop_test.exs:64-80` — `max_iterations` stop condition asserts `status == :complete` but this is ambiguous.**

The loop hits `max_iterations` and returns `:complete`, not `:max_iterations_reached` or
`:timeout`. The test accepts this but does not confirm the reason is distinguishable from a
genuine target-hit `:complete`. If the loop semantics ever change (e.g. add `:exhausted`
status), this test is fragile.

Fix: add a `state.iteration == 5` assertion alongside `state.status == :complete`. (The test
already does this — this is actually present at line 79. No action needed here; remove this
entry. Confirmed: `assert state.iteration == 5` is present.)

---

### Suggestions

**S1 — `eval_native_test.exs` — `no_dangerous_patterns` test only checks `rm -rf /`.**

The dangerous pattern matcher likely covers more cases (e.g. `curl | bash`, `chmod 777`). A
property-style table test would increase confidence.

**S2 — `scan_test.exs` — `score_session/1` is tested only for malformed input; no test for an empty file.**

An all-empty JSONL file (0 bytes) is a valid edge case for file-based ingestion. Add a fixture
or inline temp file test.

**S3 — `test_roundtrip.py:69-79` — temp file is not cleaned up (no `finally` or `unlink`).**

`test_score_via_input_file` writes a temp file but never deletes it. Use `delete=True`
(Python 3.12+) or a `try/finally` block with `Path.unlink`.

**S4 — `llm_claude_cli_test.exs` — `generate_object/3` exit code on parse failure not tested.**

`extract_json` is tested for `:no_json_object` but the full `generate_object` path with valid
binary output that fails JSON extraction is not covered (e.g. the fake binary prints malformed
JSON). The error shape from the outer call is not verified.
