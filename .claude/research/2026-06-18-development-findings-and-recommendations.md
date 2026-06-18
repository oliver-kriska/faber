# Faber — development findings & recommendations (M0–M6)

> Things discovered while building the pipeline that are worth acting on. Each is tagged with
> status: **DONE** (already implemented), **IMPLEMENT** (actioned in this pass), **REPORT** (a
> finding about the *plugin* we can't change from here), or **NOTE** (watch / future).

## 1. Sidechain transcripts inflate session counts ~70% — DONE (M2)
Claude Code writes one `.jsonl` per subagent invocation, all sharing the parent `sessionId`
(one session → 180 files). Without dedup, orchestration-heavy sessions dominate any ranking.
`Faber.Scan` dedups by `session_id`, keeping the richest member. (KB drop filed.)

## 2. The plugin's retry-loop metric has a latent bug — DONE in Faber / REPORT to plugin
`compute-metrics.py` comments the signal as "same command 3+ times **with failures between**"
but the code never checks for an error result. Faber implements the intended, error-gated
version (`Faber.Detect.count_retry_loops`). **Recommend backporting the error-gate to the
plugin's `compute-metrics.py`** — it materially changes which sessions rank as high-friction
(retry_loops stopped over-firing; dominant signal shifted to context_compactions /
user_corrections).

## 3. Friction sigmoid saturates → rank/select also by *rate* — IMPLEMENT (A)
`score = sigmoid(raw)` pins to ~1.0 on long sessions, so it can't order them; we rank by `raw`.
But `raw` favors *long* sessions with lots of total friction over *short, intensely painful*
ones. A friction **rate** (`raw / message_count`) surfaces concentrated friction. Added a
`rate` field to `Scan.Result` and a `:rank_by` option (`:raw | :rate`) so the proposer can pick
"most painful per message," not just "longest."

## 4. The autoresearch loop keeps on ties (lateral churn) — DONE in Faber / REPORT to plugin
The plugin's loop keeps a mutation when `composite >= prev_best` (ties kept). The SkillOpt
research it cites says accept only strict improvements. `Faber.Loop` requires `composite > best`,
which makes plateau detection real and the loop converge. **Recommend the plugin adopt strict
improvement** (or a min-delta) to stop lateral churn.

## 5. Plugin `references/` files prompt for permission in subagent contexts — DONE
Skills loaded by subagents can't read `${CLAUDE_SKILL_DIR}/references/*.md` without a permission
dialog the subagent can't answer. So execution-critical content must be **inlined** in SKILL.md.
The proposer's `render_skill_md/1` keeps decision content inline and uses references only as a
supplementary stub. (Keep this invariant if the renderer grows.)

## 6. The eval sidecar is pure-stdlib → structural eval needs no Python — IMPLEMENT (B)
The plugin's `lab/eval` is stdlib + PyYAML; only `trigger_scorer` (the `claude` CLI) and GEPA
need anything heavy. So the "Python ecosystem" rationale only really applies to GEPA. We added a
**native Elixir structural scorer** (`Faber.Eval.Native` + `Faber.Eval.Matchers`) and made it the
**default eval engine** — the common path (structural gating) now runs in-process with no
`python3`. The Python sidecar stays available (`engine: :sidecar`) for parity and as the future
home for GEPA / trigger accuracy. This removes a runtime dependency from the hot path and a
process-spawn per eval (matters a lot inside the loop).

## 7. `req_llm` is a heavy, key-gated dep → default to the keyless CLI — IMPLEMENT (C)
`req_llm` pulled ~15 transitive deps (finch, mint, zoi, jsv, llm_db, websockex, ex_aws_auth …)
for a single `generate_object` call, and needs an API key. `Faber.LLM.ClaudeCLI` (claude -p) is
keyless and uses existing auth. Made **ClaudeCLI the default backend** (base config, not just
dev); ReqLLM stays opt-in for the network/CI path. (Left req_llm in the tree — dropping it
removes the network path and isn't worth it yet; revisit if we want a slimmer release.)

## 8. Bleeding-edge OTP 29 / Elixir 1.20 dep warnings — NOTE
yamerl (`'catch'` deprecation), hpax (bitstring `size` pin), toml/yamerl (single-quoted
charlists) emit deprecation warnings on compile. They're in deps, not our code (our compile is
`--warnings-as-errors` clean). Watch for breakage on the next OTP bump; no action now.

## 9. The dashboard scanned on every mount (static + connected) — IMPLEMENT (D)
`DashboardLive.mount` ran `Faber.Scan.run` on both the static and the connected render — two full
scans of ~4,600 files (~3.5s each) for the first paint. Now it scans **only when
`connected?(socket)`** (static render shows a "scanning…" state), halving the work and making
first paint instant. (A TTL cache / `assign_async` is the next step if needed.)

## 10. Privacy boundary: only friction *summaries* leave the machine — NOTE / guarantee
The proposer sends the LLM the friction *signals, fingerprint, and missed-opportunity list* —
**not raw transcript text**. Worth keeping as an explicit guarantee: if we later feed transcript
excerpts to improve proposals, that crosses a privacy line and should be opt-in. Faber is
local-first; the only outbound calls are the chosen LLM backend.

## Net recommendations (priority order)
1. (Plugin) Backport the retry-loop error-gate (#2) and strict-improvement loop (#4).
2. (Faber) Native eval default (#6) + keyless LLM default (#7) — both shipped here.
3. (Faber, future) Dashboard scan cache/`assign_async` (#9); friction-rate-driven proposer
   selection (#3, field added).
