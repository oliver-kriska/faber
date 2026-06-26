# Cross-Agent Ingest Survey

**Date:** 2026-06-26  
**Question:** Which coding-agent transcript formats should Faber support next, and what does each cost to ingest?

---

## 1. Faber's Current State

Faber has two live ingest formats:

- **`Faber.Ingest.Format.Claude`** — `~/.claude/projects/**/*.jsonl`, JSONL, one event per line. Fully normalized (type/role/timestamp/uuid/session_id/text/tool_uses/tool_results/cwd/raw).
- **`Faber.Ingest.Format.Codex`** — `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`, JSONL, two parallel event streams (response_item + event_msg). Normalized including tool-name canonicalization (exec_command→Bash, apply_patch→Edit, view_image→Read) and inline context-window pressure via `Event.usage`.

### Normalization boundary (KB: `normalize-divergent-source-formats.md`)

The `Faber.Ingest.Format` behaviour defines the contract:
- `default_base/0` — where the agent stores transcripts
- `discover/1` — finds transcript files
- `stream_file!/1` — lazy stream of `{:ok, Event.t()} | {:error, map()}`
- `normalize/1` — map a decoded record to `Faber.Ingest.Event`

The internal event model (`Faber.Ingest.Event`) has: `type` (`:user/:assistant/:system/:summary/:other`), `role`, `timestamp`, `uuid`, `parent_uuid`, `session_id`, `text`, `tool_uses` (`[%{name, input, id}]`), `tool_results` (`[%{tool_use_id, is_error}]`), `is_meta`, `usage` (`%{prompt_tokens, context_window}`), `cwd`, `raw`.

**Effort rubric:**  
- **Low (1–2 days)** — JSONL with clear role + content structure; tool calls and results are distinct events or content blocks; session_id is stable or trivially threaded  
- **Medium (3–5 days)** — Non-JSONL (JSON array rewrite, SQLite), multi-stream dedup, tool-name canonicalization, schema reverse-engineered  
- **High (1–2 weeks)** — Multiple formats (SQLite + JSONL shards), encrypted/opaque storage, no public schema, only Markdown or plain-text logs  
- **Not viable** — Cloud-only (no local persistence), encrypted with no known key, or pure markdown with no machine-readable structure

---

## 2. Per-Agent Survey

### 2.1 OpenCode (sst/opencode)

| Property | Detail |
|---|---|
| **Storage location** | `~/.local/share/opencode/opencode.db` (SQLite, v1.2+); legacy: `~/.local/share/opencode/storage/{session,message,part}/*.json` shards |
| **Format** | SQLite (WAL mode). Tables: `project`, `session`, `message`, `part`. Messages have `data` JSON column (`$.role = "user"/"assistant"`). Parts have `data` JSON (`$.type = "text"/"tool"/"tool_result"`, with `$.state.input`/`$.state.output` for tool parts). |
| **Schema stability** | SQLite schema managed via Drizzle ORM + migrations. The JSON→SQLite migration was one-way but had bugs (incremental upgrades silently skipped it). Schema is stable post-migration but the `part.data` JSON shape evolves with OpenCode releases. Not formally published in a spec. |
| **Normalization effort** | **Medium.** Read via SQLite (`:ecto_sqlite3` or `:exqlite`). Four tables to join; decode `part.data` JSON for tool calls. Tool names likely native (not Bash/Edit canonical), need mapping table. Session id is on `session` table — threads naturally. Context-pressure signal: OpenCode stores token info in `message.data` or `part.data`, needs investigation against real files. |
| **Adoption / signal value** | **High.** OpenCode is among the top 3 coding-agent CLIs by GitHub stars (2026). Supports Claude, GPT-4o, local models. Full tool-call and error data. Rich friction signal. Shares the AgentSkills spec with Claude Code and Codex — cross-agent skill proposals will directly apply. |
| **Notes** | Legacy JSON shard path is discoverable but orphaned for incremental upgraders. Safe to target SQLite as primary, fall back to shards for legacy sessions. The `anomalyco/opencode` fork (with 30K+ issues indexed) confirms the SQLite path is active. |

---

### 2.2 Gemini CLI (google-gemini/gemini-cli)

