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
