# Friction scoring — calibration findings (M2)

> What the first real-history scan revealed about the ported friction metric, what was
> fixed, and the open precision question. Source: the plugin's
> `session-scan/references/compute-metrics.py` (`compute_friction`, lines 417–509) +
> `scoring-guide.md`, scanned 2026-06-18.

## Port fidelity

`Faber.Detect.friction/1` is a faithful port of `compute_friction`. Three discrepancies in
the first cut were corrected (commit `f9eb466`):

- **Bash retry prefix** = first whitespace token (source uses `cmd.split()[0]`), not 3 tokens.
- **approach_changes** eligibility ≥ 10 tool calls, chunk size `max(n/4, 5)` (was ≥ 4, `max(n/4,1)`, capped at 4 chunks).
- **context_compactions** match the literal `"context compact"` substring (source matches
  `"context compaction"`), plus the modern `isCompactSummary` / `subtype` markers.

## Finding 1 — the sigmoid score saturates (by design)

`score = sigmoid(raw)` with `k=3.0, midpoint=1.5`. `raw = Σ(signal_value × weight)` uses
**raw counts**, so on any long session `raw` is large and `score` pins to `1.000`. The
source has the same property: `session-scan` is a **per-session triage** metric ("is this
session painful? y/n"), not a **cross-session ranking** metric.

**Fix:** `Faber.Scan` ranks by **`raw`** (monotonic, discriminates), keeping `score`/`tier2`
for the y/n gate. Before: top 15 all `1.000`. After: `323.1 → 316.1 → 215.0 → …`.

Open option: a friction **rate** (`raw / message_count`) would surface *concentrated*
friction independent of length; `raw` favors long sessions with lots of total friction.
Both are defensible for "which sessions to mine" — revisit when the proposer consumes this.

## Finding 2 — `retry_loops` (first-token) is noisy and dominates ranking

With the first-token prefix, the dominant signal is `retry_loops` for **all** top sessions.
Any 3+ consecutive Bash commands sharing a first token (`git …`, `cd …`, `python …`) count
as a "retry loop" — at weight 3.0 it dominates `raw`, so the ranking is effectively
"longest, most Bash-heavy sessions." Faithful to the source, but it conflates *real* retry
friction (re-running a *failing* command) with normal sequential workflow.

### Latent bug in the source (precision opportunity)

`compute-metrics.py:425` comments the signal as *"same command 3+ times **with failures
between**"*, but the implementation (lines 436–444) only counts consecutive same-first-token
commands — **it never checks for an error result between them.** The *intended* semantic
(consecutive same command with a failing `tool_result` in between) is far more precise for
genuine friction. Faber has the data to implement the intended version (events carry
`tool_results[].is_error`).

**Refinement (APPLIED, commit after `4d5996d`):** a retry loop now counts only when a run of
≥3 consecutive same-prefix Bash calls contains ≥1 errored result (linked via
`tool_use_id` → `is_error`), keyed on a **2-token** prefix (`mix test`, `git commit`). This
is a deliberate, documented improvement over the source.

**Outcome on full history:** the dominant signal shifted away from `retry_loops`-everywhere
to **`context_compactions`** (long grinding sessions) and **`user_corrections`** (user
pushback) — far truer friction. Top raw dropped `323 → 121` as retries stopped over-firing.
Net: a more meaningful ranking.

**New minor finding:** subagent/sidechain transcripts (`isSidechain: true`) appear as
near-duplicate sessions sharing a `session_id` (e.g. several `subagents/ff4b234b` rows).
A dedup / sidechain-filter pass is a future scan refinement. **(RESOLVED — see Finding 3.)**

## Finding 3 — sidechain dedup collapses ~70% of rows (APPLIED, M2 Phase 3)

`Faber.Scan.run/1` now groups results by `session_id` and keeps the **richest** member
(most messages, then highest `raw`); rows with no `session_id` pass through. Controlled by
`:dedupe` (default `true`) / `mix faber.scan --no-dedupe`.

The effect on real history is large and correct: **4,609 → 1,391** ranked sessions (a ~70%
collapse). The cause isn't a few sidechains — Claude Code writes **one transcript file per
subagent invocation**, all carrying the parent's `session_id`. A single heavily-orchestrated
session produced **180 files**; several others 100+. Without dedup those sessions appear
dozens-to-hundreds of times and dominate the ranking; with it, each session is counted once.
(54 files carry a blank `session_id` and pass through individually — acceptable.)

The richest-member rule matters: the parent transcript (full conversation) beats its short
subagent fragments, so the surviving row has the real message/tool/error counts.

## Finding 4 — fingerprint + opportunity surfaced per session (M2 Phase 2–3)

Each `Result` now carries a `fingerprint` (`type` + `confidence`) and an `opportunity` score
(missed-automation, 0–1) with `missed`/`used` skill lists. On real history the top of the
ranking is a healthy mix of `bug-fix`, `feature`, and `review` sessions with OPP `0.4–0.8` —
i.e. the highest-friction sessions are also where skills (investigate / plan / verify /
review) would most plausibly have helped. `tier2` now trips on any of: friction > 0.35,
opportunity > 0.5, a skill already used, or > 50 messages.

## Real-history snapshot (2026-06-18, post-Phase-3)

`mix faber.scan`: **1,391** deduped non-trivial sessions ranked in **~3.5 s** (14-way
`Task.async_stream`), **1,181** tier-2 eligible (**4,609 / 3,704** with `--no-dedupe`).
Highest-friction projects: `xuku-enaia`, `articles`, `scriptorium`, `scribe`, `job-hunt`.
Dominant signal is now `context_compactions` / `user_corrections` (see Finding 2). Zero parse
errors across the corpus.
