---
scriptorium: true
action: append
title: "Deterministic Evaluator Sidesteps Reflective-Optimization Variance Failure"
type: pattern
domain: general
tags: [prompt-optimization, evaluation, gepa, reflective-evolution, ceiling, faber, methodology]
---

## Empirical confirmation + corollary (Faber, 2026-06-26): measure the eval ceiling before adopting a heavy optimizer

The "deterministic evaluator → cheap greedy reflective loop is enough" claim was put to a direct
test in Faber when deciding whether to wire `dspy.GEPA` (heavy, keyed, breaks the keyless boundary)
over the existing keyless reflective loop (`Optimize.reflect/3`, `claude -p` + a deterministic
structural composite).

**Measurement.** Ran the reflective loop to convergence on a real friction finding, 2 independent
runs (sonnet, target 1.0): baseline composite avg 0.967 → **final avg 1.000**; both cleared the gate;
**headroom to 1.0 = 0.0**. In one run the *initial proposal* already maxed the composite; in the
other a single reflective edit took 0.933 → 1.0.

**Corollary — classify *and measure* before buying a heavier optimizer.** A heavy optimizer (GEPA,
MIPRO, RL) can only capture headroom that exists. If a cheap loop already drives a deterministic
evaluator to its **ceiling**, the heavier engine has *nothing to optimize* — the binding constraint
is the **evaluator's expressiveness**, not the optimizer's power. So the cheap pre-req before adopting
any heavy optimizer is: *measure the current loop's ceiling on representative inputs.* Only a measured
**material plateau below the achievable maximum** justifies the spend.

This also tells you *what* to fix when you want better artifacts: not a stronger optimizer, but a
**harder/richer eval** (e.g. promote a stochastic behavioral/trigger dimension into the gate) — which
loops back to this pattern's caveat: a stochastic dimension reintroduces variance and is the point at
which the heavier, Pareto-style machinery (GEPA) finally earns its cost.

(Faber full reasoning + the falsifiable revisit conditions:
`.claude/research/2026-06-23-gepa-reflective-loop-decision.md`.)
