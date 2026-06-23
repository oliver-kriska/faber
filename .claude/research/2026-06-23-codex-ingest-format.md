# Codex ingest format — schema + mapping decisions

**Date:** 2026-06-23
**Context:** Oliver ran `ccrider sync` and it loaded 14 codex sessions, expecting codex to work in
Faber. Investigation (see `2026-06-23-ccrider-as-ingestion-source.md`) established ccrider stores
codex `messages.content` **empty** (only `text_content`), so tool/usage structure isn't recoverable
through ccrider. The only full-fidelity path is a native format reading `~/.codex/sessions`. This
note records the codex transcript schema and the mapping `Faber.Ingest.Format.Codex` implements.

## On-disk layout

`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` — line-delimited JSON, one **event** per line.
14 files present locally (codex CLI `0.142.0`, model `gpt-5.5`). Every line has top-level
`{timestamp, type, payload}`; the discriminator is `type` + `payload.type`.

## Event inventory (across all 14 sessions)

| type / payload.type | count | role in Faber |
|---|---|---|
| `response_item/function_call` | 342 | tool call (exec/read/stdin) |
| `response_item/function_call_output` | 341 | tool result + error |
| `event_msg/token_count` | 273 | usage + **inline** context window |
| `response_item/message` | 243 | **dropped** — AGENTS.md preamble + role dupes |
| `response_item/reasoning` | 192 | inert |
| `event_msg/agent_message` | 151 | assistant text |
| `turn_context` | 81 | inert (carries `model`, `cwd`, `effort`) |
| `event_msg/agent_reasoning` | 61 | inert |
| `event_msg/user_message` | 27 | **the human's typed prompt** |
| `event_msg/task_started` / `task_complete` | 19 / 18 | inert |
| `response_item/custom_tool_call` (+output) | 18 | `apply_patch` (file edits) |
| `event_msg/patch_apply_end` | 15 | inert (apply telemetry) |
| `session_meta` | 14 | seeds session id (1 per file, first line) |
| `web_search_*`, `image_generation_*` | ~5 each | inert |

## Why two streams, and which we take

Codex emits a turn across both `response_item/*` (API conversation items) **and** `event_msg/*` (UI
telemetry). Counting both double-counts. Canonical view:

- **user turns** ← `event_msg/user_message`. The `response_item/message[role=user]` lines are the
  injected `AGENTS.md`/skills preamble, *not* real input — confirmed by inspection.
- **assistant text** ← `event_msg/agent_message`.
- **tool calls** ← `response_item/function_call` + `custom_tool_call` (only place args live).
- **tool results** ← `function_call_output` + `custom_tool_call_output`.
- **usage** ← `event_msg/token_count`.

## Tool-name normalization (key decision)

`Faber.Detect`'s signals are **name-keyed** to Claude's vocabulary (`Bash`, `Edit`, `Read`, …):
`retry_loops` / `bash_commands` filter `name == "Bash"` and read `input["command"]`; `files_edited`
reads `input["file_path"]` off `Edit`/`Write`. Codex's native names (`exec_command`, `apply_patch`)
would leave all those signals dead. **Decision: normalize at the format boundary** (that's the
Format's job — map on-disk shape → engine-internal shape), not by teaching Detect codex vocab.

| codex tool | → canonical | input mapping |
|---|---|---|
| `exec_command` | `Bash` | `cmd` → `command`, keep `workdir` |
| `apply_patch` (custom) | `Edit` ×N | one per `*** Add/Update/Delete File:` path in the patch |
| `view_image` | `Read` | `path` → `file_path` |
| `write_stdin` | `WriteStdin` | counted, but **not** Bash (must not register as a retry) |
| unknown | name preserved | still counts toward `error_tool_ratio` |

## Error detection

`function_call_output.output` is a string (`Process exited with code N\n…`) or a list (image data).
`is_error` when: `code != 0`; or (no exit line) a `^\w+ failed:` prefix / `SandboxDenied`. List
outputs are never errors. `custom_tool_call_output.output` is a JSON string carrying
`metadata.exit_code` — use that, falling back to the inner `output` text heuristic.

## Context pressure (the impedance mismatch)

Claude carries per-turn usage on the assistant message and derives the window from `message.model`
via a static map. **Codex carries the window inline** in `token_count.info.model_context_window`
(e.g. 258400 for gpt-5.5), and the model isn't in any static map. Rather than couple Detect to
codex's `payload.info` shape, added a normalized **`Event.usage`** field
(`%{prompt_tokens, context_window}`): the codex format fills it from
`last_token_usage.input_tokens` (already includes the cached portion) + the inline window;
`Detect.context/1` prefers it when present, else falls back byte-for-byte to the Claude
`message.usage` path. `info` is `null` early in a session → guarded to `nil`.

## Known asymmetries (documented in the moduledoc)

- Codex emits one line per conversation item; Claude batches text + multiple `tool_use` into one
  message. So codex `message_count` and tool counts run higher than the Claude equivalent for the
  same work. Friction is consistent *within* the codex corpus; cross-agent absolute counts aren't
  directly comparable.
- No codex marker for interrupts/compactions in the current schema → those signals stay 0.
- `primary_model` is left `nil` on the codex path (Scan doesn't surface it; scoring never reads it).

## Verification

Hermetic synthetic fixture `test/fixtures/codex/codex_session.jsonl` + `ingest_codex_test.exs`
(12 tests, run in the default suite — no python/sqlite needed). Real-data run over all 14 sessions:
every session scored, top friction `raw=3.16` (bug-fix, 287 msgs, 112 tools, ctx 69.1%), context
pressure computed from inline windows (no `ctx>100%` artifact).

Usage: `faber scan --format codex` (or `--source files --format codex`). ccrider remains
claude-only for now (its codex `content` is empty).
