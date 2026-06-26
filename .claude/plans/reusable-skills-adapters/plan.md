# Plan — reusable skills + adapter opportunities from the Faber build

**Date:** 2026-06-26
**Context:** Building Faber produced several proven, cross-cutting Elixir/dev patterns. This plan
decides which are worth turning into reusable **Claude Code skills** (SKILL.md) and whether a second
**Faber adapter** is warranted. The knowledge already lives in `.claude/scriptorium/*` drop files +
the scriptorium KB; this is about *operationalizing* it (a skill an agent loads, or an adapter Faber
generates from).

## Assessment

Two distinct kinds of artifact, don't conflate them:

- **Claude Code skill (SKILL.md)** = a procedure an agent runs when a trigger matches. Best for
  *architectural patterns I apply by hand* — Faber's friction-driven proposer won't surface these
  (they're not session friction).
- **Faber adapter (`adapters/<name>/`)** = a stack knowledge pack (laws + playbooks + templates)
  that lets the *engine* generate skills for a stack. Validates the "domain-free engine" thesis.

### Reusable skills — ranked (these are hand-author candidates)

| # | Skill | Reuse | Proven by | Notes |
|---|-------|-------|-----------|-------|
| S1 | `elixir-no-egress-test` — prove a fn makes **no network calls** via BEAM tracing (privacy/security boundary) | HIGH | Faber's `no_egress_test` (the moat test) | Non-obvious technique; any sensitive Elixir code. KB: `network-egress-during-compile`, drop `beam-no-egress-tracing-test`. |
| S2 | `keyless-llm-claude-cli` — add an LLM call to Elixir **keyless** via `claude -p` behind a behaviour (stdin `/dev/null`, JSON parse, ReqLLM fallback) | HIGH | `Faber.LLM.ClaudeCLI` + the stdin fix | Dev/test LLM with no key. Drop `keyless-llm-smoke-test-via-claude-cli`. |
| S3 | `anubis-mcp-readonly-phoenix` — expose **read-only** MCP tools in Phoenix (Anubis, localhost, start-gated under `serve`, aggregate-only privacy projection) | MED-HIGH | `Faber.MCP.*` | Drop `anubis-mcp-phoenix-integration`. |
| S4 | `managed-block-config-write` — idempotent, digest-guarded, **provenance-marked** writes into user-owned config (CLAUDE.md/AGENTS.md/dotfiles) | MED | `Faber.Install.ManagedBlock` + `.faber.json` marker | Generalizes beyond Faber. |
| S5 | `eval-gate-for-generated-artifacts` — design a **deterministic** structural eval (matchers→dimensions→composite→gate) + the "structural-guarantee vs metric-gaming" rule | MED | `Faber.Eval.Native` + the dogfood fix | Solution: `2026-06-25-eval-clarity-proposer-renderer-gap`. |

**Recommendation:** author **S1 + S2 first** (highest reuse, most-proven, most non-obvious). S3–S5
are good follow-ups. Where they live: install into `~/.claude/skills` (like `context-budget`) — NOT
the plugin repo (Faber boundary: read-only). Each gets the `.faber.json`-style provenance if
installed via `Faber.Install`.

> Dogfood angle: rather than hand-author, S1–S5 could be checked into `faber-elixir`'s **playbooks**
> so the engine proposes them when matching friction appears (see A2). But they're architectural, not
> friction-driven, so hand-authoring the top 2 is the pragmatic path; A2 is the long-game.

### Adapter opportunities

| # | Item | Effort | Value | Verdict |
|---|------|--------|-------|---------|
| A1 | Second real adapter (`faber-python` / `faber-typescript`) — prove the engine is domain-free with **zero engine changes** | M–L | HIGH (core thesis) | **Milestone, not a session task.** Needs a curated stack-knowledge source (the Elixir one came zero-diff from Oliver's plugin; a 2nd stack has no such source yet). |
| A2 | Enrich `faber-elixir` playbooks with the S1–S5 patterns so the proposer can emit them | S–M | MED | Good once S1/S2 prove their shape. |
| A3 | `faber-generic` skeleton adapter (stack-agnostic laws only) — smoke-proves the loader on a 2nd pack | S | LOW | Only if A1 is blocked; generic skills aren't the moat. |

## Tasks

- [ ] **S1** Author `elixir-no-egress-test` SKILL.md (trigger, Iron Laws, the BEAM-trace recipe, a worked example from `no_egress_test`). Decide install target.
- [ ] **S2** Author `keyless-llm-claude-cli` SKILL.md (the behaviour seam, `claude -p` stdin `/dev/null`, JSON parse, ReqLLM fallback, when to use).
- [ ] **S3** Author `anubis-mcp-readonly-phoenix` SKILL.md (read-only tools, localhost bind, serve-gating, privacy projection).
- [ ] **S4** Author `managed-block-config-write` SKILL.md (digest guard, provenance marker, never-clobber-user-text).
- [ ] **S5** Author `eval-gate-for-generated-artifacts` SKILL.md (deterministic matchers + the structural-guarantee rule).
- [ ] **S-install** Install the authored skills via `Faber.Install` into `~/.claude/skills` (gets the provenance marker); optionally `faber sync` the pointer.
- [ ] **A1** (milestone) Stand up a second adapter to prove engine domain-independence — first pick the stack + a knowledge source; then assemble `manifest.yaml` + laws + playbooks + a skill template; confirm **zero `lib/faber` diffs**.
- [ ] **A2** Fold S1–S5 into `faber-elixir` playbooks so the proposer can surface them on matching friction.
- [ ] **A3** (fallback) `faber-generic` skeleton adapter to smoke-test the loader on a 2nd pack.

## Decision needed

Build **S1 + S2 now** (≈ the two highest-value skills, ~30 min), or leave the whole backlog for a
later focused session? A1 (second adapter) is the thesis-proving milestone but needs a stack-source
decision first — not a quick task.
