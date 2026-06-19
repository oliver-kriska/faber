# Test Review: Re-review of test fixes (diff base f9ded78..HEAD)

## Summary

Both prior blockers are genuinely resolved. The new tests meaningfully exercise keep/revert
logic, the sidecar exclusion is wired correctly, and the new mid-iteration discard tests plug
the gaps flagged as W1/W2. The multi-iteration Server test now exercises the Task/await path
rather than the trivial pre-loop termination shortcut. A small number of residual issues follow.

---

## Prior Blockers — Disposition

**B1 RESOLVED.** `test_helper.exs` now sets `ExUnit.configure(exclude: [:sidecar])` making
`mix test` hermetic. `mix.exs` adds `"test.full": ["test --include sidecar"]` with `def cli`
`preferred_envs`. The parity test will run in any environment that has Python by invoking
`mix test.full`; a developer can no longer accidentally run `mix test` and get sidecar
coverage without noticing.

**B2 RESOLVED.** The `refine/3` test now injects `SeqSidecar` via `opts` (forwarded through
`Eval.score(c, opts)` → `Faber.Sidecar.call`). Score sequence `[0.5, 0.6, 0.55, 0.55, 0.55]`
traces correctly: seed eval pops **0.5** (best=0.5); iteration 1 pops **0.6** → keep (1 keep,
best=0.6); iterations 2–4 pop **0.55** → reject×3 → consecutive_discards=3 == patience=3 →
stuck. Assertions `best_composite == 0.6`, `kept==1`, `reverted==3` all follow from real
keep/revert logic, not from stub characteristics. The test would fail if the strict-improvement
guard were broken.

---

## Issues Found

### Warnings

**WARNING — `loop_test.exs:293-315` — multi-iteration Server test has a latent race in `await`
ordering.**

The test calls `Server.await(pid)` with no timeout (defaults to `:infinity`). If the loop
Task crashes (e.g. eval scorer exhausted unexpectedly), `handle_info` for the DOWN message
hits the catch-all clause (`handle_info(_msg, state)`), the waiters list is never replied to,
and `await` hangs forever — hanging the test process until the ExUnit suite timeout fires
(minutes). The risk is low with well-behaved opts but the test has no finite timeout guard.

Fix: pass an explicit timeout to `Server.await(pid, 5_000)` so a broken Server surfaces as a
test failure rather than a hang.

**WARNING — `loop_test.exs:11-26` — `SeqSidecar` opts-injection is a sound but fragile
coupling.**

`SeqSidecar.call` does `Keyword.fetch!(:seq_agent)` from `opts`. `opts` flows through
`refine/3` → `Eval.score(c, opts)` → `Faber.Sidecar.call(_command, _request, opts)`. This
works correctly today because `Eval.score` passes the full opts keyword list to the sidecar.
If `Eval.score` ever filters or wraps `opts` before forwarding (e.g. strips unknown keys), the
`seq_agent` key will silently disappear and the sidecar will crash on `fetch!`. The coupling
is not wrong — it is the documented mechanism — but it is invisible from the `Eval.score`
public spec.

Fix (suggestion-level): add a comment in `SeqSidecar` noting the dependency on `Eval.score`
passing opts through unmodified, so future refactors of `Eval.score` do not break this
silently.

**WARNING — `eval_test.exs:84` — parity test `@describetag :sidecar` placement.**

`@describetag :sidecar` tags every test in the `describe` block. Currently the block contains
only one test, so this is fine. If a future developer adds a non-sidecar test to this describe
block it will inadvertently be excluded from `mix test`. The block name ("real python sidecar")
makes intent clear, but the tag is describe-scoped, not test-scoped.

Fix: use `@tag :sidecar` on the individual test rather than `@describetag` on the block.

### Suggestions

**SUGGESTION — W3 (prior review) partially addressed.**

The second Server test exercises `max_iterations: 3` with three scored iterations, which
confirms the Task/await reply path when the loop runs longer than one step. The "await called
while still running" path (caller parks in `waiters`) is covered because `Server.await` is
called immediately after `start_supervised!` before the Task can complete in a heavily loaded
CI. This is sufficient — the concern is largely addressed.

**SUGGESTION — B1 silent regression risk.**

There is no CI enforcement that `mix test.full` is run before merging. `CLAUDE.md` documents
it as required before sidecar-touching commits, but this relies on developer discipline. If CI
only runs `mix test`, a native/sidecar drift will be invisible until `mix test.full` is run
manually. Consider adding a CI step or a note in the task runner that enforces `test.full` on
the relevant paths.

**SUGGESTION — `python/tests/test_roundtrip.py:69-82` — S3 RESOLVED.** `finally` block with
`Path(path).unlink(missing_ok=True)` is present. No action needed.

**SUGGESTION — W6 (prior review) RESOLVED.** `FailingLLM` in `propose_test.exs` is now a
module-level `defmodule` (namespaced as `Faber.ProposeTest.FailingLLM`), not defined inside a
test body. The same fix was applied in `loop_test.exs` (`Faber.LoopTest.FailingLLM`). Both
clean.

**SUGGESTION — W5 (prior review) RESOLVED.** Parity test now loops over `[good, bad]` inputs,
catching systematic bias across the score range.

**SUGGESTION — S2 (prior review) RESOLVED.** `scan_test.exs` now includes an empty-file
`score_session` test using `@tag :tmp_dir`.
