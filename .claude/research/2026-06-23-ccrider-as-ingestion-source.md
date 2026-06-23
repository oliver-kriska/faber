# ccrider as Faber's ingestion source (2026-06-23)

**Question:** should Faber depend on `ccrider` (Oliver's Go session indexer) and read its SQLite DB
instead of walking `~/.claude/projects/*.jsonl` itself? It would give cross-agent (claude + codex)
ingestion for free.

## What ccrider is

Go CLI (Neil Berkman; Oliver runs it everywhere via Homebrew + MCP). Indexes Claude Code **and**
Codex CLI sessions into `~/.config/ccrider/sessions.db` (FTS5, incremental import via mtime+size →
BLAKE3 → parse). KB: `projects/ccrider/overview.md`, `tools/ccrider.md`.

## Live DB probe (this machine, 2026-06-23)

- `sessions`: **2589 claude, 14 codex**. `messages`: **133,173**. `tool_uses`: **0**.
- Schema (relevant): `sessions(session_id, project_path, provider DEFAULT 'claude', git_branch,
  cwd, message_count, …)`; `messages(uuid, session_id FK, parent_uuid, type, sender, content,
  text_content, timestamp, sequence, is_sidechain, cwd, git_branch, version)`;
  `tool_uses(message_id FK, tool_name, tool_id, input, output)`.

### Two findings that decide feasibility

1. **Full fidelity is preserved in `messages.content`.** It holds the **raw inner message JSON** —
   e.g. `{"model":"claude-sonnet-4-5…","role":"assistant","content":[…tool_use…],"usage":
   {"input_tokens":9,"cache_creation_input_tokens":8064,"cache_read_input_tokens":16361,…}}`.
   90,804 messages contain `input_tokens`. So **all** Faber detection signals survive a
   SQLite-backed source, including the new **context-pressure** signal (needs `usage`).
2. **`tool_uses` is empty (0 rows).** ccrider is not populating it in this DB. Irrelevant for Faber
   because tool_use blocks live inside `messages.content` (which Faber's Claude parser already
   reads), but it means there is no `tool_uses`/`is_error` shortcut — parse `content`.

### Caveats

- `messages.content` is the **inner** message object, not the full JSONL envelope. A ccrider source
  must rebuild the envelope Faber's `Ingest.normalize/1` expects:
  `%{"type" => row.type, "message" => Jason.decode(row.content), "isSidechain" => row.is_sidechain}`.
- **Codex content is provider-native.** ccrider gets codex rows into the same `messages` table, but
  each row's `content` is Codex's schema, not Claude's. Cross-agent friction detection still needs a
  **codex format parser** (`Faber.Ingest.Format.Codex`); ccrider provides the rows + plumbing, not a
  unified message shape. (KB confirms: "the JSONL event schema for messages/tool calls is different
  from Claude's.")
- No `isMeta` column → the `user_corrections` "exclude meta turns" refinement degrades slightly
  (can be recovered from `content` if the raw carries it).

## Recommendation: optional source seam, NOT a hard dependency

Add ccrider as an **opt-in ingestion source**, keep the file-walker as the **zero-dep default**.

- **Why not a hard dep:** Faber's single-binary distribution + portability rest on being
  self-contained. Coupling the core to an external Go binary + a specific SQLite schema breaks that
  and complicates the Burrito story. ccrider also isn't present in CI / on every user's machine.
- **Architecture:** Faber already has a `Format` seam (`Ingest.Format.Claude`). Add a **`Source`**
  seam (filesystem | ccrider-sqlite) above it; the source yields `{provider, envelope}` and dispatches
  to the provider's `Format`. `Scan` gains `source: :ccrider` (default `:files`). Read-only access via
  `exqlite` (open `?mode=ro`; the DB is WAL — safe to read live). One new hex dep.
- **What it buys:** cross-agent breadth (closes the "single agent format" gap), incremental import
  for free, **no 30-day Claude cleanup data loss** (ccrider preserves deleted sessions), dedup, and
  an FTS5 pre-filter for "only mine sessions matching X".

## Sequencing

1. `Faber.Ingest.Source` behaviour + `Source.Files` (current logic) + `Source.Ccrider` (SQLite, claude
   provider only first — full fidelity already proven).
2. `Scan` `source:` option; CLI/dashboard flag.
3. `Faber.Ingest.Format.Codex` to actually consume the 14 codex rows → real cross-agent proof.

Steps 1–2 are low-risk and high-value on their own (better claude ingestion + the data-loss win).
Step 3 is the cross-agent payoff and the bigger lift (new format).
