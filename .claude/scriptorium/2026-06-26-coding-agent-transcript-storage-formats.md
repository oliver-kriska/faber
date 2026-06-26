---
scriptorium: true
action: create
title: "Coding-agent transcript storage formats: OpenCode, Aider, Gemini CLI"
type: reference
domain: general
tags: [ingestion, transcripts, cross-agent, opencode, aider, gemini-cli, faber, reverse-engineering]
---

## Why this exists

Faber mines real coding-agent sessions for friction (`Faber.Ingest`). It already ingests Claude
Code (JSONL sidechain) and OpenAI Codex (native format) via the pluggable
[[cross-agent-format-normalization-boundary]] seam. This catalogs the on-disk transcript formats of
the next three candidate sources, reverse-engineered from source (June 2026). The headline finding:
**they are wildly uneven in machine-parseability** — Gemini CLI is best, OpenCode is good but
dual-format, Aider is barely usable.

## OpenCode (repo: anomalyco/opencode, was sst/opencode, was opencode-ai/opencode)

Two storage architectures coexist depending on installed version — an integration MUST detect which:

- **Legacy (v0.x, still on older installs): flat JSON, one file per record** under
  `~/.local/share/opencode/storage/` (XDG `$XDG_DATA_HOME/opencode`; macOS uses the *same* path via
  the `xdg-basedir` npm pkg, NOT `~/Library/Application Support`). Layout:
  `session/{projectID}/{sessionID}.json`, `message/{sessionID}/msg_{messageID}.json`,
  `part/{messageID}/{partID}.json`. Key→file mapping in `packages/opencode/src/storage/storage.ts`.
- **Current (v1, `dev` branch): single SQLite DB** at `~/.local/share/opencode/opencode.db`
  (overridable `OPENCODE_DB`; per-channel `opencode-<channel>.db`), Drizzle ORM, `bun:sqlite`/node.
  Tables `session` / `message` / `part` (+ `todo`, `session_message`, `session_input`); typed JSON
  lives in a `data` column per row. Defs in `packages/core/src/session/sql.ts`.
- **Model = Session → Messages → Parts.** Message `role` ∈ user|assistant. Parts are a 12-variant
  union keyed by `type`: text, reasoning, file, **tool** (callID, tool name, state union
  pending/running/completed/error w/ input+output+time), step-start, **step-finish** (per-LLM-step
  cost + tokens{input,output,reasoning,cache{read,write}}), snapshot, patch, agent, subtask, retry,
  compaction. Canonical schema (Effect Schema) in `packages/schema/src/v1/session.ts`.
- IDs are time-sortable branded strings (`ses_`, `msg_`, `prt_`). Projects keyed off the git-root
  commit hash, NOT per-project dirs. **Gotcha: legacy message JSON `cost` is often `0`** — recompute
  from tokens (ccusage does this via LiteLLM pricing). v1 SQLite persists real cost + split tokens.
- **Doc status:** NOT officially documented as an external contract — reverse-engineered. Best
  third-party docs: ccusage (`ccusage.com/guide/opencode/`, legacy JSON layout), DeepWiki.

## Aider (repo: Aider-AI/aider, was paul-gauthier/aider)

**Bottom line: lossy human-readable Markdown, NOT cleanly machine-parseable.** Avoid as a primary
structured source unless you control the invocation.

- Default files anchored to **git repo root** (cwd fallback): `.aider.chat.history.md` (the
  transcript), `.aider.input.history` (prompt_toolkit FileHistory of raw user inputs),
  `.aider.tags.cache.v3/`|`.v4/` (repo-map symbol cache, SQLite via `diskcache` — **NOT** conversation
  data). Home dir: `~/.aider/analytics.json` (uuid/opt-in only). NO `~/.aider/` session store.
- **`.aider.chat.history.md` structure** (from `aider/io.py`): user turns prefixed `#### `, tool/
  system msgs prefixed `> ` (blockquote), session boundary line `# aider chat started at <ts>`, and
  **assistant turns have NO marker (bare text)** → user/assistant boundary is heuristic & fuzzy. NO
  per-message tokens/cost/model/timestamp anywhere. Append-only, shared across all runs in the repo.
  No structured session record exists; `--restore-chat-history` re-loads the markdown itself.
- **Cleaner opt-in:** `--llm-history-file` (default None, OFF) writes `ROLE ISO-TIMESTAMP\n<content>`
  per entry — role-tagged + timestamped, but still free text, no cost/token metadata, and won't exist
  for already-run sessions.
- **Doc status:** flags/defaults documented (aider.chat/docs/config/options.html, FAQ); the actual
  delimiters/formats are reverse-engineered from `aider/io.py`, `args.py`, `repomap.py`,
  `analytics.py`.

## Gemini CLI (repo: google-gemini/gemini-cli)

Three SEPARATE persistence mechanisms — do not conflate. Best parseability of the three agents.

- **A. File-edit checkpoints (`/restore`):** JSON-per-tool-call in `~/.gemini/tmp/<id>/checkpoints/`
  + shadow git in `~/.gemini/history/<id>/`. OFF by default. (docs/cli/checkpointing.md)
- **B. `/chat save <tag>` (legacy `Logger`):** JSON-file-per-tag `checkpoint-<tag>.json` +
  `logs.json` (flat JSON array of `{sessionId, messageId, timestamp, type, message}`) in the project
  temp dir. (packages/core/src/core/logger.ts)
- **C. Session recording (`ChatRecordingService`, powers `/resume`):** **JSONL** transcripts in
  `~/.gemini/tmp/<id>/chats/*.jsonl`, appended line-by-line. **This is the primary ingest target.**
  Schema `ConversationRecord` (packages/core/src/services/chatRecordingTypes.ts): `sessionId`,
  `projectHash`, `startTime`/`lastUpdated`, `messages: MessageRecord[]`, `kind: main|subagent`.
  `MessageRecord`: `{id, timestamp, content: PartListUnion}` + `type` discriminator
  (user|gemini|info|error|warning) — **role is the `type`, content is Gemini API Parts**. Gemini
  messages add `toolCalls: ToolCallRecord[]` ({id,name,args,result,status}), `thoughts`, `model`, and
  `tokens: {input,output,cached,thoughts,tool,total}`.
- `<id>` per-project subdir: historically SHA-256 hex of abs project root (`getProjectHash` in
  `utils/paths.ts`); `main` is **migrating to a registry slug** with legacy-dir migration — treat
  `<id>` as an opaque per-project-root id, not assumed hex.
- **Doc status:** features documented (docs/cli/checkpointing.md, session-management.md) but the
  on-disk JSONL format + schema are source-only. Active churn (issues #15292 JSONL move, #22604
  sessionId-on-resume bug).

## Ranking for ingest (most → least useful)

1. **Gemini CLI** — JSONL, role+content+toolCalls+per-message tokens, well-structured. Maps cleanly.
2. **OpenCode** — rich Session/Message/Part model w/ tokens & cost, but dual-format (must handle both
   legacy JSON tree and v1 SQLite) and legacy cost often 0.
3. **Aider** — lossy markdown, unmarked assistant turns, no per-message metadata. Heuristic at best.

Per the [[cross-agent-format-normalization-boundary]] pattern, each becomes one new `Faber.Ingest`
format module mapping its native shape onto the engine vocabulary — the scorer/consumer stay
source-agnostic.
