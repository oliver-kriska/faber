---
scriptorium: true
action: create
title: "Faber Elixir Tooling Decisions"
type: decision
domain: claude-elixir-phoenix
tags: [faber, elixir, otp-29, jason, yaml_elixir, exile, req_llm, oban, dependencies, subprocess]
---

Dependency decisions for **Faber** (the generic retrospective-skill engine extracted from
the claude-elixir-phoenix plugin; Elixir/OTP spine + Python eval sidecar). Made 2026-06-18
from five parallel `hex-library-researcher` runs, verified on **Elixir 1.20.1 / OTP 29**.
Reusable wherever an Elixir tool needs to ingest JSONL, load YAML config, shell out to
Python, or call an LLM.

## Verdicts

| Need | Pick | Rejected / deferred |
|---|---|---|
| JSON / JSONL ingest | **`jason ~> 1.4`** + stdlib `Path.expand`→`Path.wildcard`. JSONL = line-delimited; `File.stream!(_, :line)` + `Jason.decode(line, keys: :strings)`. | Jaxon (dead, NIF, pointless when each line is small); Poison; path_glob (in-memory only). |
| YAML config + frontmatter | **`yaml_elixir ~> 2.12`** (pure-Erlang yamerl, no NIF, string keys). Frontmatter: inline split on `\n---\n`. | `fast_yaml` (NIF/libyaml); `yaml_front_matter` (dead wrapper). |
| Config validation | **hand-roll now; Peri or Ecto when rich errors needed** (Ecto arrives via ecto_sqlite3 if Oban lands). | `drops` (LGPL); `nestru`/`norm` (wrong tool / dead). |
| Elixir→Python subprocess | **`exile ~> 0.14`** — only lib with stdin + separate stderr (`:consume`) + clean SIGTERM→SIGKILL. Map exit codes via `Exile.Process` + `await_exit/2`. | `System.cmd`/raw `Port` (no stdin, no timeout-kill, pipe deadlock + orphans); `Rambo`/`Porcelain` (dead); `MuonTrap` (no stdin); `erlexec` (heavyweight). Runner-up `ex_cmd` (pure Elixir, no separate stderr). |
| Embedded Python (later) | **Pythonx deferred** — single GIL serializes all calls, collapsing `Task.async_stream` concurrency to single-threaded Python. Subprocess wins for concurrent eval. | — |
| LLM client | **`req_llm ~> 1.6` (agentjido fork)** — `generate_object/4` for validated structured output; `provider_options: [anthropic_prompt_cache: true]`. No `instructor_ex` needed. | LangChain Elixir; raw Anthropic SDK. See [[ReqLLM]] ownership-change note. |
| Background loop | **plain supervised GenServer + `Process.send_after`** for v1; **Oban OSS 2.23 + `ecto_sqlite3`** only when cross-restart persistence is needed (SQLite Lite engine removes the Postgres barrier but is newer/less mature). | Quantum (stale). |
| Git ops | **`System.cmd("git", …)`** behind a `Faber.Git` facade. | `git_cli`, `gitex` (both dead). |
| CLI packaging / UX | **`escript`** + **`optimus`** (subcommands) + **`owl`** (progress/tables). | Burrito/Bakeware deferred (Zig toolchain; only for non-Erlang targets). |

## Cross-cutting gotchas

- **Atom exhaustion:** always decode untrusted transcript JSON with `keys: :strings`, never
  `:atoms`/`:atoms!`.
- **Pipe deadlock:** a child filling the ~64 KB pipe buffer on an undrained stream blocks;
  Exile's `:consume` mode multiplexes stdout+stderr and prevents it.
- **`Path.wildcard` ignores `~`** — `Path.expand` first.
- **OTP 29 bleeding edge:** `yamerl` compiles but emits a `'catch ...' deprecated` warning
  (harmless). All picks above resolve + compile + test on Elixir 1.20.1 / OTP 29.

## Reinforced patterns

This stack operationalizes [[Script-First LLM-Second]]: the Elixir spine + Python sidecar
do deterministic extraction/scoring → structured JSON → the LLM (req_llm) only interprets.
Its corollary — wrap JSONL-ledger mutation in a subprocess (LLMs corrupt structured data) —
applies to Faber's M5 autoresearch journal.
