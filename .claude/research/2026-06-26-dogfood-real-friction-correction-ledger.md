# Dogfood run: Faber on real cross-agent sessions (2026-06-26)

**What:** Ran Faber's full pipeline end-to-end on real local sessions, keyless (`Faber.LLM.ClaudeCLI`
→ `claude -p`, no API key), during a free-token window. Scan → pick top friction → propose skill →
eval gate → behavioral trigger eval. This is the first real-data (non-fixture) exercise of the whole
M2→M4 path.

## Scan (M2) — works at scale

`mix faber.scan` over `~/.claude/projects`: **1446 non-trivial sessions in 5.6s**, 1235 tier-2
eligible, ranked by weighted friction. Dominant signals across the top 20 were `user_corrections`,
`context_compactions`, and `retry_loops` — i.e. real, recognizable pain, not noise. Fingerprints
(maintenance / bug-fix / feature / review) and opportunity scores populated sensibly.

## Propose + eval (M3/M4) — convergent, gate-passing skill

Two **independent** real sessions, proposed separately:

| Rank | Session | Friction | Dominant | Composite | Trigger acc |
|------|---------|----------|----------|-----------|-------------|
| 1 | faber (this project) | 137 (maintenance) | user_corrections (29) + compactions (29) | **1.00 PASS @ 0.75** | 0.75 (6/8) |
| 9 | xuku-enaia bug-fix | 59.5 (bug-fix) | user_corrections (11) + compactions (12) + interrupts (4) | **1.00 PASS @ 0.75** | 0.80 (8/10) |

**Headline: both converged on the same novel skill — `correction-ledger`.** Diagnosis (identical
across the two, reached independently): in long sessions the agent re-violates directives the user
already gave, because each **context compaction wipes the corrections from context**, forcing the
user to re-issue them. Proposed fix: pin every correction to a durable in-repo file
(`.claude/ledger/<branch>.md` / `.claude/corrections.md`), re-read after each compaction, cite the
governing entry before an edit, resolve (not delete) satisfied entries.

Why this is a strong result:

- **Convergent validity.** Two unrelated codebases/sessions → same diagnosed friction → same skill.
  The detector is finding a *recurring* pattern, not over-fitting one transcript.
- **Novelty + non-duplication.** The proposer explicitly reasoned that `correction-ledger` is
  distinct from already-used skills (`learn-from-fix`/`compound` write post-hoc solution docs;
  `context-budget` hoards investigation output) — it read the adapter's skill conventions and avoided
  proposing a dupe.
- **Adapter-grounded specificity.** Iron Laws cite real Elixir conventions (`:decimal` for money,
  streams >100 items, authorize every `handle_event`, `connected?/1` before PubSub) — the
  faber-elixir adapter's knowledge flowed into a domain-correct artifact.
- **Gate held honestly.** Native structural eval = 1.00 across all 7 dimensions; behavioral trigger
  eval (real `claude -p` per fixture) = 0.75–0.80, i.e. the proposal's own should/shouldn't-trigger
  fixtures are mostly but not perfectly routed — a believable, non-gamed number.

## Notes / caveats

