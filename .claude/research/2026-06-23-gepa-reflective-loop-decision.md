# Self-improving loop: GEPA / DSPy feasibility → keyless reflective evolution (2026-06-23)

**Question (G1):** should Faber's self-improving loop adopt `dspy.GEPA` (the SOTA reflective prompt
optimizer), or hand-roll a keyless reflective loop in Elixir?

**Decision: hand-roll keyless reflective evolution in Elixir.** Do **not** take a `dspy` runtime
dependency for v1. Keep the `Faber.Optimize` Python sidecar as a documented *future* seam for
`dspy.GEPA`, but make the working v1 optimizer a reflective strategy in `Faber.Loop`.

## What GEPA actually is (grounding)

GEPA = **Genetic-Pareto** reflective prompt evolution (Agrawal et al., *GEPA: Reflective Prompt
Evolution Can Outperform Reinforcement Learning*, ICLR 2026 oral, arXiv 2507.19457). Mechanics:

1. **Reflect** on structured execution traces (inputs, outputs, failures, feedback) with an LLM,
   targeting one module, and propose new text tailored to the *observed* failures.
2. **Evolve** candidates derived from an ancestor, accumulating high-level lessons.
3. **Pareto front**: explore the top performers *per instance*, not just the global best, to dodge
   local optima.

Beats GRPO by ~6–19pp with up to **35× fewer rollouts**; productized as `pip install gepa` /
`dspy.GEPA`. (DSPy GEPA overview; Morph GEPA guide.)

## Why not `dspy.GEPA` for v1

- It needs the **DSPy runtime + a provider API key**. Faber's v1 sidecar boundary is deliberately
  **stdlib-only and keyless** (`python -m faber_eval`, no installs); the eval hot path is native
  Elixir. Pulling in DSPy + a key contradicts that boundary (confirmed in KB `research/gepa.md` and
  the existing `Faber.Optimize` moduledoc, which already reserves this as a *future* seam).
- Faber's LLM access is the **keyless** `Faber.LLM.ClaudeCLI` (`claude -p`). Reflection only needs
  "given a prompt, return a structured object" — which `Faber.LLM` already provides.

## Why the *current* loop needed the upgrade

`Faber.Loop.refine/3` re-proposed the skill **from scratch** every iteration (blind regeneration).
KB pattern `bounded-factor-level-prompt-optimization.md` (confidence: high) names this the failure
mode: a one-shot/holistic hill-climb on frontier models *samples noise rather than signal* because
"tiny lexical edits have effect sizes smaller than evaluation variance." Its prescribed alternative
when not adopting DSPy: **named factors → typed patches → discriminative evaluation → Pareto/strict
selection → variance-based stopping.**

## What we built (G2/G3)

A `:reflect` strategy for `Faber.Loop`, exposed as `Faber.Optimize.reflect/3`:

- **Credit assignment from the eval.** Each iteration re-scores the current best (native,
  deterministic, ~free) and finds the **weakest dimension** + its failed assertions (with evidence).
  Eval dimensions are the "named factors."
- **Targeted (factor-level) edit.** The weakness + the current `SKILL.md` are fed back into
  `Propose.propose/3` via a new `:feedback` option ("fix ONLY these; keep the strengths"). This is a
  derived-from-ancestor reflective mutation, not a blind rewrite.
- **Strict-improvement ratchet** (existing `Faber.Loop`): keep iff `composite > best`, else revert;
  git is the ratchet; plateau/iteration/target stop conditions.

## Why Faber sidesteps GEPA's central risk

