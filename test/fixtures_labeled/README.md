# A labeled session fixture

`dogfood_session.jsonl` is a **synthetic transcript with known ground truth**. Faber's other
fixtures answer "does the parser handle this shape?"; this one answers a question no amount of
happy-path testing reaches: **what friction is real, and how much of it can the detector see?**

The friction encoded here is known because it was **lived, not inferred**. It reproduces four
things that actually happened while building the CLI UX work (`4d74a53`, `e223c8b`) and this plan.

Characterization tests: `test/faber/detect/labeled_session_test.exs`.
Why the score is ~60% length-loaded, and why rescoring was deliberately deferred rather than done:
`.claude/research/2026-07-16-friction-score-construct-validity.md`.

## Why its own directory

`test/fixtures_labeled/`, not `test/fixtures/` — the same reason `fixtures_dedup` and
`fixtures_python` are separate. `scan_test` and `cli_test` **dir-scan** the shared `test/fixtures`
tree and assert on what they find. This fixture is deliberately high-friction, so dropped in there
it ranks #2, adds a fourth project to the header count, and breaks two unrelated tests.

## Why synthetic

The real transcript is ~834 events, lives outside the repo, contains Oliver's unrelated work, and
**keeps growing while being scanned**. None of that can be committed or asserted line-by-line. This
fixture is 33 lines and every one of them is readable.

The cost is honest: proportions are not the real session's. The real session's dominant signal was
`context_compactions`; this fixture's is `user_corrections`, because two corrections in 33 events
weigh differently than two in 834. **The rows are faithful; the ratios are not.** Don't tune the
scorer against this file's `raw`.

## Ground truth vs. detected

| # | What actually happened | Detected? | Signal | Why |
|---|---|---|---|---|
| 1 | `mix verify \| tail -5; echo $?` → **false green**. Reported pass; verify really exited 8. | **No** (friction) / **Yes** (hazard) | `Hazard :pipe_masks_exit` | The pipeline returns `tail`'s status, so Bash exits 0 → `is_error: false`. No retry (the agent believed it), no correction (Oliver didn't catch it). **No friction signal will ever see this** — that is why `Faber.Detect.Hazard` reads tool *inputs* instead of outcomes. |
| 2 | `@attribute` used before definition — the **same mistake twice**, two files. | **No** | `retry_loops` = 0 | `count_retry_loops/2` needs ≥3 **consecutive** Bash calls with the **same normalized command**. An edit and a `mix format` sit between the hits. |
| 3 | Wrong verb (`/phx:full` on an existing plan), `--codex` misuse. | **Partially** | `user_corrections` = 2 | Counts *that* Oliver pushed back, not *what about*. A counter, not a classifier. |
| 4 | One context compaction. | **Yes** | `context_compactions` = 1 | The only row the detector sees cleanly — and it means "this session was long". |

Scored today (pinned in the tests):

```
retry_loops: 0   user_corrections: 2      error_tool_ratio: 2/14
approach_changes: 0   context_compactions: 1   interrupted_requests: 0
raw: 6.785714285714286   score: ~1.0 (saturated)   dominant: user_corrections
```

## Three findings this fixture produced

**0. Row 1 is now detected — by a second detector, not by the score.**
`Faber.Detect.Hazard` (2026-07-17) sees the false green as a `:pipe_masks_exit` **hazard**, and
`Faber.Scan.Result.hazards` carries it. Read the table's row 1 precisely: the friction score still
scores this session's lie at **zero on all six signals**, and the three findings below all still
hold unchanged. The hazard detector does not fix them — it sidesteps them, by reading what the
session was *about to run* rather than how badly it went. It sees **one** class of silent success
(`Hazard.known_kinds/0` is the honest list), not silent successes in general.
Characterization: `test/faber/detect/hazard_test.exs`.

**1. The false green doesn't merely evade the score — it *dilutes* it.**
The plan this came from recorded "contributes 0 to all six signals". That is right about the five
counters and wrong about the sixth: `error_tool_ratio` is `error_count / tool_count`, and a
successful-*looking* call still lands in the denominator. Removing the false-green exchange from
this fixture **raises** `error_tool_ratio` from 2/14 to 2/13. A session that fails silently scores
as *less* frictional than the same session with the lie deleted. Faber currently rewards lying.

**2. The score is saturated here.**
`raw` 6.79 against `sigmoid(k=3.0, midpoint=1.5)` pins `score` at ~1.0. Two corrections and one
compaction max it out; the four rows above cannot move it and neither could four more. Any
rescoring should note the dynamic range is spent well before the interesting cases.

**3. Error *text* never reaches the detector.**
`extract_tool_results/1` (`lib/faber/ingest/format/claude.ex:200`) normalizes a tool result to
`%{tool_use_id, is_error}` and discards its content. Row 2's two failures are the *same* error —
which is exactly what makes it a pattern worth a skill — but they arrive as two indistinguishable
`true`s. This is the ceiling on every content-based friction signal: a detector cannot cluster
errors it cannot read. Recorded, not fixed: retaining tool output means putting the user's
tool output into Faber's memory, which is a privacy decision (cf. the transcript-`path` stripping
in `Faber.Install`'s provenance), not a patch.

## For whoever does the rescoring

This file is the **baseline**; the table above is the **target**. They are deliberately in one
place, so a change can be measured rather than argued about.

The tests pin current behavior *including the zeros*. A zero failing is a finding, not a broken
test — if you change the detector, update the table in the same commit.
