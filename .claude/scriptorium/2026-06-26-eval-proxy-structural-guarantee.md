---
scriptorium: true
action: create
title: "Eval proxies need structural renderer guarantees, not metric-gaming"
type: pattern
domain: general
tags: [eval, llm, codegen, metrics, goodhart, dogfooding, quality-gates]
---

# Eval proxies need structural renderer guarantees, not metric-gaming

A reusable principle for any system that **generates artifacts with an LLM and gates them with a
deterministic eval** (skill/prompt/doc generators, codegen, scaffolders, RAG answer graders). Found
while dogfooding Faber's skill proposer, but it generalizes.

## The situation

A deterministic eval scores generated output on proxy checks (e.g. "action density ≥ 0.25", "has a
fenced example with ≥2 lines", "description ≤ 250 chars"). Output keeps failing a dimension even
though it's *good*. Two very different root causes hide here, and they demand **opposite** fixes:

1. **The renderer cannot pass the proxy on a valid LLM draw.** Optional sections render empty; a
   fenced block can collapse to one line; a required marker is sometimes absent. The gate is then
   measuring luck, not quality.
   → **Fix the generator structurally.** Presence-gate sections, guarantee a ≥2-line block by
   construction (a comment line over the value), inject required structure regardless of model
   output. This *raises the floor* — every valid draw now passes.

2. **The model produced genuinely good content that a proxy happens to penalize.** e.g. a 287-char
   description that includes a valuable "NOT for …" disambiguation clause, vs a 250-char cap.
   → **Do NOT add a deterministic shim** (truncate/clamp) to force the proxy green. That games the
   metric against its own intent and *degrades the real artifact* (Goodhart's law). This belongs to
   the content optimizer (a reflective/iterative loop), not the renderer.

## The rule

> Fix the **generator structurally** when the renderer can't pass regardless of the model.
> **Never** add a shim that satisfies a proxy by lowering real output quality.
> The first raises the floor; the second corrupts the metric.

## How to tell which case you're in

- Probe the matcher against the **actually-rendered artifact**, not a fixture — render paths diverge
  (Faber's built-in renderer passed `has_examples`; its adapter-template path didn't, on the same
  proposal). The fixture lies; the real output doesn't.
- Ask: *"Can a valid, high-quality LLM draw fail this check?"* If yes → case 1 (structural fix). If
  the only way to pass is to remove something good → case 2 (don't shim; optimize content instead).

## Testing corollary

When you add a structural guarantee, assert it **independently of the matcher** (e.g. count the
fenced block's non-empty lines directly), so a later change to the matcher's regex can't silently
"pass" the test without the renderer actually holding the guarantee.

## Source

Faber skill proposer: empty `## Workflow`/`## Patterns` + a one-line Usage fence failed the eval's
`clarity` dimension (action_density + has_examples). Structural fixes took clarity 0.50 → 1.00. The
over-long description (`triggering` 0.67) was deliberately left to the reflective loop, not clamped.
