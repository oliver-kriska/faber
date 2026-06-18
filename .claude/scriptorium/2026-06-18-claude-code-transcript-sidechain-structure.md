---
scriptorium: true
action: create
title: "Claude Code transcript files: one per subagent, shared sessionId"
type: solution
domain: general
tags: [claude-code, transcripts, jsonl, sessions, subagents, sidechain]
---

# Claude Code transcript files: one per subagent, shared sessionId

When mining `~/.claude/projects/**/*.jsonl` session transcripts, **file count ≠ session
count**. Claude Code writes a **separate `.jsonl` file for each subagent / sidechain
invocation**, and every one of those files carries the **parent session's `sessionId`**
(plus `isSidechain: true` on sidechain events).

Measured on a real corpus (2026-06-18, Faber M2): **4,609 transcript files collapsed to
1,391 distinct sessions (~70%) when grouped by `sessionId`.** A single heavily-orchestrated
session produced **180 files**; several others 100+. About 54 files carried a **blank
`sessionId`** and had to be treated as standalone.

**Implication for any session-analysis tool:** dedup by `sessionId` before ranking/counting,
or one orchestration-heavy session dominates the results dozens-to-hundreds of times. Keep
the **richest member** of each group (most messages, then highest activity) — the parent
transcript holds the full conversation; subagent fragments are short. Rows with no
`sessionId` should pass through individually, not be merged into one bucket.

Reusable wherever Claude Code transcripts are parsed (friction scanners, usage analytics,
ccrider-style miners). See Faber `Faber.Scan.run/1` `:dedupe` for a reference implementation.
