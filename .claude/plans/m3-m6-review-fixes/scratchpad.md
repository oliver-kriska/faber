# Scratchpad — M3–M6 Review Fixes

## Origin
Planned from `.claude/plans/m3-m6/reviews/faber-m3-m6-review.md` (verdict: REQUIRES CHANGES).
8-agent review of the M3–M6 diff (e1db06c..HEAD). Findings ARE the research — no re-discovery
agents spawned (plan Iron Law #7).

## Decisions
- New slug `m3-m6-review-fixes` (kept the completed `m3-m6/plan.md` intact).
- W6: chose to **wire adapter context into the user prompt** rather than rename `_adapter`.
- BL1 changes `Loop.Server.status/1` contract (`:running | {:complete, result}`) — safe, no
  external consumers yet.

## Coupling / dead-ends to avoid
- Don't write the new Server `await`-while-running test before BL1's Task refactor lands — the
  current seed (composite 0.96 ≥ target 0.95) exits before iterating, so the running path can't
  be exercised until the loop actually runs in a Task.
- After BL2 (assign_async), the dashboard table arrives async — the existing connected-render
  test will need `render_async/1`; don't assert the table synchronously.
- BL4: the vacuous refine test only "passes" because both stubs are constant. Use a sequencing
  eval stub (mirror the `Loop.run/1` tests' `scorer/1` cell) — a constant stub will re-break it.

## Verify before every commit
mix format · mix compile --warnings-as-errors · mix test · (python) python3 -m unittest discover -s tests
Trailer: Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com> · never push.
