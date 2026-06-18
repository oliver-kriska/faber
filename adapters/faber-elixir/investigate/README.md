# `investigate/` — stack-specific debugging playbooks

What goes here: structured playbooks the proposer can fold into generated skills, and the
loop can consult — "when symptom X, check Y then Z" for this stack.

For `faber-elixir`, these map from the plugin's investigation skills (`investigate`,
`ecto-constraint-debug`, `n1-check`, `call-tracing`, `narrow-bare-rescue`, `perf`): e.g.
constraint-violation tracing, N+1 root-causing, changeset-error-first form debugging.

Format: one playbook per file (markdown): symptom → hypotheses → ordered checks →
resolution patterns. **No host-language code.** Filled in M1.
