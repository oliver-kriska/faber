# Behavioral Eval & Trigger Accuracy for Faber

**Date:** 2026-06-26  
**Status:** Research complete — actionable recommendation included  
**Context:** Structural composite at 1.0 → binding constraint shifted to eval expressiveness.

---

## Question

Faber's `Faber.Eval.Native` + Python sidecar (`scorer.py`) is a deterministic structural eval
(6–8 dimension composite: frontmatter, sections, length, examples, safety). The reflective loop
now drives this to 1.0 with no headroom. A structural 1.0 means "well-formed," not "triggers
when it should and helps when loaded." How should Faber measure behavioral quality?

---

## What Faber Has Today

### Structural gate (always-on)
Six composite dimensions in `DEFAULT_EVAL` (`scorer.py` / `Faber.Eval.Native`): completeness,
conciseness, triggering, safety, clarity, specificity. The `triggering` dimension is **static
structural checks**: description length (50–250 chars), no vague words, description structure
heuristic. It does **not** run the description against any example inputs.

### Behavioral trigger eval (opt-in, `trigger: true`)
`Faber.Eval.Trigger` (`lib/faber/eval/trigger.ex`) is **already implemented** and **already
wired** into `Faber.Eval.score/2` as an opt-in dimension. It:

- Reads `%Proposal{should_trigger: [...], should_not_trigger: [...]}` (populated by the
  proposer from LLM output — `propose.ex` lines 319–320).
- For each phrase, calls `LLM.generate_object/3` with a routing question: "Should this skill
  activate for this request? Return `triggers: true/false`."
- Computes accuracy/precision/recall from TP/FP/FN/TN counts.
- Folds results into the composite as the `behavioral` dimension at weight 0.10 when
  `trigger: true`.

The Python `trigger_scorer.py` **does not yet exist** in `python/faber_eval/` (only
`scorer.py`, `matchers.py`, `optimize.py`, `cli.py`, `__main__.py`, `__init__.py` are
present). The sidecar's comment in `scorer.py` says behavioral "is folded in by the Elixir
`Faber.Eval` layer (it needs an LLM, not this pure scorer)." The Elixir implementation is
the canonical home.

### Tests
`test/faber/eval_trigger_test.exs` covers the trigger scorer with deterministic doubles
(PerfectRouter, AlwaysYes). The behavioral fold path is tested via stub LLMs, not a live model.

---

## Options

### 1. Trigger Accuracy (already partially implemented)

**What it measures:** Does the generated description route the agent into this skill for the
right user phrasings? Precision and recall over `should_trigger`/`should_not_trigger` fixtures.

**What's missing:**
- The proposer generates `should_trigger`/`should_not_trigger` from the LLM, but **fixture
  quality is unvalidated**. If the LLM writes easy fixtures that trivially pass, accuracy
  games itself.
- Single-model routing: the judge is the same model that would load the skill. Cross-model
  coverage (Haiku vs Sonnet vs smaller models) is unimplemented (the reference plugin's KB
  article plans a `--model` flag in T1.3).
- No labeled gold set: there are no human-annotated positive/negative examples for a given
  friction domain. All fixtures are LLM-generated, not validated.

**Approaches (in order of effort):**

