# priv/skills — Faber's own dogfooded skills

These SKILL.md packs are **reference artifacts, not runtime data**: no `lib/faber` code reads
this directory. They are skills Faber generated *about building Faber* — each one passed the
eval gate and was kept because the lesson generalizes beyond this repo.

Why they live in the repo:

- **Proof of output.** They are checked-in examples of what the pipeline produces end to end
  (scan → propose → eval ≥ threshold → render), useful when judging a proposed change to the
  renderer or the eval bar ("would this have improved or degraded these?").
- **Reusable engineering knowledge.** Each captures a pattern learned while building Faber
  (keyless LLM via `claude -p`, no-egress tracing tests, managed config blocks, read-only MCP
  on Phoenix, deterministic eval gates). Install one with
  `cp -r priv/skills/<name> ~/.claude/skills/` if you want it in your own agent.

They are **not** installed, listed, or synced by `Faber.Install` — installed skills live under
`~/.claude/skills` with a `.faber.json` provenance marker. If a future feature wants to ship
starter skills, it should go through `Faber.Install` so provenance stays tracked.
