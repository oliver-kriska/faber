# Faber — Elixir dependency needs (research brief)

> What the Elixir spine needs libraries for, per pipeline stage, and the candidates under
> evaluation. Findings from the `hex-library-researcher` subagents (launched 2026-06-18)
> are appended per area as they land. Environment: **Elixir 1.20.1 / OTP 29** (bleeding
> edge — compatibility must be checked), local-first CLI tool, keep the dependency
> surface small.

## Prior art (from Oliver's scriptorium KB — checked before recommending)

- **LLM client → ReqLLM** (`neilberkman/req_llm`), KB verdict **use** (high confidence).
  Already used in Enaia + Virgil; unified Anthropic/OpenAI/Azure/Bedrock, streaming,
  prompt caching. Gotcha: `generate_text/3` returns `%ReqLLM.Response{}` — extract text
  with `ReqLLM.Response.text/1`. Alternatives already rejected: LangChain Elixir, raw
  Anthropic SDK. → Treat as the default; the R4 agent only *confirms* it still fits.
- **Raw JSONL session parsing** is already proven (`solutions/session-parsing.md`),
  validated on a 1,757-message transcript, ccrider-free — the ingest premise is sound.
- **Script-first / LLM-second** (`patterns/script-first-llm-second.md`, high confidence):
  deterministic extraction → structured JSON → LLM interprets. Validates Faber's
  spine+sidecar+proposer split. Corollary: **wrap JSONL-ledger mutation in a subprocess**
  — LLMs corrupt structured data. Applies to the M5 autoresearch journal.
- **Hook IO contract** (`patterns/codex-hook-event-io-contract.md`): JSON on stdin, JSON
  on stdout, exit `0` ok / `2` block / other fail. Informs both the Python sidecar
  boundary and future Codex-session ingest.

## Needs by stage

| # | Stage / need | What for | Candidates | KB verdict? |
|---|---|---|---|---|
| R1 | **Ingest** — JSON + JSONL | Parse `~/.claude/projects/**/*.jsonl` (large, line-delimited, one JSON object per line; tool_use / tool_result / messages). Decode fast, stream large files, tolerate malformed lines. Glob discovery. | `Jason`, `Jaxon` (streaming), `Poison`; `File.stream!` + per-line decode; `Path.wildcard` (built-in) | parsing proven; lib TBD |
| R2 | **Adapter config** — YAML + frontmatter + validation | Load `faber.adapter.yaml` + per-file YAML frontmatter (laws/detect/…); validate against the adapter contract (required fields, types, unique ids). | YAML: `yaml_elixir`, `fast_yaml`, `yamerl`. Frontmatter: `yaml_front_matter` or roll-own. Validation: Ecto embedded schemas (no DB), `peri`, `drops`, `nestru`, `norm` | TBD |
| R3 | **Eval boundary** — subprocess / port | Spawn `python -m faber_eval <cmd>`, write JSON stdin, read JSON stdout; timeouts, large output, error capture, no zombies, concurrent under `Task.async_stream`. Plus eval embedded-CPython option for later. | `System.cmd`, `Port`, `Exile`, `ex_cmd`, `Rambo`, `MuonTrap`, `erlexec`; later: `Pythonx` | IO contract known; lib TBD |
| R4 | **Proposer** — LLM client | Adapter-informed Claude calls; structured/JSON output; retries; prompt caching. | **ReqLLM** (default), vs LangChain Elixir, `instructor_ex`, raw `Req` | **use ReqLLM** (confirm only) |
| R5 | **Loop infra** — jobs + git + CLI packaging | M5 overnight runs (Oban); git rollback between iterations; plateau bookkeeping. Local-first CLI distribution. | Jobs: `Oban` (OSS). Git: `System.cmd("git", …)` vs `git_cli`. CLI: `escript` vs `Burrito`/`Bakeware`; arg/UX: `OptionParser`/`Optimus`/`Owl` | Oban is the Elixir standard (KB glossary) |

## Decisions

| # | Decision | Add at | Notes |
|---|---|---|---|
| R1 | **`jason ~> 1.4`** for JSON; stdlib `Path.expand` + `Path.wildcard` for discovery | M2 (added now) | JSONL = line-delimited; `File.stream!(_, :line)` + `Jason.decode(line, keys: :strings)`. No streaming-JSON parser needed. |
| R2 | **`yaml_elixir ~> 2.12`** for YAML; **roll-own frontmatter** (split on `---`); **validation: hand-roll now, pick Peri or Ecto when rich errors needed** | M2 (yaml added now) | yaml_elixir is pure-Erlang (yamerl), no NIF. Validation lib is an open call — see below. |
| R3 | **`exile ~> 0.14`** for the Python sidecar; **Pythonx deferred** | M4 | Only lib with stdin + separate stderr + clean kill. Use `:consume` mode (pipe-deadlock guard). Runner-up `ex_cmd` (pure Elixir, no NIF) if C build is a problem. Reject `System.cmd` (no stdin, deadlock). |
| R4 | **`req_llm ~> 1.6`** (agentjido) for the proposer; **no `instructor_ex`** | M3 | `generate_object/4` gives validated structured output; `provider_options: [anthropic_prompt_cache: true]`. **Ownership changed** — see finding. |
| R5a | **plain GenServer + `Process.send_after`** for the M5 loop; **Oban OSS (+`ecto_sqlite3`) deferred to M6** | M5 / M6 | Oban 2.23 now has a SQLite `Lite` engine (Postgres barrier gone) but it's overkill + the Lite engine is new/less mature. |
| R5b | **`System.cmd("git", …)`** behind a `Faber.Git` facade for rollback | M5 | No git lib earns its keep; the lib options are all dead. |
| R5c | **`escript`** packaging; **`optimus`** args; **`owl`** terminal UX | M5 | Burrito deferred to M6 (needs Zig; only matters for non-Erlang machines). |