a. **Current path: LLM routing judge with forced structured output** (already done)  
   `LLM.generate_object/3` returns `{triggers: bool}`. This is a forced binary verdict —
   exactly what the 2025–2026 literature identifies as the most reliable LLM-judge format
   (binary > Likert, structured JSON output > prose parsing). The Faber implementation
   matches the reference plugin's plan to replace prose parsing with forced tool verdicts
   (KB: "T2.2 replaces this with forced tool-call grading — verdicts deterministic by
   construction").

b. **Fixture quality gate: require ≥N fixtures, validate polarity balance**  
   Add a matcher or proposer-side check: require ≥3 `should_trigger` and ≥3
   `should_not_trigger` examples. Flag if all fixtures are paraphrases of the description
   (embedding cosine similarity > 0.95 → likely trivial positives).

c. **Embedding similarity pre-filter**  
   Before calling the LLM, compute cosine similarity between each fixture and the
   description embedding. Flag fixtures that are too close (trivial positive) or too far
   (adversarial synthetic negative). This costs one embedding call per fixture but catches
   degenerate fixture sets without LLM overhead. Effort: medium (requires an embedding model
   or API).

d. **Labeled friction set from mined sessions**  
   Use `Faber.Ingest` to extract real user phrasings that caused friction. Label them as
   should/should-not for a given skill domain. This gives a non-LLM-generated ground truth.
   Effort: high (needs labeled sessions, which requires Oliver's curation).

**Variance caveat (per KB pattern "Deterministic Evaluator Sidesteps Reflective-Optimization
Variance Failure"):** The trigger eval is **stochastic** — same description + same phrase may
get different LLM verdicts across runs. If folded into the gate composite, variance returns for
that slice. Mitigations:
- Run at temperature 0.0 (already a `LLM.generate_object` concern — confirm the ClaudeCLI
  backend supports it).
- Average over 3–5 samples per fixture before computing accuracy (adds cost but reduces
  variance substantially).
- Keep it off the deterministic gate (current design is correct: `trigger: true` is opt-in).

---

### 2. LLM-as-Judge Behavioral Dimension (description quality, intent clarity)

**What it measures:** Does a human-proxy judge agree that the description communicates the
skill's purpose clearly, and that an agent would understand *when* to load it?

**Designs (lowest variance first):**

a. **Binary pointwise rubric, structured output, temperature 0**  
   Single question per criterion: "Does this description unambiguously state the triggering
   condition? Answer yes/no with one sentence of evidence." Binary > Likert (per KB
   "Code-Based Evals vs LLM-as-Judge" and 2025 DeepEval guide). Structured JSON output
   eliminates parsing ambiguity.

b. **Criterion-by-criterion reasoning (chain-of-thought)**  
   Best current practice (2026 LLM-as-Judge best practices): explicit reasoning per rubric
   item reduces inter-judge variance on hard subsets more than just prompting for a number.
   Cost: ~2× tokens vs direct verdict.

c. **Pairwise comparison with position swap**  
   Compare two candidate descriptions for the same skill; swap positions and re-run; accept
   winner only if consistent. Effective for relative quality but expensive (2× calls per
   pair). Useful for the reflective loop (compare previous vs proposed edit), not for
   absolute gate.

d. **Ensemble (panel of 3 small models, majority vote)**  
   High variance mitigation but 3× cost. Justified only if the pool of skills is small
   (Faber is generating one skill per session, not 40/day).

**Practical recommendation:** Binary rubric, structured output, temperature 0, single call.
Validate against a small gold set of 20–30 human-rated examples before trusting the dimension.
Track Cohen's kappa ≥ 0.7 vs human labels as the quality bar (per the hamel.dev guide).

**Variance relation to "Three-Set Evaluation Strategy":** That pattern (discriminative dev
slice, locked fragile set, full holdout) applies when optimizing a prompt with many evaluation
examples. For Faber's per-skill judge, the analog is: lock 5–10 "known-good" and "known-bad"
examples as a calibration set, run the judge on them, and gate only if calibration accuracy
≥ 0.80 before trusting the production verdict. This costs ~15 extra LLM calls but prevents
judge drift.

---

### 3. Outcome/Efficacy Eval (does the skill reduce friction when loaded?)

**What it measures:** Does a session with the skill loaded produce fewer friction signals than
a session without it?

**Tractability assessment (honest):**

| Approach | Feasibility for local-first tool | Effort |
|---|---|---|
| A/B in production (live agents) | Not feasible: Faber is local, not multi-tenant | N/A |
| Replay with/without skill | Partially feasible: replay a mined session through `claude -p` with vs without the skill in CLAUDE.md; compare session length, error recovery patterns, explicit-friction signals | High |
| Synthetic task harness | Feasible: generate 3–5 synthetic tasks for the skill's domain; measure whether the LLM invokes the skill and whether the task succeeds. SWE-Replay pattern (2025) does this for software engineering agents | Medium-High |
| Session-diff monitoring (post-install) | Feasible and low-effort: after install, compare friction-signal rates in sessions before vs after the skill was present. Requires `Faber.Ingest` to emit per-skill attribution, which it doesn't yet | Medium |

**Honest bottom line:** True outcome efficacy measurement requires either replay infrastructure
(expensive to build) or post-install session monitoring (requires enough post-install sessions
to be statistically meaningful, which for a local-first tool may be 1–2 sessions). The
"session-diff monitoring" path is the most tractable: instrument the ingest pipeline to tag
sessions with active skills at the time, compute friction-signal rate before/after a skill was
installed, surface the delta as a "did-it-help?" score. This is a 2–3 week build.

For v1, the pragmatic substitute is the **trigger eval + a synthetic task check**: generate
3 mini-tasks for the skill's domain using the same LLM; run `claude -p` with and without the
skill in context; measure invocation rate and task completion quality via a structural judge.

---

## Recommendation (phased, opt-in)

### Phase 1 (now, near-zero effort): Surface the behavioral dimension Faber already has

`Faber.Eval.Trigger` is implemented, tested, and wired. The proposer (`propose.ex`) already
asks the LLM to emit `should_trigger`/`should_not_trigger` fixtures. The only missing piece
is **turning it on by default in the loop** or at least in the CLI report.

**Changes needed:**
1. Add `--trigger` flag to `mix faber.propose` (or always include it in `mix faber.scan`).
   This makes `Faber.Eval.score(proposal, trigger: true)` the default, adding the
   `behavioral` dimension to every proposal score.
2. Add fixture quality guard in `Faber.Propose`: require ≥3 fixtures per polarity; warn (not
   fail) if the set looks trivial (all fixtures are paraphrases of the description).
3. Confirm `LLM.generate_object/3` sends temperature 0 to the ClaudeCLI backend (or add it
   as a default opt). This makes the behavioral verdict as stable as a binary judge can be.

**Cost:** ~3 LLM calls per proposal (1 per fixture, with a minimal 3+3 set). Keyless with
ClaudeCLI. Does not touch the deterministic gate — behavioral folds in at weight 0.10 as the
8th dimension, exactly as designed.

### Phase 2 (1–2 weeks): Fixture diversity check via embedding pre-filter

Before sending fixtures to the routing judge:
- Compute embedding similarity of each `should_trigger` phrase to the description.
- Flag if similarity > 0.9 (trivially copied from description) or if all negatives are
  semantically distant from the domain (too easy to distinguish).
- Emit warnings in the eval report; don't block the gate.

Requires choosing an embedding backend: `mix_embed` hex package (local, no API) or a
dedicated embedding call via `Faber.LLM`. The local option is preferred (Faber is
local-first).

### Phase 3 (2–4 weeks): Synthetic task check (mini outcome eval)

For each proposed skill:
1. Use the same proposer LLM to generate 3 "synthetic friction tasks" for the skill's domain.
2. Run `claude -p --system <with-skill>` vs `claude -p --system <without-skill>` on each
   task.
3. Count: does the with-skill run invoke the skill? Does it produce fewer tool-error events?
4. Emit a `synthetic_efficacy` score (not gated — informational only).

This is the minimal outcome eval that is tractable for a local-first tool without replay
infrastructure. Based on the SWE-Replay pattern (2025): generalizable across agent scaffolds,
implementable in ~500 lines.

### Phase 4 (future): Post-install session monitoring

After a skill is installed, `Faber.Ingest` attributes incoming sessions to the set of active
skills at session time. Compute friction-signal rate before vs after install date. Surface the
delta in `mix faber.status` as a "did-it-help?" trailing indicator. This closes the loop from
"generated well-formed skill" to "demonstrably reduces friction."

---

## The Key Design Invariant: Keep Stochastic Off the Gate

Per the KB pattern ("Deterministic Evaluator Sidesteps Reflective-Optimization Variance
Failure"), adding any stochastic dimension to the deterministic composite reintroduces variance
into the reflective loop. The behavioral dimension **must stay opt-in and weighted lightly**
(current design: weight 0.10, `trigger: true` required). The deterministic 6-dimension
structural gate remains the loop's ratchet; behavioral is a separate, informational signal
surfaced in the report.

If the behavioral score becomes a hard gate criterion, the loop will begin gaming it: the LLM
will tune descriptions to pass specific fixtures rather than to genuinely improve routing. The
fixtures are LLM-generated, so the loop and the fixtures are in the same distribution — a
closed loop that can self-satisfy without improving real-world routing. Avoid this by keeping
behavioral as an advisory dimension and validating fixture quality separately.

---

## Open Questions

1. **Fixture quality validation without human labels:** Is embedding distance a sufficient
   proxy for "are these fixtures non-trivial," or do we need human-curated examples per skill
   domain? The reference plugin's eval achieves this by caching Haiku trigger tests across
   all 38 skills — a corpus that grew through iteration. Faber can follow the same path.

2. **Cross-model trigger accuracy:** The trigger judge uses the same model family that runs
   the skill. A description that routes well on Sonnet may route poorly on Haiku. Is this a
   concern for Faber's target users (who may be running smaller local models)? If yes, Phase
   1 should add a `--trigger-model haiku` option to `mix faber.propose`.

3. **Fixture source:** Currently the proposer asks the same LLM that generated the skill to
   also generate the fixtures. This creates circular validation. The cleanest fix is to mine
   fixture candidates from **real session phrases** (from `Faber.Ingest` output) and use those
   as the routing test set rather than synthetic ones. Session-sourced fixtures are not
   distribution-matched to the description — they are actual phrasings that caused friction,
   which is exactly what the skill is meant to handle.

4. **Reporting:** The behavioral dimension currently appears in the score result map but is not
   surfaced in the CLI output. Add a "Trigger accuracy: X/Y fixtures (precision P, recall R)"
   line to `mix faber.propose` output before calling Phase 1 done.

---

## Sources

**KB articles consulted:**
- `scriptorium/wiki/deterministic-eval-sidesteps-variance.md` — Faber's own pattern for why
  keeping stochastic off the gate is correct; documents the design decision.
- `scriptorium/tools/lab-eval-skill-agent-evaluation-system.md` — reference plugin's 8-dim
  eval, behavioral haiku trigger tests, T2.2 forced tool-call verdict plan.
- `scriptorium/wiki/patterns/code-based-evals-vs-llm-as-judge.md` — decision rule: code evals
  for objective/structural checks; LLM-J only for subjective; validate judge with gold set.
- `scriptorium/decisions/plugin-eval-framework.md` — reference plugin decision: hybrid
  structural + behavioral, 0.95 threshold, session monitoring as post-deploy complement.
- `scriptorium/patterns/evaluation-scheduling-for-prompt-optimization.md` — three-set
  architecture (discriminative dev, fragile set, holdout); calibrate before promoting.

**Web sources:**
- [LLM-as-Judge Best Practices 2026 — FutureAGI](https://futureagi.com/blog/llm-as-judge-best-practices-2026)
- [LLM as a Judge Complete Guide — OpenLayer (March 2026)](https://www.openlayer.com/blog/post/llm-as-judge-evaluation-guide)
- [Using LLM-as-a-Judge For Evaluation: A Complete Guide — hamel.dev](https://www.confident-ai.com/blog/why-llm-as-a-judge-is-the-best-llm-evaluation-method)
- [Am I More Pointwise or Pairwise? Position Bias in Rubric-Based LLM-as-a-Judge (arXiv 2602.02219)](https://arxiv.org/html/2602.02219)
- [Rubric-Conditioned LLM Grading: Alignment, Uncertainty, Robustness (arXiv 2601.08843)](https://arxiv.org/pdf/2601.08843)
- [SWE-Replay: Efficient Test-Time Scaling for Software Engineering Agents (arXiv 2601.22129)](https://arxiv.org/pdf/2601.22129)
- [The Measurement Imbalance in Agentic AI Evaluation (arXiv 2506.02064)](https://arxiv.org/pdf/2506.02064)
- [Incentivizing Agentic Reasoning in LLM Judges via Tool-Integrated RL (arXiv 2510.23038)](https://arxiv.org/pdf/2510.23038)
- [What is LLM-as-a-Judge? — Braintrust](https://www.braintrust.dev/articles/what-is-llm-as-a-judge)