| Property | Detail |
|---|---|
| **Storage location** | `~/.gemini/tmp/<project_hash>/chats/session-*.json` (current) |
| **Format** | Single JSON file per session (full rewrite on each turn). The project_hash is derived from the project root path. Format: JSON object with a messages array containing `{role, content, tokenCount, ...}`. Tool execution records (inputs + outputs), token usage metrics, and reasoning summaries included. |
| **Schema stability** | Not formally documented. A JSONL migration proposal (issue #15292) was closed as "not planned" as of late 2025 — so the monolithic JSON rewrite format persists. The session management docs describe the format functionally but not with a field spec. |
| **Normalization effort** | **Low-Medium.** JSON (not JSONL) — load entire file, walk `messages` array. Role mapping is straightforward. Main challenge: confirm tool_call and tool_result shapes in the JSON (not publicly documented in detail; tokscale and cross_agent_session_resumer both support it, implying the shape is stable enough). The full-rewrite-per-turn format means large sessions are memory-resident on parse (Faber streams; may need to load then emit). |
| **Adoption / signal value** | **Very High.** Google's official CLI, rapid growth in 2026. Huge user base. Gemini 2.5 Pro/Flash are used heavily for agentic coding. Long contexts (1M+) make context-pressure signals especially rich. 20+ session types from `cass` project confirm it's a priority target. |
| **Notes** | `Qwen Code` uses the same format at `~/.qwen/tmp/*/chats/session-*.json` — a Qwen fork of Gemini CLI. Supporting Gemini CLI's format likely covers Qwen Code for free. |

---

### 2.3 GitHub Copilot CLI (github/copilot-cli)

| Property | Detail |
|---|---|
| **Storage location** | `~/.copilot/session-state/{session-id}/events.jsonl` + `~/.copilot/session-store.db` (SQLite index) |
| **Format** | JSONL event stream with 20+ event types (messages, tool calls `call_tool`, subagent starts, rewind markers, etc.). Also OpenTelemetry spans at `~/.copilot/otel/*.jsonl`. |
| **Schema stability** | Not formally published. The `events.jsonl` is described in issues as "internal" (issue #3551 requested it be formalized as an official API — open). Schema is reverse-engineered from community tools. Likely stable within minor versions but could break with major Copilot CLI releases. |
| **Normalization effort** | **Medium.** JSONL with typed events — pattern matches on event type. Main unknowns: exact field names for tool call input/output and error detection. Several community token-usage tools (tokscale, copilot-cli-cost) parse it, suggesting the friction-relevant fields (turn counts, tool invocations, errors) are extractable. |
| **Adoption / signal value** | **High.** GitHub Copilot is enterprise-dominant. Copilot CLI is growing rapidly. Org teams running Copilot at scale are exactly the persona for cross-agent skill proposals. |
| **Notes** | The OTel JSONL at `~/.copilot/otel/*.jsonl` may be the cleaner signal source (structured spans with model/token attrs). Worth probing both paths against a real installation. |

---

### 2.4 Cline (cline/cline, VS Code extension)

| Property | Detail |
|---|---|
| **Storage location** | `~/<vscode-globalStorage>/saoudrizwan.claude-dev/tasks/<task-id>/api_conversation_history.json` (Linux: `~/.config/Code/User/globalStorage/saoudrizwan.claude-dev/tasks/`) |
| **Format** | JSON file per task. `api_conversation_history.json`: array of messages in Anthropic API format — `[{role: "user"/"assistant", content: string | [{type: "text"/"tool_use"/"tool_result", ...}]}]`. Also `ui_messages.json` (UI events with cost/token metadata) and `task_metadata.json`. |
| **Schema stability** | The `api_conversation_history.json` uses the Anthropic Messages API format verbatim — highly stable since it mirrors what Cline sends to the API. This is the most standardized schema among non-Claude agents surveyed. |
| **Normalization effort** | **Low.** Cline stores the exact Anthropic Messages API conversation — which maps almost directly onto Faber's `Event` model. Role is `"user"/"assistant"`, tool_use and tool_result are first-class content block types. The primary work is: (1) discovering task directories across different OS globalStorage paths, (2) loading JSON (not streaming JSONL), (3) extracting token usage from `ui_messages.json` for context-pressure. Tool names are the actual tool names Cline configures (Bash, Read/str_replace_based_edit, etc.). |
| **Adoption / signal value** | **High.** Cline is the dominant open-source VS Code coding-agent extension. Heavy usage by solo devs and teams who aren't Claude Code subscribers. Cline CLI 2.0 released 2026. Rich task-level friction signal (per-task cost, files touched, errors). |
| **Notes** | VS Code globalStorage paths differ by OS and VS Code variant (Code, Code-Insiders, VSCodium). The glob `**/saoudrizwan.claude-dev/tasks/*/api_conversation_history.json` covers all variants from the home dir. Cline also stores per-task environment_details and model change events in ui_messages.json — bonus friction signals. |

---

### 2.5 Kimi Code (moonshotai/kimi-cli)

| Property | Detail |
|---|---|
| **Storage location** | `~/.kimi-code/sessions/<workDirKey>/<sessionId>/agents/main/wire.jsonl` + `~/.kimi-code/session_index.jsonl` |
| **Format** | JSONL event stream (`wire.jsonl`) — the complete agent event stream used for session resumption and replay. `session_index.jsonl` is a line-per-session index (`sessionId`, `sessionDir`, `workDir`). Also `state.json` (metadata: title, lastPrompt, timestamps). |
| **Schema stability** | Documented in official Kimi Code CLI docs (data-locations, sessions guides). The wire.jsonl format is described as "complete communication record" but the per-record schema is not publicly specced. Growing project (Moonshot AI, 2025-2026). |
| **Normalization effort** | **Medium.** JSONL + index pattern is familiar. Unknown: exact wire event schema (similar to Codex's two-stream pattern?). Kimi Code supports extended thinking — reasoning events need to be handled as `:other`. tokscale parses it for token usage — field paths available in that source. |
| **Adoption / signal value** | **Medium-High.** Growing rapidly in Asia, increasingly global. Kimi k2 model has strong agentic capabilities. Sessions contain tool call friction data. |

---

### 2.6 Aider (Aider-AI/aider)

| Property | Detail |
|---|---|
| **Storage location** | `.aider.chat.history.md` (per-project, CWD), `.aider.input.history` (user inputs), optional `.aider.llm.history` (raw LLM messages, must be opted-in with `--llm-history-file`) |
| **Format** | `.aider.chat.history.md`: **Markdown** — human-readable transcript, not machine-readable JSON. `.aider.llm.history` (opt-in): standard OpenAI/Anthropic messages JSON array format (role/content pairs). NOT written by default. |
| **Schema stability** | The Markdown history format is stable but unstructured. The `llm-history-file` JSON format mirrors the underlying LLM API messages — stable and well-understood. However, requiring opt-in means almost no Aider user has the machine-readable history. |
| **Normalization effort** | **High** for the default Markdown format (parse Markdown conversations, no tool_call structure). **Medium** if targeting `llm-history-file` JSON (but requires opt-in from every user). Either way, Aider doesn't write tool calls as structured data — it uses edit formats (SEARCH/REPLACE blocks, unified diffs, whole-file replacement) in the message text. |
| **Adoption / signal value** | **Medium.** Aider has large mindshare (the original AI pair programmer), but the session data is structurally sparse: no tool_call events, no error taxonomy, edits are embedded in message text. The friction signals Faber detects (retry loops, tool errors, context pressure) are present but not extractable cleanly. Aider's friction is mainly in edit format failures and repeated correction prompts — detectable from markdown text but with much lower precision than structured formats. |
| **Notes** | Not worth implementing in v1 unless a `--llm-history-file` detection path is added (auto-enable for Faber-enrolled users). Consider as a Phase 2 stretch goal with user-opt-in requirements. |

---

### 2.7 Cursor (Cursor IDE)

| Property | Detail |
|---|---|
| **Storage location** | `~/Library/Application Support/Cursor/User/globalStorage/` — `state.vscdb` (SQLite, ~1–2 GB) with workspace-level `state.vscdb` per project (`~/.cursor/workspaceStorage/<hash>/state.vscdb`) |
| **Format** | SQLite with a `cursorDiskKV` key-value table. Keys: `composerData:<composerId>` (session metadata, `fullConversationHeadersOnly`), `bubbleId:<composerId>:<bubbleId>` (individual messages/responses), `agentKv` (request-level message blobs with role + content), `checkpointId` (diff state). Sizes: agentKv ~506 MB, bubbleId ~463 MB, composerData ~45 MB across ~1,188 entries. |
| **Schema stability** | Not documented. Entirely reverse-engineered (github.com/S2thend/cursor-history, cursor-view, vibe-replay.com blog). Subject to silent schema changes on IDE updates. Multiple community extractors exist but track schema changes manually. Not every composerData row is replayable; data is fragmented across key families. |
| **Normalization effort** | **High.** SQLite with a bespoke KV schema — no row-per-message table. Must deserialize composerData JSON, traverse `fullConversationHeadersOnly`, then join with bubbleId entries. Tool calls live in agentKv blobs. Cross-platform path differences (macOS/Linux/Windows). High maintenance risk: schema changes break extraction on IDE update. The 1–2 GB database size makes streaming critical. |
| **Adoption / signal value** | **Very High** (millions of users). But the extraction difficulty and maintenance cost are the highest of any agent surveyed. Multiple open-source extractors exist, which derisks implementation somewhat, but Faber would need to track Cursor schema changes independently. |
| **Notes** | Worth implementing eventually, but the maintenance burden is high. Consider forking or depending on a community library that tracks the schema. |

---

### 2.8 Amp (ampcode.com)

| Property | Detail |
|---|---|
| **Storage location** | `~/.local/share/amp/threads/` |
| **Format** | Thread-based. Exact schema not publicly documented. Sessions (threads) are primarily stored in Sourcegraph's cloud (ampcode.com/threads), with local copies of thread data. After killing the VS Code extension in March 2026, Amp is CLI-only. |
| **Schema stability** | Unknown. Cloud-primary storage with local cache. Not documented. No community extraction tooling found. |
| **Normalization effort** | **High/Unknown.** Without a documented or reverse-engineered schema, implementation is speculative. |
| **Adoption / signal value** | **Medium.** Niche but sophisticated user base. Cloud-primary model limits local transcript richness. |

---

### 2.9 Continue (continue.dev)

| Property | Detail |
|---|---|
| **Storage location** | VS Code extension global storage — but Continue's primary differentiator is its context/indexing layer, not session transcripts |
| **Format** | No stable local session transcript format found. Chat mode operates in-IDE without a structured persistent log beyond the VS Code webview state. |
| **Schema stability** | Not applicable — no known local session transcript format. |
| **Normalization effort** | **Not viable** for v1. No local session log to mine. |
| **Adoption / signal value** | **Low** for Faber's specific use case (friction mining from transcripts). Continue's value is IDE-native context, not agentically running tasks that generate rich tool-call logs. |

---

### 2.10 Windsurf (Codeium)

| Property | Detail |
|---|---|
| **Storage location** | `~/.codeium/windsurf/memories/` (memories), `.windsurf/rules/` (rules). Conversation history: unclear — likely in VS Code/Electron app data (`~/Library/Application Support/Windsurf/`) as SQLite, similar to Cursor. |
| **Format** | Probable Electron/VS Code SQLite pattern, but no confirmed schema found. Memories are plain-text files. |
| **Schema stability** | Unknown — schema not publicly documented or reverse-engineered. |
| **Normalization effort** | **High/Unknown.** Same category as Cursor (Electron IDE) but without even the community extraction tooling Cursor has. |
| **Adoption / signal value** | **Medium.** Significant user base (ex-Codeium users). But without a confirmed local storage path, implementation is blocked pending reverse-engineering. |

---

### 2.11 Pi (pi.ai / Inflection AI)

| Property | Detail |
|---|---|
| **Storage location** | `~/.pi/agent/sessions/` (Pi Agent mode) |
| **Format** | Session JSONL with thinking blocks (per tokscale and cass tool). |
| **Schema stability** | Reverse-engineered. Pi Agent is relatively new and the schema may evolve. |
| **Normalization effort** | **Medium.** JSONL with thinking blocks similar to Codex's reasoning events. |
| **Adoption / signal value** | **Low-Medium.** Pi Agent is not widely used as a coding agent — Pi.ai is primarily a conversational AI. Niche adoption among power users. |

---

### 2.12 Kiro (AWS)

| Property | Detail |
|---|---|
| **Storage location** | `~/.kiro/` (config, credentials). Session transcripts: described as JSONL locally, but schema not confirmed from primary sources. AWS Kiro CLI announced mid-2025, uses ACP protocol. |
| **Format** | Likely JSONL (per ACP standard), but not verified with schema evidence. |
| **Schema stability** | Too early — new product (2025). Schema likely volatile. |
| **Normalization effort** | **Unknown.** Defer pending more data. |
| **Adoption / signal value** | **Medium-Low** for 2026 (early adoption phase). AWS ecosystem means enterprise growth trajectory, but not yet the dense user base that produces rich session corpora. |

---

## 3. Summary Table

| Agent | Format | Path | Stability | Effort | Adoption | Priority |
|---|---|---|---|---|---|---|
| **OpenCode** | SQLite + legacy JSON shards | `~/.local/share/opencode/opencode.db` | Medium (ORM-managed) | Medium | High | **#1** |
| **Gemini CLI** | JSON (full rewrite) | `~/.gemini/tmp/<hash>/chats/session-*.json` | Medium (no formal spec) | Low-Medium | Very High | **#2** |
| **Cline** | JSON (task dirs) | `*/saoudrizwan.claude-dev/tasks/*/api_conversation_history.json` | High (mirrors Anthropic API) | Low | High | **#3** |
| **GitHub Copilot CLI** | JSONL events | `~/.copilot/session-state/<id>/events.jsonl` | Medium (informal) | Medium | High | **#4** |
| **Kimi Code** | JSONL (wire.jsonl) | `~/.kimi-code/sessions/<key>/<id>/agents/main/wire.jsonl` | Medium (documented) | Medium | Medium-High | **#5** |
| **Cursor** | SQLite KV bespoke | `~/Library/Application Support/Cursor/User/…/state.vscdb` | Low (reverse-engineered, changes) | High | Very High | Later |
| **Aider** | Markdown / opt-in JSON | `.aider.chat.history.md` | High (stable Markdown) | High (sparse signal) | Medium | Stretch |
| **Amp** | Unknown local | `~/.local/share/amp/threads/` | Unknown | High/Unknown | Medium | Blocked |
| **Windsurf** | Probable Electron SQLite | Unknown path | Unknown | High/Unknown | Medium | Blocked |
| **Continue** | None found | N/A | N/A | Not viable | Low | Skip |
| **Pi** | JSONL | `~/.pi/agent/sessions/` | Low (reverse-engineered) | Medium | Low | Deprioritize |
| **Kiro** | Likely JSONL | `~/.kiro/` (unconfirmed) | Unknown (new) | Unknown | Low-Medium | Defer |

---

## 4. Recommended Priority Order (Next 2–3 Adapters)

### Priority 1: Cline

**Justification:** Lowest normalization effort of any new agent. The `api_conversation_history.json` stores the Anthropic Messages API format verbatim — tool_use and tool_result content blocks map almost 1:1 to Faber's Event model. No tool-name canonicalization needed (Cline uses Claude's native tool names). The only challenges are VS Code globalStorage path discovery (multi-OS glob) and loading JSON-not-JSONL (wrap in `Jason.decode` + emit events sequentially). Cline has very high adoption among Claude Code-adjacent users — the exact audience most likely to also want cross-agent skill improvement. **Estimate: 1–2 days.**

### Priority 2: Gemini CLI

**Justification:** Very high adoption + growing fast = biggest untapped corpus. The format (JSON file with messages array) is well-understood by multiple community tools. The full-file-per-session JSON is a minor wrinkle (load whole file, then stream events) but manageable. Tool calls and results are present in the JSON. The `project_hash` path scheme means sessions are project-local — Faber can infer cwd from the hash lookup. Bonus: Qwen Code uses the same format, so this adapter covers two agents. **Estimate: 2–3 days.**

### Priority 3: OpenCode

**Justification:** OpenCode is the other major Claude-Code-aware agent (supports AgentSkills spec natively) — cross-agent skill proposals will have the highest hit rate here. The SQLite backend requires adding a SQLite read dependency (`exqlite` or raw `sqlite3` NIF), but the schema is table-structured and well-enough understood. The `part.data` JSON for tool calls needs real-file verification before shipping. The legacy JSON shard path adds a fallback case. **Estimate: 3–5 days.**

### After #3: GitHub Copilot CLI (enterprise reach) or Kimi Code (JSONL, familiar pattern)

---

## 5. Not Worth It (for v1)

- **Continue** — No local session transcript format. Skip entirely.
- **Aider** — Markdown-only by default; the machine-readable `llm-history-file` requires user opt-in and still lacks structured tool calls. Signal too sparse relative to effort. Consider only if Faber adds an "enroll this agent" setup flow.
- **Windsurf** — Electron IDE without confirmed local storage path or schema. Blocked pending community reverse-engineering.
- **Amp** — Cloud-primary. Local path exists but schema is unknown and the product killed its VS Code extension. Wait for community tooling.
- **Pi** — Niche coding-agent adoption. Limited friction signal value relative to effort.
- **Kiro** — Too early. Schema volatile, low user base. Revisit in 6 months.

---

## 6. Sources

- [DeepWiki: sst/opencode Storage and Database](https://deepwiki.com/sst/opencode/2.9-storage-and-database)
- [DeepWiki: sst/opencode Session Management](https://deepwiki.com/sst/opencode/2.1-session-management)
- [DeepWiki: sst/opencode Message and Part Structure](https://deepwiki.com/sst/opencode/2.2-message-and-prompt-system)
- [GitHub issue: OpenCode JSON→SQLite migration bug](https://github.com/anomalyco/opencode/issues/13654)
- [DeepWiki: google-gemini/gemini-cli Session Management](https://deepwiki.com/google-gemini/gemini-cli/3.9-session-management)
- [GitHub issue: Gemini CLI JSONL session storage (closed not planned)](https://github.com/google-gemini/gemini-cli/issues/15292)
- [Gemini CLI session management docs](https://geminicli.com/docs/cli/session-management/)
- [DeepWiki: cline/cline Disk Storage Organization](https://deepwiki.com/cline/cline/5.2-disk-storage-organization)
- [GitHub: cline/cline task history reconstruction issue](https://github.com/cline/cline/issues/7742)
- [GitHub Docs: Copilot CLI session data](https://docs.github.com/en/copilot/concepts/agents/copilot-cli/chronicle)
- [DeepWiki: github/copilot-cli Session Management](https://deepwiki.com/github/copilot-cli/3.3-session-management-and-history)
- [GitHub: Copilot CLI events.jsonl formalization request](https://github.com/github/copilot-cli/issues/3551)
- [Cursor local storage deep dive (vibe-replay)](https://vibe-replay.com/blog/cursor-local-storage/)
- [github.com/S2thend/cursor-history](https://github.com/S2thend/cursor-history)
- [Kimi Code data locations docs](https://www.kimi.com/code/docs/en/kimi-code-cli/configuration/data-locations.html)
- [Kimi Code sessions docs](https://www.kimi.com/code/docs/en/kimi-code-cli/guides/sessions.html)
- [Windsurf Cascade Memories docs](https://docs.windsurf.com/windsurf/cascade/memories)
- [Aider options reference](https://aider.chat/docs/config/options.html)
- [Stanislas blog: TUI to index coding agent sessions](https://stanislas.blog/2026/01/tui-index-search-coding-agent-sessions/)
- [github.com/Dicklesworthstone/coding_agent_session_search](https://github.com/Dicklesworthstone/coding_agent_session_search)
- [github.com/Dicklesworthstone/cross_agent_session_resumer](https://github.com/Dicklesworthstone/cross_agent_session_resumer)
- [github.com/junhoyeo/tokscale](https://github.com/junhoyeo/tokscale)
- **KB:** `scriptorium/wiki/normalize-divergent-source-formats.md`
- **KB:** `scriptorium/solutions/claude-code-session-jsonl-schema.md`
- **KB:** `scriptorium/output/absorb-chunks/research-elixir-live-claude-engineer-2026-05-08-issue-45-adapt-plugin-for-other-agents/03-coding-agent-landscape-may-2026.md`
- **Project:** `faber/.claude/research/2026-06-23-codex-ingest-format.md`
