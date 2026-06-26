---
module: "Faber.Propose"
date: "2026-06-25"
problem_type: logic_error
component: eval_renderer
symptoms:
  - "Generated SKILL.md scores clarity 0.50 (composite 0.88) despite a sensible skill"
  - "action_density check fails: rendered skill has empty ## Workflow / ## Patterns sections"
  - "after fixing that, clarity still 0.50: has_examples fails — the Usage fence holds a single prose line"
root_cause: "the renderer could not STRUCTURALLY satisfy the deterministic eval's clarity sub-checks regardless of LLM output — empty optional sections and a one-line fenced block"
severity: medium
tags: [eval, proposer, renderer, clarity, action-density, has-examples, dogfooding, metric-gaming]
---

# Eval clarity gaps are renderer guarantees, not prompt wishes

## Symptoms

Dogfooding Faber on real `~/.claude` history: `mix faber.propose --rank 1` produced a genuinely
useful skill that nonetheless scored **clarity 0.50** (the weakest dimension; composite 0.88).
`clarity` is two checks (`lib/faber/eval/native.ex`): `action_density` (min_ratio 0.25) and
`has_examples` (≥1 fenced block with ≥2 non-empty lines).

- First pass: `action_density` failed — the rendered skill had **empty `## Workflow` / `## Patterns`**.
- After populating those: clarity *stayed* 0.50 — now `has_examples` failed, because the adapter
  template's only fenced block (`## Usage`) held a **single prose line**.

## Investigation

1. **"Prompt the LLM harder to fill the sections"** — partial. The system prompt already asked; the
   model sometimes complied, but the score swung with the draw. Not a guarantee.
2. **Probe the matcher against the actually-rendered file** (not a fixture) — revealed `action_density`
   counts numbered lines (`^\d+\.`), bold bullets (`^[-*]\s+\*\*`), imperative leads, and table rows
   as "actionable". Empty sections → no such lines.
3. **Re-probe after the Workflow/Patterns fix** — `action_density` jumped to 0.83 (pass), but
   `has_examples` now failed: it wants a fence with ≥2 non-empty lines; the template rendered one.
4. **Root cause found**: the *renderer*, not the LLM, was the bug. The built-in renderer happened to
   pass `has_examples` (it has a separate 2-line `## Examples` fence); the adapter template did not.

## Root Cause

A deterministic eval proxy can only be relied on if the **renderer structurally guarantees** it
independent of model output. Optional sections left empty, and a fenced block that can collapse to
one line, mean the generator *cannot* pass on an uncooperative draw — so the gate measures luck.

```elixir
# BEFORE — template Usage fence could be a single line; Workflow/Patterns absent entirely
"usage_examples" => p.usage || p.example || "# (no example provided)"
```

## Solution

Make the renderer satisfy the proxy by construction (both render paths):

```elixir
# Presence-gated sections: numbered Workflow (raises action_density), bold do/don't Patterns.
# Empty list ⇒ "" so no dangling "## Section" header.
defp workflow_section(steps), do: "## Workflow\n\n" <> numbered(steps)

# A worked example that is ALWAYS >=2 non-empty lines: usage comment over the concrete snippet.
defp usage_block(%Proposal{usage: u, example: e}) do
  "# " <> fence_safe(present(u) || "When the trigger conditions match") <> "\n" <>
    fence_safe(present(e) || "# (add a concrete example)")
end
```

Result on the same session: **clarity 0.50 → 1.00, composite 0.88 → 0.93.**

### The counter-example (why this is a principle, not "make every check pass")

The last sub-1.0 dimension was `triggering` 0.67 — a 287-char description vs a 250 cap. I did **NOT**
add a truncation clamp: cutting to 250 would drop the useful "NOT for …" disambiguation clause, i.e.
**game the proxy against its own intent** and degrade the real artifact. That is LLM-content variance,
which belongs to the reflective optimizer (`Faber.Optimize.reflect`), not the renderer.

> **The rule:** fix the *generator structurally* when the renderer can't pass regardless of the model.
> Do **not** add deterministic shims that satisfy a proxy by lowering real output quality. The first
> raises the floor; the second corrupts the metric.

### Files Changed

- `lib/faber/propose.ex` — `workflow_section/1`, `patterns_section/1`, `usage_block/1`, `fence_safe/1`,
  `oneline/1`; both `render_skill_md/1` and the adapter-template `template_context/1` paths.
- `adapters/faber-elixir/templates/skill.md.tmpl` — presence-gated Workflow/Patterns; Usage fence.
- Commits `dfd9cd5`, `4e12f33`.

## Prevention

- [x] Add to test patterns — assert the rendered fence *directly* (`fence_nonempty_lines/1` ≥ 2),
      not only via the matcher, so a matcher regex change can't silently "pass" without the renderer
      guaranteeing the minimum.
- [ ] When adding any new eval dimension, ask: "can the renderer fail this on a valid LLM draw?" If
      yes, give the renderer a structural guarantee (or a presence gate) before relying on the score.
- Specific guidance: "Probe matchers against the *actually rendered* artifact, not a fixture — the
  built-in and adapter-template render paths can diverge on exactly these checks."

## Related

- `.claude/research/2026-06-25-dogfood-real-history.md` — full dogfooding log (this fix + the
  install-provenance fix that the same session surfaced).
- Sibling root cause (separate file candidate): `sync_pointer` over-claiming all skills in a shared
  dir — fixed with an install-provenance marker (`commit 5d1032d`).
