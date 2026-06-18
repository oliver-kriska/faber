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

**Proposed refinement (not yet applied):** count a retry loop only when ≥3 consecutive
same-command Bash calls have ≥1 error result between them; consider a 2–3 token prefix for
precision. This is a deliberate *improvement over* the source, so it should be a flagged,
tested change — keep the faithful port available for comparison.

## Real-history snapshot (2026-06-18)

`mix faber.scan`: **4,607** non-trivial sessions ranked in **~4 s** (14-way
`Task.async_stream`), **3,358** tier-2 eligible. Highest-friction projects: `scriptorium`,
`xuku-enaia`, `scribe`, `elixir-live-claude-engineer`. `retry_loops` dominant across the
board (see Finding 2). Zero parse errors observed across the corpus.
