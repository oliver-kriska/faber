---
scriptorium: true
action: create
title: "Lore / rac-core (Requirements as Code)"
type: tool
domain: general
tags: [ai, coding-agents, mcp, knowledge-base, determinism, claude-code, skill-engine, faber, adr]
---

# Lore / rac-core — Requirements as Code

**Verdict: evaluate / complement** (adjacent to Faber, not a competitor). Repo: https://github.com/itsthelore/rac-core · PyPI `requirements-as-code` · MCP id `io.github.tcballard/lore` · Apache-2.0 · author Tom Ballard (`itsthelore`). Analyzed 2026-06-24 (4 parallel deep-read agents). Full Faber-facing write-up: `faber/.claude/research/2026-06-24-rac-core-lore-analysis.md`.

## What it is
A **deterministic, read-only knowledge-grounding system for coding agents**. Team knowledge — requirements, decisions (ADRs), designs, roadmaps, prompts — lives as **typed Markdown** in the repo, classified + validated against per-type schemas, served **read-only over MCP** to Claude Code / Cursor / Claude Desktop so the agent cites decisions instead of violating them. **No RAG, no embeddings, no LLM judge** — retrieval/scoring is a pure function of (corpus bytes, query, code). Enforcement is at **write time** in CI (`rac validate` / `rac gate`). Three surfaces over one engine: library (`rac.__all__`), CLI (`rac`), MCP server (`lore`). Satellites: **Wayfinder** (deterministic prompt-complexity router), **lore-connectors**.

## Where it sits in the skill-engine landscape
Same axis as [[Stack-aware improvement engine]] / Faber and [[Coding Agents Dashboard]] (make your coding agent better), different station: **Lore grounds the agent in decisions already made; Faber mines sessions to compile skills.** Complementary, with a real two-way composition: Faber's mined friction ("agent re-did something ruled out") = a missing decision artifact Lore could hold; a decisions corpus = a friction signal Faber could detect against. Independently arrived at the same determinism-over-LLM-judge conclusion Faber did (cf. [[Layer-5 evaluation signal drives AI agent convergence]]).

## Patterns worth reusing (cross-project, not just Faber)
- **Deterministic grounding eval** (ADR-066): score the *real* served surface, Precision@k/Recall@k + a **hard-negative gate** (a superseded item surfacing as current = the canonical failure), gated-metrics vs excluded-metadata split, floor + (baseline − tolerance), **CI never rebaselines** (a test parses every workflow to prove `--update-baseline` can't run there), regression-injection tests proving the gate fails. The strongest reusable eval-gate blueprint I've seen.
- **Managed-block agent-rules injection**: digest-guarded `<!-- BEGIN MANAGED BLOCK (digest:…) -->` written idempotently into CLAUDE.md / AGENTS.md / .cursor/rules / .github/copilot-instructions.md (one block, all clients), distilled pointers not bodies, `--check` drift gate, preserve-outside-block. Better than blind append/overwrite for any tool that injects context.
- **Tools-only read-only MCP server**: ~5 tools, engineered+pinned descriptions (the trigger surface), stateless re-read per call (reproducible), per-response char budget with whole-item truncation + `{truncated, omitted, hint}`, structured errors not exceptions, isolation test proving no write-capable import.
- **"Ride the carrier, own the enforcement"** (ADR-048/049 re Google's Open Knowledge Format): a hyperscaler commoditized the file format; community standards commoditized per-type schemas; so they redefined the product as the layer the standard leaves out — deterministic CI-enforced cross-artifact validation. "OKF is read-time interchange; RAC is write-time enforcement." Informative-only dependency, re-pinnable.
- **Thin clients over one engine** (ADR-062/063): every other-language/surface client is a thin consumer of a stable JSON/exit-code/MCP contract — "a second engine is a second source of truth = drift." Refuses native ports. Spins off off-identity concerns (routing → Wayfinder).
- **ADR-067/065 integration philosophy**: context-supply + post-edit enforcement, *not* pre-edit interception (no agent platform exposes a generic veto except Claude Code `PreToolUse`); the engine asserts *which decisions bind*, never that a change *is wrong* (semantic judgment stays in the agent); served artifact content is **untrusted input**, trust boundary = human PR review.
- **Engineering discipline**: no-egress test (monkeypatch `socket` to raise, run the pipeline — the no-network claim is CI), golden byte-for-byte CLI-output tests, per-service test batteries + a coverage-guard test, content-hash on source bytes never mtime, digest-not-timestamp idempotency, CalVer decoupled from a `schema_version` compatibility contract, deterministic CycloneDX SBOM with drift test, OIDC trusted publishing, injectable clock+entropy for deterministic ID minting.

## Tools it pulls in
FastMCP (`mcp`), markdown-it-py (single shared parser), markitdown (optional doc ingestion DOCX/PDF/PPTX/XLSX, ADR-072), textual (optional TUI Explorer), SARIF output → GitHub Code Scanning, CycloneDX SBOM, setuptools-scm, ruff + strict mypy + src/ layout, importlib.resources for bundled templates/skills/hooks.

Related: [[GEPA]], [[EvoSkill]], [[SkillsBench]], [[Premature Agent Victory Problem]], [[Harness Engineering]].
