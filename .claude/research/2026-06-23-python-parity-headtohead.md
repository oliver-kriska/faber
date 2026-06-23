# Faber ↔ plugin Python parity — runtime head-to-head (2026-06-23)

**Question:** does Faber's Elixir scorer produce the same output as the plugin's Python
reference (`compute-metrics.py`) — the thing it was ported from?

**Answer:** Yes — Faber's friction scorer is a **faithful port**. Two of six signals are
**bit-identical**; the other four diverge **only** in ways that are documented-intentional or a
defensible definitional choice. **No unexplained deltas → no bugs found.** Bit-identical output
was never the goal (Faber is the *generic extracted engine* with deliberate fixes), but every
difference is now accounted for.

## How it was measured (reproducible)

Both sides read the **same raw `~/.claude/projects/*.jsonl` files** — no converter needed:
`compute-metrics.py`'s `parse_messages` accepts a raw list of message dicts, and `_get_content`
reads `message.content` (a list in raw Claude jsonl) → the structured "API format" path extracts
real `tool_use` blocks with inputs, exactly what `Faber.Detect` reads.

Harness (kept in `parity/`):

```sh
# Faber native scores for a deterministic spread of real sessions → JSONL (path + numbers)
mix run --no-start parity/export.exs /tmp/faber_parity.jsonl 120
# Plugin reference scorer over the SAME raw files + per-signal diff
python3 parity/compare.py /tmp/faber_parity.jsonl
# Override the reference location with PLUGIN_METRICS=/path/to/compute-metrics.py
```

## Results (120-session spread, sampled across the full ~5.6k corpus)

| field | exact-match | verdict |
|---|---|---|
| `error_tool_ratio` | **100%** | bit-identical |
| `interrupted_requests` | **100%** | bit-identical |
| `approach_changes` | 95.8% | identical algo; misses are arbitrary dominant-tool **tie-breaks** (3/4 within ±1) |
| `context_compactions` | 93.3% | **documented divergence** — 8/8 faber ≥ ref |
| `user_corrections` | 88.3% | **definitional** — 14/14 faber ≤ ref by 1–3 |
| `retry_loops` | 56.7% | **documented divergence** — 52/52 faber ≤ ref |
| `friction_score` (±0.05) | 74.2% | 100% of misses attributable to the signals above |
| `fingerprint` | 79.2% | user-message-set definition + tie-breaks |
| `tier2_eligible` | 90.8% | downstream of friction signals |
| `plugin_opportunity` | 94.2% | downstream / could_use ordering |

(40-session run showed the same shape: error_tool_ratio/user_corrections/approach_changes/
interrupted_requests at 100%, retry_loops 67.5%, context_compactions 90%.)

## Divergence ledger — every delta attributed

1. **`retry_loops` (faber ≤ ref, always).** Reference counts any run of 3+ consecutive
   same-*first-token* Bash calls and **never checks for failures** (despite its own comment
   saying "with failures between"). Faber requires a **2-token** prefix **and** an errored result
   in the run. Intentional fix — see `2026-06-18-friction-scoring-calibration.md` and
   `Faber.Detect` moduledoc. Avoids over-firing on normal `git …`/`cd …` sequences.

2. **`context_compactions` (faber ≥ ref, always).** Reference matches only the literal text
   `"context compaction"` in message text. Faber also honors the structured modern markers
   (`isCompactSummary`, `subtype: compact|compact_boundary`). Documented extension in
   `Faber.Detect`. Modern transcripts mark compaction structurally, so Faber catches what the
   text-match misses.

3. **`user_corrections` (faber ≤ ref by 1–3).** Definitional: the reference's
   `extract_user_messages` includes skill-injection blocks, image refs, and meta turns (it only
   strips a few literal prefixes), while Faber's `Event.human_turn?` excludes `is_meta` turns and
   requires extracted text. Faber's set is "what the human actually typed," which is the right
   denominator for a correction signal. Defensible; not a bug.

4. **`approach_changes` / `fingerprint` (tie-breaks).** Identical algorithms, but the
   dominant-tool / best-type selection breaks ties differently (Python dict insertion order vs
   Elixir `Enum.max_by` map order). Ties are inherently arbitrary; 3/4 approach_changes misses
   are within ±1. `fingerprint` additionally inherits the user-message-set difference from (3):
   the first-10-message keyword window shifts, occasionally flipping a soft, confidence-weighted
   label (e.g. `feature→unknown` on subagent `agent-*` transcripts where the human prompt is
   sparse).

5. **`friction_score` / `tier2` / `opportunity`.** Purely downstream — every friction_score
   miss traces to a signal in (1)–(4); tier2/opportunity follow from friction and the same
   signals.

## Decision: no Faber code changes

All four divergent signals are explained; none is a defect. Chasing bit-parity would mean undoing
the deliberate `retry_loops`/`context_compactions` improvements and counting skill-injection text
as user corrections — i.e. making Faber *worse*. The port is confirmed correct.

## Note: not the eval side

This covers the **scan/friction** side only. Faber's **eval** is a deliberate **subset** of the
plugin's `lab/eval/` — 6 of 8 dimensions (drops `accuracy` = needs a real plugin tree, and
`behavioral` = needs a cached trigger run), reweighted to sum to 1.0. The native↔Faber-sidecar
parity test (`@describetag :sidecar`) guards that the Elixir and Python *implementations of
Faber's eval* agree within 0.05; it does not claim parity with `lab/eval`'s composite, by design.
