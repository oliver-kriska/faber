# `detect/` — stack-specific friction signatures

What goes here: declarative signatures that tell `Faber.Detect` what *friction* looks
like for this stack — beyond the engine's generic signals (repeated tool sequences, retry
loops, failure clusters).

For `faber-elixir`, the signatures derive from the plugin's session-retrospective skills
(`session-scan`, `session-deep-dive`, `session-trends`) and the friction/fingerprint
scoring in `compute-metrics.py`: e.g. repeated `mix compile` failure→fix loops, N+1
detection passes, changeset-debug churn, repeated `mix test` reruns on the same file.

Format: one signature per file (yaml/markdown). Each names the pattern, the transcript
evidence that matches it, and a severity/weight. **No host-language code** — the engine
interprets these. Filled in M1/M2.
