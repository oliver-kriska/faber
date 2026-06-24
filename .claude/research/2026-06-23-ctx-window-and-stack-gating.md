# Context-window resolution + stack-aware gating — findings & fixes

**Date:** 2026-06-23
**Trigger:** After shipping the Codex ingest format, asked "what next — fix/test/implement?".
Two gaps the Codex work exposed, both fixed this session.

## 1. Detect context-pressure: `ctx > 100%` (FIX — commit 11f2a86)

**Investigation:** sampled 60 of 5707 real Claude sessions, computed `Detect.context/1` + the raw
peak prompt tokens per session.

Two real bugs:

- **1M-beta sessions read 177–223%.** Claude Code records the *plain* model id
  (`claude-opus-4-8`, `claude-opus-4-6`) even when the session ran on the **1M context beta**, so
  the window resolved to 200k against peaks of 355k–446k. There's no `[1m]` marker in the
  transcript to tell us — but a **peak prompt that exceeds the standard window IS the tell** the 1M
  beta was active. Fix: `resolve_window/2` infers the model's `[1m]` window when `peak > base`.
- **`claude-opus-4-5-20251101` silently lost the signal.** Not in `@context_windows` (no
  `claude-opus-4-5` key) → `nil` window → no context-pressure at all for 10/60 sampled sessions.
  Fix: added `claude-opus-4-5` (+`[1m]`).
- Safety net: `@max_ctx_pct 100.0` clamp on both the Claude and Codex paths, so a future stale map
  can never report a nonsensical fill.

**Verified:** 0/59 sessions over 100% (was 4), opus-4-5 now scored, peak 90.3%.

## 2. `file_globs` declared but never enforced (IMPLEMENT — commit 9a49dc5)

**Finding:** the adapter manifest's `file_globs` carry the comment *"Presence of these is how Faber
decides this adapter applies"* — but **no code consumed them**. `Adapter.load` parsed/validated
them, then `propose` applied `faber-elixir` to whatever session sat at the chosen rank. Harmless
while every session was Elixir Claude; the Codex ingest made it real — Codex sessions come from
non-Elixir projects (naostro.ai landing, andrej_skolenia, phd_knowledge), so
`faber propose --format codex` would draft an **Elixir** skill for a Next.js session and judge it
against the Elixir eval bar — violating the core "stack-aware" promise.

**Design decisions:**

- **Match against the session's *referenced* paths, not the project on disk.** Filesystem-
  independent (works cross-machine / moved projects); uses data Scan already has. Added
  `Scan.Result.file_paths` (edited/read/patched paths) + `Adapter.matches_session?/2` translating
  globs to suffix-anchored regexes (`glob_regex/1`: `**`→any dirs, `*`/`?`→within segment,
  `{a,b}`→alternation).
- **Gate at the selection site (CLI propose), NOT inside `Propose.propose/3`.** propose/3 has many
  callers; the Loop re-proposes the *same* result repeatedly — a hard gate there would break the
  loop. CLI: mismatch → exit 1 with an actionable message; `--force` overrides.
- **Bias to avoid false positives** (skip wrong-stack), with `--force` for the rare false negative
  (e.g. an Elixir session that only ran `mix` without touching `.ex`).

**Verified on real data:** all 14 Codex sessions gated out of faber-elixir; the Claude corpus
matches a healthy mix (15/39 — Oliver's `~/.claude` spans many non-Elixir projects, correctly).

## Still open (deferred, not done this session)

- **Live `propose` on a Codex session** — needs an LLM API key (neither ANTHROPIC_API_KEY nor
  OPENAI_API_KEY set here). The stub-LLM CLI test covers the gate→draft→eval wiring; the live call
  is a manual step.
- **dspy.GEPA sidecar engine + Pareto selection for the reflective loop** — out of v1 scope per the
  documented keyless-evolution decision (`2026-06-23-gepa-reflective-loop-decision.md`).
- **Codex project label** — Scan shows the rollout file's date dir (`23/<sid>`) instead of the real
  project; the `cwd` is in `session_meta`. Minor display polish; would need to thread `cwd` into the
  Result.
- **Multi-adapter selection** — only `faber-elixir` exists; `matches_session?/2` is the primitive a
  future "pick the matching adapter among many" selector would build on.
