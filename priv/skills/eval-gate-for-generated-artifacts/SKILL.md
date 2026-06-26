---
name: eval-gate-for-generated-artifacts
description: "Design a DETERMINISTIC structural eval to gate LLM-generated artifacts (skills, prompts, docs, codegen, scaffolds, RAG answers): matchers -> dimensions -> composite -> pass/fail threshold. Use when generated output keeps failing a quality check and you must decide whether to fix the GENERATOR structurally or leave it to a content optimizer. Core rule: raise the floor by construction; NEVER add a shim that games the proxy by lowering real output quality (Goodhart)."
effort: medium
argument-hint: ""
allowed-tools:
---

# Eval Gate for Generated Artifacts

For any system that **generates artifacts with an LLM and gates them with a deterministic
eval**, the eval scores output on proxy checks (action density ≥ 0.25, has a fenced example
with ≥2 lines, description ≤ 250 chars …), combines them into dimensions → a composite → score, and
gates on a threshold. When output keeps failing a dimension *even though it's good*, two very
different root causes hide there — and they demand **opposite** fixes.

## Iron Laws - Never Violate These

1. **When the renderer cannot pass the proxy on a valid LLM draw, fix the GENERATOR
   structurally.** Optional sections render empty; a fenced block collapses to one line; a
   required marker is sometimes absent → the gate is measuring luck. Presence-gate sections,
   guarantee a ≥2-line block by construction (a comment line over the value), inject required
   structure regardless of model output. This **raises the floor** — every valid draw passes.

2. **NEVER add a shim that satisfies a proxy by lowering real output quality.** A 287-char
   description with a valuable "NOT for …" disambiguation clause vs a 250-char cap: do **not**
   truncate/clamp to force the proxy green. That games the metric against its own intent and
   degrades the artifact (Goodhart). This belongs to the content optimizer (a reflective loop),
   not the renderer.

3. **Probe the matcher against the ACTUALLY-RENDERED artifact, not a fixture.** Render paths
   diverge (a built-in renderer can pass `has_examples` while the adapter-template path fails
   it on the same proposal). The fixture lies; the real output doesn't.

4. **Assert a structural guarantee INDEPENDENTLY of the matcher.** When you add a guarantee
   (e.g. "fenced block has ≥2 non-empty lines"), test it by counting lines directly — not by
   re-running the matcher — so a later regex change can't silently "pass" without the renderer
   actually holding the guarantee.

## The decision rule

> Fix the **generator structurally** when the renderer can't pass regardless of the model.
> **Never** shim to satisfy a proxy by lowering real output quality.
> The first raises the floor; the second corrupts the metric.

**How to tell which case you're in** — ask: *"Can a valid, high-quality LLM draw fail this
check?"* If yes → case 1 (structural fix). If the only way to pass is to remove something good
→ case 2 (don't shim; optimize content instead).

## Usage

```
# Score a rendered artifact deterministically (no model call), gate on the threshold.
# score(md) -> %{composite, dimensions, threshold, passed}
```

## Workflow

1. Define **pure matchers** (string/structure → bool or 0..1): action density, has-example,
   length bounds, required-section presence.
2. Group matchers into **dimensions** (e.g. `clarity`, `triggering`), each a weighted blend.
3. Combine dimensions into a **composite**; gate on a threshold (e.g. 0.75).
4. For every failing dimension, apply the decision rule: structural fix (Law 1) or hand to the
   optimizer (Law 2) — never a shim.

```elixir
# Deterministic, hermetic — no model call in the gate.
%{composite: c, dimensions: dims, threshold: t, passed: passed} = MyApp.Eval.score(rendered_md)

# Law 1 example — guarantee the example block structurally in the renderer:
defp example_block(nil), do: "```\n# (no example)\n_\n```"   # always ≥2 non-empty lines
defp example_block(code), do: "```\n#{ensure_two_lines(code)}\n```"

# Law 4 — assert the guarantee independently of the matcher:
lines = rendered_md |> extract_fenced_block() |> String.split("\n", trim: true)
assert length(lines) >= 2   # NOT `assert Matchers.has_examples?(rendered_md)`
```

## Patterns

- **Source story:** Faber's skill proposer — empty `## Workflow`/`## Patterns` + a one-line
  Usage fence failed the eval's `clarity` dimension (action_density + has_examples). Structural
  fixes took clarity 0.50 → 1.00. The over-long description (`triggering` 0.67) was *deliberately
  left to the reflective loop, not clamped*.
- A deterministic eval sidesteps the variance of reflective/LLM-graded optimization — it's
  reproducible, free, and CI-safe. Keep the strict production gate separate from any lenient
  smoke-test floor.

## References

- Faber: `lib/faber/eval/native.ex` (matchers → dimensions → composite → gate).
- Pattern note: `.claude/scriptorium/2026-06-26-eval-proxy-structural-guarantee.md`.
- Solution: `.claude/solutions/2026-06-25-eval-clarity-proposer-renderer-gap.md`.
