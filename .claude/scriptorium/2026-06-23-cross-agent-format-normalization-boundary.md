---
scriptorium: true
action: create
title: "Normalize divergent source formats at the adapter boundary, not in the consumer"
type: pattern
domain: general
tags: [architecture, ingestion, adapter-pattern, cross-agent, normalization, faber]
---

## Pattern

When a generic engine consumes data from multiple heterogeneous sources (different coding-agent
transcript formats, different log shapes, different APIs), keep the **consumer source-agnostic** and
push all per-source quirk-handling into the format/adapter module behind a behaviour. The adapter's
job is precisely to map an on-disk/on-wire shape onto the engine's internal vocabulary.

Concrete case (Faber, 2026-06): adding OpenAI Codex as a second ingest format alongside Claude Code.

### Two decisions that fell out of the pattern

1. **Normalize vocabulary at the boundary, not in the scorer.** Faber's friction scorer (`Detect`)
   is *name-keyed* to Claude's tool vocabulary — `retry_loops`/`bash_commands` filter
   `name == "Bash"` and read `input["command"]`; `files_edited` reads `input["file_path"]` off
   `Edit`. Codex's native tool names (`exec_command`, `apply_patch`, `view_image`) would leave every
   one of those signals dead. The wrong fix is teaching the scorer codex vocab (couples the generic
   engine to every agent forever). The right fix: the **codex format** maps `exec_command → Bash`
   (`cmd → command`), `apply_patch → one Edit per file`, `view_image → Read`, so the unchanged
   generic scorer fires cross-agent. The adapter absorbs the divergence.

2. **Add a normalized field rather than couple the consumer to per-source raw shapes.** Claude
   carries per-turn token usage on the assistant message + derives the context window from the model
   name via a static map. Codex carries usage in a *separate* telemetry event with the window
   **inline** (and a model absent from any static map). Tempting hack: make the consumer sniff
   codex's `payload.info` shape. Better: add one normalized field to the shared struct
   (`Event.usage = %{prompt_tokens, context_window}`), have each format populate it from its own
   shape, and have the consumer prefer it — falling back byte-for-byte to the legacy path when it's
   nil. The legacy (Claude) path is untouched; the new source carries its own normalized truth.

### Why this matters

- Adding a source = one new module implementing the behaviour + one alias. Zero engine changes.
- The consumer's tests stay valid; the new source gets its own hermetic fixture + tests.
- "Impedance mismatches" (usage-on-message vs usage-in-separate-event-with-inline-window) resolve by
  introducing a *normalized* seam, never by leaking raw per-source shapes into the consumer.

### Tells that you're violating it

- A `case` in the generic consumer that branches on which source produced the data.
- The consumer reaching into `raw[...]` with keys that only one source emits.
- A shared map type that some sources fill and others read via source-specific digging.

### Watch-outs

- Normalization is lossy and the mapping is a judgement call (codex `apply_patch` → one `Edit`
  *per file* to keep file-count signals accurate vs. one call). Document the asymmetries: codex emits
  one line per conversation item where Claude batches, so absolute message/tool counts aren't
  cross-source comparable even after normalization — signals stay consistent *within* a source.
- Some signals have no analog in a new source (codex has no interrupt/compaction marker) — let them
  degrade to zero gracefully rather than faking them.

Related: this is the same instinct as [[bounded-factor-level-prompt-optimization]]'s "deterministic
seam over a stochastic one" — push variance/divergence to a controlled boundary the rest of the
system can rely on.