**Verified on this host (Elixir 1.20.1 / OTP 29):** `jason 1.4.5`, `yaml_elixir 2.12.2`, `yamerl 0.10.0` resolve, compile, and pass tests. `yamerl` emits one harmless `'catch ...' deprecated` warning on OTP 29 (Erlang dep, not an error). This answers the compat caveat every agent flagged.

### Open decision — validation library (R2)

`hex-library-researcher` recommended **Ecto embedded schemas** (familiar, best error messages, and Faber pulls Ecto via `ecto_sqlite3` at M6 anyway). Runner-up **Peri** (lighter, purpose-built, no DB baggage). For now the adapter loader can hand-roll required-field/type/unique-id checks (~30 lines, no dep); commit to Peri **or** Ecto when community-author-grade error messages are needed. **Recommend: Peri unless/until Ecto lands for storage.** Flagged for Oliver.

## Findings (per subagent)

### R1 — Ingest (Jason)
Jason 1.4.5 sole pick (pure Elixir, no NIF, de-facto standard). Jaxon rejected (dead since 2021, NIF, and JSONL lines are already small — median ~7–13 KB, max ~29 KB on real transcripts — so streaming-within-a-line buys nothing). `Path.wildcard` does **not** expand `~` → must `Path.expand` first. **Gotcha:** always `keys: :strings` (never `:atoms`/`:atoms!`) on transcript lines — atom exhaustion DoS.

### R2 — Adapter config (yaml_elixir + hand-roll/validate)
yaml_elixir 2.12.2 (pure-Erlang yamerl, no C toolchain, string keys by default, `atoms: false` is safe). Frontmatter: inline split on `\n---\n` (the hex `yaml_front_matter` is a dead 5-line wrapper). Validation: Ecto embedded schemas recommended; Peri runner-up. Rejected: `fast_yaml` (NIF), `drops` (LGPL), `nestru`/`norm` (wrong tool / dead). **Gotcha:** string vs atom keys — normalize early; use `String.to_existing_atom` if converting.

### R3 — Sidecar boundary (Exile)
Exile 0.14.0 — only lib with stdin write + separate stderr (`:consume`) + SIGTERM→SIGKILL escalation, active on OTP 29 (POSIX NIF, low build risk; needs C compiler). Runner-up `ex_cmd` (same author, pure Elixir, no separate stderr). **Pythonx deferred** — single GIL serializes all calls, collapsing `Task.async_stream` concurrency to single-threaded Python. Rejected: `System.cmd`/raw `Port` (no stdin, no timeout-kill, deadlock + orphans), `Rambo`/`Porcelain` (dead), `MuonTrap` (no stdin), `erlexec` (heavyweight). **Gotcha:** stdout/stderr pipe deadlock at ~64 KB — `:consume` mode multiplexes both pipes and prevents it. Map exit codes via `Exile.Process` + `await_exit/2` (0 ok / 1 bad request / 2 unknown command).

### R4 — Proposer (req_llm, agentjido) — ⚠ ownership change
**`req_llm` is no longer `neilberkman/req_llm`.** The hex package is now published by `mikehostetler` from **`agentjido/req_llm`** (agentjido.xyz) — same hex name, substantially evolved successor. **v1.16.0, released 2026-06-11**, ~16K downloads/30d. Covers Anthropic prompt caching (`provider_options: [anthropic_prompt_cache: true, anthropic_prompt_cache_ttl: "1h"]` — auto-applies `cache_control` to the last system block + tool defs), structured output via `generate_object/4` (JSON-schema or strict-tool mode, returns a validated map), current Claude model specs (`"anthropic:claude-opus-4-8"` etc.). **No `instructor_ex` needed.** **Gotcha:** treat it as a new library that shares the hex name — old Enaia/Virgil `generate_text/3` + `Response.text/1` call sites must be re-checked against current hexdocs. → KB update filed.

### R5 — Loop infra
(a) **Jobs:** plain supervised GenServer + `Process.send_after` for M5; Oban OSS 2.23 + `ecto_sqlite3 ~> 0.24` deferred to M6 (SQLite Lite engine removes the Postgres barrier but is newer/less mature; loop is a single sequential pipeline, not a queue). Quantum rejected (stale). (b) **Git:** `System.cmd("git", …)` behind a `Faber.Git` facade — git libs (`git_cli`, `gitex`) are all dead. (c) **CLI:** `escript` now (single binary, only needs Erlang present); `optimus 0.6.1` (clap-style subcommands) + `owl 0.13.1` (progress/tables/spinners for the loop's "iteration N, Δscore" output). Burrito/Bakeware deferred (Zig toolchain; only for non-Erlang targets). **Gotcha:** Oban's SQLite Lite engine has explicitly "differing maturity" — validate before depending on it at M6.
