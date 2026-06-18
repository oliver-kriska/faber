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

## Decisions (filled as research lands)

- **R1:** _pending agent_
- **R2:** _pending agent_
- **R3:** _pending agent_
- **R4:** ReqLLM (KB verdict `use`) — pending current-version/OTP-29 confirmation.
- **R5:** _pending agent_

## Findings

_(Appended per area as the subagents report.)_