The KB's main warning — *edits smaller than evaluation variance → the loop samples noise* — assumes a
**stochastic evaluator**. Faber's structural composite is **deterministic** (pure matchers): the same
`SKILL.md` always scores identically, so between-candidate variance *is* signal. The only
stochasticity is in the LLM's *generation* of candidates, which the strict-improvement revert handles.
(The behavioral/trigger dimension is LLM-stochastic, but it's opt-in and off the default gate.)

## Known limitation / future work

We use **greedy strict-composite** selection, not a **Pareto front**. The KB flags greedy
single-winner as wrong when one dimension improves while another regresses. For v1 the weighted
composite + strict-improvement is a reasonable, far simpler choice. A Pareto/best-feasible selection
(per the `Constrained Multi-Objective Prompt Selection` pattern) and a dspy.GEPA sidecar engine are
the documented next steps. Multi-instance Pareto would also need a *set* of friction findings to
optimize against, which the loop does not yet carry.

## Sources

- GEPA paper: https://arxiv.org/abs/2507.19457 (ICLR 2026 oral)
- GEPA repo: https://github.com/gepa-ai/gepa ; DSPy: https://dspy.ai/api/optimizers/GEPA/overview/
- KB: `research/gepa.md`, `patterns/bounded-factor-level-prompt-optimization.md`
  (`Hand-Rolled Bundle Prompt Optimization Pattern (Elixir)`, `Constrained Multi-Objective Prompt
  Selection` are the linked next-step patterns).

---

## Decision-gate resolution (2026-06-26): defer GEPA — do NOT wire `dspy.GEPA` now

Revisiting the post-v1 open step *"Compare GEPA vs reflective on a fixture: is the extra cost worth
it?"* before writing any dspy code. **Resolution: keep GEPA as the capability-gated `not_implemented`
seam it already is. Do not implement `_run_gepa_live` or the `:live_api` integration yet.** The
deferral is reaffirmed, now with explicit, falsifiable revisit conditions.

### Why (the decision rests on regime, not effort)

1. **Regime mismatch is the whole argument.** GEPA's measured edge (6–19pp over GRPO, ~35× fewer
   rollouts) and its KB-recommended use (`tools/dspy.md`: enaia's factorized CFG-constrained
   *extraction*) live in the **stochastic-evaluator, multi-objective, dataset-driven** regime.
   Faber's skill eval is **deterministic + single-document**. Per
   `[[deterministic-eval-sidesteps-variance]]`: deterministic evaluator ⇒ a greedy strict-improvement
   reflective loop "is fine and cheap"; the variance machinery GEPA brings solves a problem Faber
   does not have.

2. **The keyless loop already has GEPA's mechanism that matters here.** `Optimize.reflect/3` does
   credit-assignment from the eval (weakest dimension + failed checks → targeted feedback) → a
   factor-level reflective edit → strict-improvement git ratchet. What it lacks vs GEPA — a Pareto
   front over *instances* and accumulated cross-candidate lessons — has no payoff on a single
   deterministically-scored document (the loop carries one finding, not a dataset).

3. **Cross-project precedent says optimization is a cleanup pass, not the main loop.** enaia's
   waterbed analysis (7-iter loop, **14% success**, fixing one field regressed others) and its
   decision — *"prompt optimization should become a cleanup pass that earns the last stability
   points where the signal is real, not the main optimization loop"* — are the cautionary prior.
   That waterbed/regression is precisely the multi-objective stochastic pain GEPA's Pareto front
   addresses; Faber's deterministic composite + revert ratchet already sidesteps it.

4. **Cost & boundary.** Live GEPA breaks the stdlib-only keyless sidecar contract (needs `dspy` + a
   paid key) and spends real tokens per rollout for an exploratory, post-v1 engine. The
   `_run_gepa_live` surface also carries a **known dspy API-drift risk** (the `max_metric_calls`
   vs `auto`/`max_full_evals` budget kwarg and a likely-required `reflection_lm=`), so enabling it
   is non-trivial *and* unvalidated.

### The cheap test that should precede any GEPA build

The "is it worth it?" gate cannot be answered by building GEPA blindly. The cheap, in-regime proxy:
**measure the keyless reflective loop's ceiling on real skills.** If `Optimize.reflect/3` already
reaches composite ≈ gate (the dogfood run took `clarity` 0.50→1.00 structurally) on representative
proposals, there is little headroom left for GEPA to capture and the spend is unjustified. Only a
*measured material plateau below the gate* makes GEPA worth evaluating.

### Falsifiable conditions to revisit (any one flips the decision)

- A **stochastic dimension enters the default gate** (e.g. LLM-judged trigger/behavioral accuracy
  stops being opt-in) → variance returns → GEPA's machinery starts to earn its cost.
- The loop optimizes against a **set of findings at once** (multi-instance) → a Pareto front over
  instances becomes meaningful (today the loop carries a single finding).
- The reflective loop is **measured to plateau materially below the eval gate** on real skills →
  real headroom exists for a heavier optimizer.

Until one of these holds, the v1 posture stands: keyless reflective loop is the optimizer; GEPA stays
a documented, tested-at-the-boundary, `not_implemented` seam.
