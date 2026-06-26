# Local session/transcript storage formats: Windsurf, Pi, Kiro, Devin for Terminal

Research date: 2026-06-26. For Faber.Ingest cross-agent source pluggability (cf. native
Codex + ccrider SQLite work already landed).

Summary of where each lands for Faber ingest viability:

| Agent | Local persistence? | Format | Path | Schema status | Ingest difficulty |
|---|---|---|---|---|---|
| **Windsurf** | Yes | SQLite (VS Code `state.vscdb` k/v) | `~/Library/Application Support/Windsurf/User/{workspaceStorage/<hash>,globalStorage}/state.vscdb` | Reverse-engineered | Medium (VS Code k/v unpack, like Cursor) |
| **Pi** | Yes | JSONL (tree, `parentId`) | `~/.pi/agent/sessions/--<cwd>--/<ts>_<uuid>.jsonl` | **Documented** (open source) | Low — cleanest of the four |
| **Kiro CLI** | Yes | JSONL | `~/.kiro/` (override `KIRO_HOME`), per-dir sessions | Partially documented (commands yes, on-disk schema no) | Low–Medium |
| **Devin for Terminal** | Yes (local session DB) | Undocumented (local cache; JSON config) | `~/.config/devin/` (Win: `%APPDATA%\devin\`) | Reverse-engineering required | High (format opaque; hybrid local↔cloud) |

---

## 1. Windsurf (Codeium's AI IDE → "Windsurf")

- **Persists locally: yes.** Windsurf is a VS Code fork (Electron), so it follows the
  same `state.vscdb` SQLite pattern as Cursor.
- **Format:** SQLite databases in VS Code's key/value layout (`ItemTable`, and a
  Cursor-style `cursorDiskKV`-equivalent for agent/composer state).
- **Paths (macOS):**
  - Workspace-scoped: `~/Library/Application Support/Windsurf/User/workspaceStorage/<hash>/state.vscdb`
  - Global: `~/Library/Application Support/Windsurf/User/globalStorage/state.vscdb`
  - (Linux: `~/.config/Windsurf/User/...`; Windows: `%APPDATA%\Windsurf\User\...`)
- **Separate Cascade artifacts (NOT the transcript):**
  - Auto-generated memories: `~/.codeium/windsurf/memories/`
  - These are distilled facts/decisions, not raw conversation turns.
- **Schema status: reverse-engineered.** No official schema. The community extractor
  `0xSero/ai-data-extraction` confirms Windsurf support and describes it as
  "SQLite databases (VSCode-like format)" holding "Chat, agent/flow conversations,
  code context" — but does NOT publish the exact table/key mapping for Windsurf
  (it documents Cursor's keys in detail and notes Windsurf follows the same pattern).
- **Ingest note:** Highest-fidelity approach mirrors a Cursor extractor — open the
  `.vscdb` with sqlite3, pull JSON blobs out of the k/v table, walk message bubbles.
  Keys are version-fragile (Windsurf updates can rename them), like Cursor.

## 2. Pi (Earendil Works — `earendil-works/pi`, open source)

- **Persists locally: yes, auto-saved by default.** `--no-session` for ephemeral mode.
- **Format: JSONL, one session per file, with an in-file TREE structure** (branching via
  `parentId`, no new file per branch).
- **Path:** `~/.pi/agent/sessions/--<path>--/<timestamp>_<uuid>.jsonl`
  where `<path>` is the cwd with `/` replaced by `-`. Sessions are grouped by working dir.
- **Schema status: DOCUMENTED** — `packages/coding-agent/docs/session-format.md` and
  `docs/sessions.md`. This is the cleanest target of the four.
- **File structure:**
  - Line 1 = session header:
    `{"type":"session","version":3,"id":"uuid","timestamp":"...","cwd":"/path"}`
    (currently version 3; auto-migrates legacy v1–v2 on load).
  - Every other line extends `SessionEntryBase`: `{type, id (8-char hex), parentId|null, timestamp}`.
  - Entry `type`s: `message` (AgentMessage: user/assistant/toolResult/bashExecution/custom),
    `model_change` (`provider`,`modelId`), `thinking_level_change`, `compaction`
    (`summary`,`firstKeptEntryId`,`tokensBefore`), `branch_summary` (`fromId`),
    `custom` (extension state, not in LLM context), `custom_message` (extension msg in context),
    `label` (`targetId`,`label`), `session_info` (`name`).
  - Tree walk: `buildSessionContext()` walks current leaf → root, applying compactions /
    branch summaries to reconstruct the message sequence.
- **Resume flags:** `pi -c` (continue most recent), `pi -r` (picker), `--session <path|id>`,
  `--fork <path|id>`, `--name`, `/session`, `/tree`, `/resume`.
- **Caveat:** issue #320 reported `--resume` looked at the wrong session directory / wrote
  to the wrong dir — directory layout has had churn; verify the live path on the installed version.
- **Note vs prior KB:** Pi also has an RPC mode (`pi --mode rpc`, LF-delimited JSONL over
  stdio) used by wrapper apps (open-design). That's the live-control channel; the on-disk
  `.jsonl` sessions above are the persisted transcript Faber would ingest. See KB
  `wiki/pi-rpc-protocol.md`.

## 3. Kiro (kiro.dev / Amazon Kiro — IDE + Kiro CLI)

- **Persists locally: yes.** Sessions are stored per directory.
- **Format: JSONL** (per AWS/community reports — "session transcripts stored in JSONL
  format and can be read directly"). On-disk per-line schema not officially published.
- **Path:** `~/.kiro/` (global agents, prompts, skills, steering, settings, AND sessions).
  Overridable via `KIRO_HOME` env var. Exact `sessions/` subfolder layout not in the docs.
  Also: MCP config at `.kiro/settings/mcp.json`; skills at `~/.kiro/skills`.
- **Session commands (documented):**
  - `kiro-cli chat --resume` (most recent), `--resume-picker`, `--list-sessions`,
    `--delete-session <ID>` (sessions ID'd by UUID).
  - In-chat: `/chat new` (auto-saves current), `/chat save <FILE_PATH>`, `/chat load <FILE_PATH>`,
    `/chat save-via-script` / `/chat load-via-script` (custom storage hooks).
- **Schema status: partially documented.** The management *commands* and JSONL claim are
  documented; the per-entry on-disk schema is not — confirm by reading a real file.
- **Protocol note:** Kiro CLI also speaks ACP (Agent Client Protocol) for editor
  integration — a live channel, separate from the persisted JSONL.

## 4. Devin for Terminal (Cognition — "Devin CLI", official)

- **Persists locally: yes, but format opaque.** "Sessions are saved once you send your
  first message"; `devin list` shows locally-stored recent sessions; `devin -c` resumes
  last, `devin -r <id>` resumes a specific session. Word-pair memorable session IDs.
- **Config (documented):** `~/.config/devin/config.json` (Windows: `%APPDATA%\devin\config.json`).
  JSON-with-comments. Holds settings ONLY: model/history-display, UI prefs, permissions,
  MCP servers, proxy/sandbox, import-from (Cursor/Windsurf/Claude). Per Cognition,
  profiles here are "fully isolated including session caches and active session IDs."
- **Transcript location/format: NOT documented.** Devin docs describe a local "session
  database" and session caches but never state the serialization (SQLite vs JSONL) or
  the on-disk path for transcripts. Skills/agents load from `~/.config/devin/` and
  `.devin/` (legacy `~/.config/cognition/`, `.cognition/`).
- **Execution model: HYBRID local↔cloud.** Runs locally (Rust TUI, full codebase/tool
  access) but `/handoff` ships the session (with local git diff) to a remote cloud Devin
  sandbox with its own computer. So the LOCAL transcript exists, but cloud-handed-off work
  continues server-side and may not be fully reflected locally.
- **Schema status: reverse-engineering required.** Would need to inspect
  `~/.config/devin/` on a live install to find the session store and decode it.
- **Caution:** `revanthpobala/devin-cli` (PyPI `devin-cli`) is an UNOFFICIAL wrapper over
  Devin's HTTP API — not the official Cognition terminal agent. Don't conflate.

---

## Pi as the conceptual sibling
Inflection's pi.ai (Inflection-2.5 chatbot) is a different product — consumer
conversational AI, no local coding-agent / CLI / on-disk session store relevant here.
The "Pi" that matters for coding-agent ingest is **Earendil Works' Pi** (section 2). The
prior KB landscape note lists "Pi (RPC)" among the 16 open-design-detected CLIs — that's
Earendil's Pi.

## Ranking for Faber ingest (lowest friction first)
1. **Pi** — documented JSONL tree, stable schema doc, open source. Best next adapter.
2. **Kiro** — JSONL, predictable `~/.kiro/`, good CLI surface; confirm per-line schema from a real file.
3. **Windsurf** — SQLite `state.vscdb`; reuse a Cursor-style extractor; keys are version-fragile.
4. **Devin for Terminal** — undocumented local store + hybrid cloud handoff; needs live reverse-engineering, lowest ROI.

## Sources
- 0xSero/ai-data-extraction (Windsurf/Cursor/Codex/Claude/Trae paths): https://github.com/0xsero/ai-data-extraction
- Pi session-format: https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/session-format.md
- Pi sessions: https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/sessions.md
- Pi resume-dir bug: https://github.com/earendil-works/pi/issues/320
- Kiro CLI commands: https://kiro.dev/docs/cli/reference/cli-commands/
- Kiro CLI intro: https://kiro.dev/blog/introducing-kiro-cli/
- Windsurf memories: https://docs.windsurf.com/windsurf/cascade/memories
- Devin for Terminal config: https://docs.devin.ai/cli/reference/configuration/config-file
- Devin for Terminal changelog: https://docs.devin.ai/cli/changelog/stable
- Devin for Terminal blog: https://cognition.com/blog/devin-for-terminal
- KB: /Users/oliverkriska/Projects/scriptorium/wiki/pi-rpc-protocol.md
