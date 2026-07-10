# just_bash evaluation — useful for Faber? (2026-07-10)

**Verdict: skip for now.** Well-made library solving a problem Faber doesn't have. Two narrow
future angles noted below; re-evaluate only if one of them becomes real work.

## What it is

[`elixir-ai-tools/just_bash`](https://github.com/elixir-ai-tools/just_bash) (v0.3.0,
April 2026, ~91 stars) — a **pure-Elixir bash interpreter**: parses shell syntax to an AST and
executes it against an **in-memory virtual filesystem** (`vfs` dep). No real processes, no real
FS, no network (opt-in curl/wget behind HTTPS-only + host allowlists). ~80 builtins (`grep`,
`sed`, `awk`, `jq`, file ops), pipes/redirections/functions/arrays/arithmetic. Immutable
`bash = JustBash.new(); {result, bash} = JustBash.exec(bash, cmd)` API. Escape hatch: "custom
commands" — trusted Elixir functions registered as shell commands that **bypass the sandbox
entirely**.

Its target use case: giving an AI agent a *safe Bash tool* — executing untrusted, LLM-generated
shell without touching the host.

## Why it doesn't fit Faber's actual shell usage

Faber shells out in four places, and **every one needs a real external binary** that an
in-memory interpreter cannot run:

| Call site | Binary | just_bash applicable? |
|---|---|---|
| `Faber.LLM.ClaudeCLI` | `claude -p` (real CLI, real auth, real network) | no |
| `Faber.Sidecar.System` | `python3 -m faber_eval` | no |
| `Faber.Loop.Git` | `git` (real repo on real disk) | no |
| opencode / ccrider ingest | `sqlite3` (real DBs on real disk) | no |

More fundamentally: **Faber never executes LLM-generated shell.** The LLM output it handles is
a structured proposal (JSON → `%Proposal{}`); the only "bash" Faber touches from untrusted
sources is *text it reads* — commands recorded in transcripts, and example snippets it writes
into generated SKILL.md files. Nothing untrusted is ever run, so the sandbox-execution value
proposition (the whole point of just_bash) doesn't apply. Timeout/hang hardening for the real
subprocesses is already solved by `Faber.Subprocess` (and the 2026-06-18 tooling research
already picked `exile` as the upgrade path if richer process control is ever needed — see KB
`wiki/faber-elixir-tooling.md`).

Dependency posture also argues against: Faber deliberately runs lean (jason + yaml_elixir +
phoenix-stack; no NIFs, stdlib where possible). just_bash + vfs is a nontrivial tree to carry
with no call site.

## Two narrow angles where it *could* matter later

1. **Shell parsing for detection accuracy.** `Faber.Detect` classifies transcript bash commands
   with prefix/regex matching (retry loops = same-prefix consecutive commands; fingerprint
   command-bonus rules; the eval's `no_dangerous_patterns` regex). A real bash parser (just_bash's
   AST) would classify compound commands (`cd x && mix test`, pipes, subshells) more faithfully
   than prefixes. BUT: the current heuristics are deliberate ports of the reference
   implementation (parity is a calibration feature, not laziness), they work on real data, and
   it's unclear just_bash exposes its parser as a public API separate from execution. Not worth
   a dep for marginal gains today.
2. **Syntax-checking generated examples.** Faber-generated skills embed fenced bash examples. A
   deterministic eval matcher could parse the example with just_bash and fail the artifact on
   invalid shell — a cheap "does the example even parse" floor. Nice-to-have; the current
   renderer guarantees (≥2-line examples, fence-safety) already cover the observed failure
   modes.

**Trigger to re-evaluate:** if Faber (or its MCP surface) ever offers agents a
"run-this-command" tool, or if detection accuracy on compound commands becomes a measured
problem — just_bash is the first candidate to reach for. Also genuinely relevant to OTHER
Elixir projects that hand an LLM a shell (noted in the KB drop file).
