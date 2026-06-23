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

## Note: the eval side (updated 2026-06-23 — gap closed, E1–E3)

This report's measurements cover the **scan/friction** side. The **eval** side originally shipped 6
of the plugin's 8 `lab/eval` dimensions (dropped `accuracy` = "needs a real plugin tree", and
`behavioral` = "needs a cached trigger run"). Both are now implemented:

- **`accuracy`** — three ref-resolution matchers (`valid_file_refs`, `valid_skill_refs`,
  `valid_agent_refs`) ported to **both** engines (Elixir `Matchers` + Python `matchers.py`). The
  plugin's versions list the filesystem; Faber's are kept **pure** — they validate refs against
  caller-supplied *known-sets* (`:refs` → `known_files`/`known_skills`/`known_agents`), and the
  filesystem walk happens once at the boundary (`Faber.Eval`). Pure functions ⇒ native↔sidecar
  parity is exact. Without a known-set the check neutral-passes (never blocks the gate for missing
  context — same philosophy as the reference's "cannot locate plugin root — skipping").
- **`behavioral`** — the existing `Faber.Eval.Trigger` (keyless LLM routing accuracy) now reports
  precision/recall and is **folded into the composite** as the `behavioral` dimension (weight 0.10,
  three threshold assertions mirroring the reference) when `trigger: true`. A well-formed but
  mis-routing skill can now fail the gate.

**Design choice — no gate inflation.** The *default* eval stays the 6 structural dimensions
(`eval_set: :default`). Adding always-neutral dimensions to the default would have handed every
skill ~0.25 of free weight and silently weakened the 0.75 gate. So the 8-dimension shape lives in
`eval_set: :full` (+ `accuracy`) with `behavioral` folded only when trigger data exists — each new
dimension contributes **only when it has real signal**. Weights mirror the reference
(`lab/eval/scorer.py` `default_eval`).

The native↔Faber-sidecar parity test (`@describetag :sidecar`) now guards **both** eval sets and the
ref-injected accuracy path (Elixir vs Python agree within 0.05). It still does not claim parity with
`lab/eval`'s *composite* (Faber's per-dimension checks are its own, deliberately), by design — it
guards that Faber's two engines agree.

## Follow-up (2026-06-23): detection improvements (D1–D3)

After the head-to-head, three fixes landed; parity re-measured on a fresh 120-session spread:

| field | before | after | change |
|---|---|---|---|
| `approach_changes` | 95.8% | **100%** | tie-break now matches the reference exactly |
| `friction_score` ±0.05 | 74.2% | **79.2%** | downstream of the tie-break fix |
| `tier2` | 90.8% | **91.7%** | up *despite* adding the context-pressure trigger |
| `fingerprint` | 79.2% | 76.7% | tie-break helped; residual is the message-set difference |
| `error_tool_ratio`, `interrupted_requests` | 100% | 100% | unchanged (bit-identical) |

1. **`:limit` no longer takes the alphabetical prefix** (`Scan.run`) — it samples an even spread.
   This was a real bug: the dashboard's `limit:400` and the CLI's defaults scored only the
   first-sorted (tiny stub) sessions, so the dashboard showed the wrong top session. The dashboard
   now scores **all** sessions (async) and ranks the true worst; CLI/propose defaults dropped.

2. **Deterministic tie-breaks** (`Detect`) — `fingerprint` best-type and `approach_changes`
   dominant-tool resolved ties by (unstable) map order. Now they break ties by the reference's
   fixed order (`@fingerprint_order`) / first-appearance (`Counter.most_common` semantics), which
   is both reproducible run-to-run AND parity-matching → `approach_changes` is now an exact match.

3. **Context-pressure signal** (`Detect.context/1`) — mines `message.usage` for peak prompt fill
   (`max_ctx_pct`); feeds the `≥90%` tier-2 trigger (the 5th reference trigger Faber lacked). The
   model→window map is ported from the reference and **extended to current models** (it predated
   opus-4-8), so context pressure is computed for modern sessions where the stale reference returns
   `None` — a documented improvement.

Residual `fingerprint` divergence (~77%) is the **message-set definitional difference** (Faber's
`human_turn?` excludes `is_meta`/skill-injection/image turns the reference counts), not tie-breaks.
That is a defensible choice ("what the human actually typed"), left as-is.
