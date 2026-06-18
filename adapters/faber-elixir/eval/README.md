# `eval/` — domain matchers + trigger fixtures (this stack's "correct")

What goes here: the stack-specific notion of *correct* that the eval gate applies on top
of generic structural and trigger-accuracy scoring. This is the part a generic
skill-creator cannot commoditize (correct-for-Elixir ≠ correct-for-Rails).

For `faber-elixir`, this maps from the plugin's `lab/eval/`:

- **domain matchers** — `matchers.py` (~24 matchers), `scorer.py` (8-dimension scorer),
  `agent_matchers.py` / `agent_scorer.py`, `schemas.py`.
- **trigger fixtures** — `trigger_scorer.py` + the `triggers/` fixtures (behavioral eval:
  does the skill fire on the right prompts and stay quiet on the wrong ones).

These are consumed by the Python sidecar (`python -m faber_eval score`). The adapter
contributes the matchers/fixtures; the engine runs them. Filled / wired in M1 → M4.