- Adapter eval ran as native default (log: "adapter eval is exec-in-place; using default native
  scoring … referenced scorer integration is env-bound — ADAPTER_CONTRACT §7"). The vendored-dims /
  exec-in-place adapter scorer path was not exercised here; structural+behavioral default was.
- Artifact written to `proposals/correction-ledger/SKILL.md` (untracked; not committed — it's an
  output). **Not installed** to `~/.claude/skills` (that writes the user's shared dir → needs
  explicit opt-in via `--install` / the Install provenance path).
- The `correction-ledger` skill is itself a genuinely useful workflow fix for *this* user (this very
  session had multiple compactions) — a candidate to actually adopt, independent of Faber.

## Loop (M5) + install — confirmed ceiling on real data

`Faber.Loop.refine(rank1, adapter, strategy: :reflect, trigger: true, target: 0.95)` →
`status=complete, iterations=1, best_composite=1.0, candidates_tried=1`. The reflective loop
**stopped immediately with no refinement**: the seed already met target (composite 1.0 ≥ 0.95), so
there was no gradient. This empirically reconfirms the GEPA-deferral / zero-headroom finding
(`2026-06-23-gepa-reflective-loop-decision.md`) on real data — the behavioral `trigger` fold opens
no headroom because the rank-1 seed cleared all three behavioral thresholds (acc≥0.75, prec≥0.80,
recall≥0.60) so `behavioral` = 1.0. **To make the loop push raw trigger accuracy higher, the eval
must reward accuracy continuously, not as a 0.75 pass/fail step** — i.e. a stochastic/continuous
objective, exactly GEPA's regime.

Installed the winner to `~/.claude/skills/correction-ledger/SKILL.md` with a `.faber.json`
provenance marker (`installed_by:faber`, adapter, source_session, fingerprint). The loop closed
end-to-end: the skill became loadable in the same session whose friction produced it.

## Continuous behavioral reward + the stochasticity finding (follow-up)

Changed `Faber.Eval.fold_behavioral/2` so the `behavioral` dimension scores **continuously** (mean of
raw accuracy/precision/recall) instead of `passed/total` over three boolean thresholds (commit
`fb1cd7b`, unit-proven: a skill that clears every threshold but isn't perfect now scores 0.833 /
composite < 1.0 where the old step-function pinned at a flat 1.0). This is what gives the reflective
loop a gradient to push routing higher — bounded impact since behavioral weight is only 0.10, so a
structurally-perfect skill still passes the gate.

Re-ran `Loop.refine(rank1, reflect, trigger: true, target: 1.0)`: `status=complete, iterations=1,
trajectory=[{kept: true, 1.0}]`. The seed scored **composite 1.0 this run** — i.e. the LLM routed
every trigger fixture correctly. But the *same* session's earlier propose scored trigger accuracy
**0.75**. **Same skill, same fixtures, different `claude -p` calls → 0.75 vs 1.0: the trigger
objective is stochastic.**

Implication (reinforces `2026-06-23-gepa-reflective-loop-decision.md` and
`deterministic-eval-sidesteps-reflective-opt-variance`): the continuous reward correctly exposes a
gradient *when a gap exists*, but the gap appears/disappears with LLM noise. Greedy single-sample
keep/revert over a noisy objective is fragile — it'll "keep" a candidate that merely got a lucky
routing draw. Optimizing a stochastic objective properly needs multi-sample evaluation per candidate
(average N trigger runs) and/or a dataset-based optimizer (GEPA) — exactly the regime the deferral
decision reserved GEPA for.

**Implemented (commit `c455fef`):** opt-in `trigger_samples: N` on `Faber.Eval.Trigger.score/2` (and
`mix faber.propose --trigger-samples N`) repeats the eval N times and **pools** the results
(micro-average), so the behavioral score is a stable estimate over N×fixtures with an
`accuracy_stdev` that quantifies the noise. `samples: 1` is byte-for-byte the original behavior (no
cost change). This makes the continuous behavioral gradient (`fb1cd7b`) trustworthy — the loop now
optimizes a stable estimate rather than one Bernoulli draw. GEPA's dataset regime remains the
heavier option if multi-objective / many-shot optimization is later needed.

## Cross-agent dogfood on real data (follow-up) — engine is agent-agnostic end-to-end

The ingest seam shipped cline/gemini/opencode this session, but **neither CLI surface could select
them**: `mix faber.scan`/`mix faber.propose` had no `--format` switch (they `Keyword.take`'d only
`[:limit, :base, …]`, dropping `:format`), and `Faber.CLI.normalize_format/1` whitelisted only
`claude`/`codex` → the new formats silently fell to `nil` → a misleading **Claude** scan. Fixed by
adding `Faber.Ingest.Format.known/0` + `cast/1` (single source of truth; validates `--format`
without `String.to_atom` on user input) and routing all three entrypoints through it (commits
`bed30ab`, `966bdbb`). The mix tasks now fail loudly on a typo'd format; the binary keeps lenient
nil-fallback parity with `--source`/`--rank-by`.

Then dogfooded on **real local data** for the two non-Claude agents present on this machine:

| Agent | Source | Scan result | Notes |
|-------|--------|-------------|-------|
| OpenCode | real SQLite DB (`~/.local/share/opencode/opencode.db`, 292 KB) | 1 session, 5 msgs, 4 tools, 1 err → `error_tool_ratio` | validates sqlite3-CLI transport, message⋈part join, tool-name canonicalization |
| Codex | real rollout JSONL (`~/.codex/sessions/**`) | 10 sessions, 4 tier-2; top two (287/160 msgs) dominant `retry_loops` | rich, believable signals + fingerprints (bug-fix/review) |

**Headline — cross-agent propose works end-to-end.** `mix faber.propose --format codex --rank 1`
(keyless `claude -p`) on the top real Codex session (`019ef32f`, dominant `retry_loops`) generated a
gate-passing **"Bugfix Retry Tripwire"** skill (composite **1.00**, all 6 structural dims 1.00) whose
content maps *directly* to the detected signal ("after 3 fails escalate, never a 4th guess-edit").
Adapter-grounded in Elixir idioms (`mix test path:LINE`) — that Codex session was an Elixir project,
so the faber-elixir adapter's knowledge flowed into a domain-correct artifact. The detect→propose
chain is **agent-blind**: the same friction vocabulary and the same adapter produced a coherent skill
from a Codex transcript with zero engine changes. (Gemini/Qwen/Cline have no local data on this box →
fixture-covered only.)

## Repro

```sh
mix faber.scan                                   # rank real sessions
mix faber.propose --rank 1 --write proposals --trigger   # keyless full pipeline + behavioral eval
mix faber.propose --rank 9 --write proposals --trigger

# cross-agent (real non-Claude data):
mix faber.scan --format opencode --top 8         # real SQLite store
mix faber.scan --format codex --top 8            # real rollout JSONL
mix faber.propose --format codex --rank 1        # cross-agent propose → "Bugfix Retry Tripwire"
```

## Run against a real external project — enaia-main (follow-up)

First run against a large, actively-used external Elixir/Phoenix project (Oliver's `enaia`, worktree
`~/Projects/xuku/enaia-main`, 271 recorded Claude sessions) rather than Faber's own history. Scanned
that project's session dir directly (`--base ~/.claude/projects/-Users-oliverkriska-Projects-xuku-enaia-main`):
**259 non-trivial sessions, 231 tier-2**, top sessions genuinely huge (1030–3089 messages). Dominant
signals across the top 15: `context_compactions` (7×), `retry_loops` (5×), `user_corrections` (3×) —
the same recurring pain, at scale.

Proposed for three different friction types (keyless), all gate-passing:

| Rank | Signal | Skill | Composite | Triggering |
|------|--------|-------|-----------|------------|
| 1 | context_compactions | Bugfix Context Ledger | 1.00 | 1.00 |
| 3 | retry_loops | Break Retry Loop | 0.93 | 0.67 |
| 4 | user_corrections | Bugfix Correction Ledger | 1.00 | 1.00 |

Findings:
- **Signal-differentiated generation.** Each skill attacks its own dominant signal (compaction →
  read-offload to `Explore`/`deep-bug-investigator` subagents + post-compact ledger re-read;
  retry_loops → reproduce→isolate→one-hypothesis→`dbg/2`; user_corrections → verbatim capture, never
  re-apply a REJECTED approach). Not one generic template.
- **Convergent root cause within one project.** All three independently prescribe a *disk-backed
  ledger surviving autocompaction* — which is exactly enaia's #1 friction. Three entry points, one
  real fix (cf. the cross-session convergence on `correction-ledger` earlier).
- **Project-aware non-duplication.** Each proposal reasoned about skills the *session actually used*
  (read from the transcript) and positioned itself as complementary ("distinct from the generic
  correction-ledger and compound", "does not duplicate the already-used review/work/connected/example
  skills") — the proposer reads existing-skill context, not just the adapter's list.
- **Gate discriminates.** "Break Retry Loop" honestly scored triggering 0.67 (composite 0.93) — its
  routing description is weaker than the other two's 1.00; not a rubber stamp.
- **Overlap is real.** Ranks 1 & 4 are both "Bugfix … Ledger" — in practice one consolidated ledger
  skill beats three competing triggers (a future Faber consolidation step, or a human merge).

Installed all three (user opt-in) into the enaia-main worktree via `Faber.Install.install/2` with
`dir:` + provenance (`adapter`, `source_session`, `source_project`) → `.claude/skills/<name>/SKILL.md`
+ `.faber.json`. `list_faber_installed/1` returns exactly the 3 (filtered from enaia's ~30 own
skills); worktree git status showed only the 3 new untracked dirs — non-destructive. Left untracked
for the user to commit/discard (Faber never commits into the target project).

```sh
# repro (scan + propose against a real project's sessions):
mix faber.scan   --base ~/.claude/projects/-Users-oliverkriska-Projects-xuku-enaia-main --top 15
mix faber.propose --base ~/.claude/projects/-Users-oliverkriska-Projects-xuku-enaia-main --rank 1 --write proposals
# install into the project worktree: Faber.Install.install({name, md}, dir: "<worktree>/.claude/skills", provenance: %{…})
```

## Consolidation + behavioral eval — structural ≠ behavioral (enaia follow-up)

Merged the three enaia ledger proposals into one `bugfix-ledger` skill (single durable
`.claude/bugfix-ledger.md`: Hypotheses / Ruled out / Corrections; one trigger), force-reinstalled it,
and retired the three originals (`Install.list_faber_installed/1` → just `bugfix-ledger`).

Two findings, both about the **trigger**:

1. **Structural triggering is a length/structure proxy — tightening the description is a real fix, not
   gaming.** The first merged description (~500 chars, opened "Survive-compaction…") scored
   `triggering 0.33` (composite 0.87): it failed `description_length` (>250 max) and
   `description_structure` (`has_what` wants `^[A-Z][a-z]+\s` — "Survive-compaction" starts with a
   hyphen, not a space). Rewriting to a 242-char, "Durable bug-fix ledger … Use when …" description
   (plain leading word, `Use when`, no vague words) → `triggering 1.00`, composite **1.00**. This is
   the renderer-guarantee principle: satisfy the proxy by *improving* the artifact (a punchy routing
   description IS better), never by clamping.

2. **The behavioral trigger eval caught what the structural proxy could not.** 3-sample pooled
   (30 keyless `claude -p` calls): **precision 1.00, recall 0.40, accuracy 0.50 (σ=0.082)** →
   behavioral 0.633, composite-with-fold 0.967 (PASS). The structural proxy rated the trigger
   *perfect (1.00)*, but the real-LLM behavioral eval shows the consolidated description is
   **under-sensitive**: when it fires it's always right (no false positives), but it stays quiet on
   60% of the should-fire phrasings. **This is the consolidation tradeoff quantified** — folding three
   focused single-signal triggers into one concise trigger trades recall for a clean single router.
   It also validates *why Faber runs both evals*: structural (cheap, deterministic, gates form) +
   behavioral (LLM, stochastic, measures routing) are not redundant — the behavioral one found a real
   routing weakness invisible to structure. Because behavioral weight is only 0.10, recall 0.40 docks
   the composite by ~0.03 (still passes), so it's a *measurement*, not a gate failure — the lever for
   fixing it is the reflective loop / GEPA regime (optimize the stochastic recall), not the structural
   gate.
