---
scriptorium: true
action: create
title: "Deterministic Evaluator Sidesteps Reflective-Optimization Variance Failure"
type: pattern
domain: general
tags: [prompt-optimization, evaluation, gepa, reflective-evolution, variance, faber]
---

# Deterministic Evaluator Sidesteps Reflective-Optimization Variance Failure

**Claim.** The central failure mode of reflective / black-box prompt optimization — *edits whose
effect size is smaller than evaluation variance, so the loop samples noise rather than signal*
(see [[Bounded Factor-Level Prompt Optimization]], [[Prompt Optimization Under Noise]]) — assumes a
**stochastic evaluator**. If your evaluator is **deterministic**, that failure mode largely
disappears: the same candidate always scores identically, so *all* between-candidate variance is
signal. Generation stochasticity (the LLM producing the candidate) remains, but a strict-improvement
keep/revert ratchet absorbs it.

**Why it matters.** It changes the cost/benefit of running an evolve→eval→keep loop at all:

- With a **stochastic evaluator** (LLM-judge, small gold set, sampled rollouts): you must spend the
  budget on *evaluation signal quality* first — repeated sampling, racing, variance-based stopping,
  Pareto/best-feasible selection — before prompt edits are worth chasing. This is the enaia regime.
- With a **deterministic evaluator** (structural matchers, exact-match metrics, compile/test pass):
  a single eval per candidate is enough to separate winners from losers. The loop can be cheap and
  greedy-but-correct: keep iff `composite > best`, else revert.

**Worked example — Faber (2026-06).** Faber's skill-quality eval is a set of pure structural
matchers (frontmatter/section/ref/safety checks) → a weighted composite. Because it is deterministic,
its keyless reflective loop (`Faber.Loop` `:reflect` strategy / `Faber.Optimize.reflect/3`) can:
1. re-score the current best for free,
2. pick the weakest dimension + failed checks as targeted feedback (credit assignment), and
3. ask the LLM for a focused edit,
without any of the variance machinery the enaia extraction work needed. The decision to hand-roll
this in Elixir rather than adopt `dspy.GEPA` (DSPy runtime + API key) is documented in Faber's
`.claude/research/2026-06-23-gepa-reflective-loop-decision.md`.

**Caveat — partial determinism.** If any *one* dimension of a composite is stochastic (e.g. an
LLM-judged "behavioral / trigger accuracy" dimension), the variance returns *for that slice*. Keep
stochastic dimensions off the hot/default gate, or average them before they enter the composite.
Faber keeps its trigger-accuracy dimension opt-in and off the default structural gate for exactly
this reason.

**Corollary.** When choosing an optimizer, classify the evaluator first. Deterministic → a simple
greedy reflective loop is fine and cheap. Stochastic → invest in [[Three-Set Evaluation Strategy for
Prompt Optimization]] + [[Constrained Multi-Objective Prompt Selection]] before the optimizer matters.

Related: [[GEPA]], [[Bounded Factor-Level Prompt Optimization]], [[Faber]].
