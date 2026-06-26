# `eval/` — this stack's notion of "correct"

The stack-specific bar the eval gate applies on top of generic structural + trigger scoring.

For `faber-python` v1 this is **vendored mode with no domain matchers yet** (`eval.yaml`): a
proposed skill is gated on structure (`Faber.Eval.Native` — frontmatter, Iron-Laws section,
description triggering quality, action density, worked example, references) and, opt-in, on
trigger accuracy over its `should_trigger` / `should_not_trigger` fixtures.

Adding Python-specific matchers is a future step: drop matcher modules under `eval/` (pure
`(candidate: dict) -> {"passed", "score", "detail"}` functions) and reference them from
`laws/*.check.ref`. The sidecar (`python -m faber_eval score`) runs them; the engine never
imports them.
