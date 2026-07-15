# Faber

**A local-first, cross-agent, stack-aware improvement engine for AI coding agents.**

Faber mines your *real* coding-agent sessions (Claude Code, Codex, Cline, Gemini / Qwen Code,
and OpenCode today; Pi later) for repetitive, painful workflows, then generates **skills** that automate them —
but only skills that a stack-specific **adapter** vouches for and that pass an
**evaluation gate**. Over time it runs a self-improving loop to make those skills better.

> *"It mines your sessions for pain and emits skills your stack's expert adapter vouches for."*
> — not "AI that writes your skills."

The name **Faber** is Latin for *the maker / smith* (`homo faber`; `faber est suae quisque
fortunae` — "each is the craftsman of his own fortune", i.e. the self-improvement loop).

## Why it's different

Faber owns the two ends nobody owns and composes the proven middle:

- **Content-level session retrospective → friction detection.** It mines the real
  transcript (tool calls, failures, repetition), not a shallow `/insights` report.
- **The domain-adapter abstraction**, which supplies BOTH the generation knowledge (Iron
  Laws, investigation playbooks) AND the stack-specific eval criteria. Correct-for-Elixir
  ≠ correct-for-Rails — and that's the part a generic skill-creator can't commoditize.
- It does **not** rebuild token metering (`ccusage` does that) or the evolve→eval→keep
  optimizer (GEPA / DSPy / EvoSkill exist) — it composes them.

## Architecture

An **Elixir/OTP spine** (this app: ingest, detect, adapter loading, the loop, and a later
LiveView dashboard) with a **Python eval sidecar** (`python/`: GEPA/DSPy optimizer and
eval matchers, reached over a JSON-in/JSON-out subprocess boundary for v1).

```
ingest sessions → detect friction → propose skill (adapter-informed)
   → eval gate (structural + trigger accuracy + adapter criteria)
   → present / install → [optional] autoresearch loop until plateau
```

## Status

**M0–M6 implemented** — the full pipeline runs end to end:

| Milestone | What | Module(s) |
|-----------|------|-----------|
| M0 | Scaffold, sidecar stub, adapter skeleton, contract spec | — |
| M1 | Adapter contract + `faber-elixir` pack (zero plugin diffs) | `Faber.Adapter` |
| M2 | Ingest + friction/fingerprint/opportunity scan, ranked, sidechain-deduped | `Faber.Ingest`, `Faber.Detect`, `Faber.Scan`, `mix faber.scan` |
| M3 | Adapter-informed skill proposer (pluggable LLM, ReqLLM) | `Faber.Propose`, `Faber.LLM`, `Faber.Proposal` |
| M4 | Eval gate via the Python matcher sidecar (composite + dimensions) | `Faber.Eval`, `Faber.Sidecar`, `python/faber_eval` |
| M5 | Self-improving loop — propose→eval→keep with git ratchet + plateau | `Faber.Loop` (+ `Git`, `Journal`, `Server`, `Supervisor`) |
| M6 | LiveView friction dashboard (Bandit, no build step) | `FaberWeb.DashboardLive` |
| +  | Read-only MCP server (Anubis) — friction/skills as live tools for coding agents | `Faber.MCP.Server`, `Faber.MCP.Tools.*` |
| +  | Cross-agent skill install + provenance-tracked pointer sync (`faber sync`) | `Faber.Install` (`.faber.json` marker) |
| +  | **Second adapter (`faber-python`) — engine proven domain-free** (zero `lib/faber` diffs) | `adapters/faber-python/` + contract v0.2 detection vocab |
| +  | **Cross-agent ingest** — pluggable transcript formats behind one seam: Claude, Codex, Cline, Gemini (+ Qwen Code), OpenCode (SQLite) | `Faber.Ingest.Format.*` (Pi deliberately absent — no transcript spec yet) |
| +  | **Install-feedback outer loop** — did installed skills actually fire, and did friction drop? (`faber feedback`) | `Faber.Feedback` |
| +  | **Proposal consolidation** — cluster near-duplicate proposals (pure), LLM-merge each cluster through the eval gate | `Faber.Consolidate` |

Two adapters ship today: [`faber-elixir`](adapters/faber-elixir/) (the reference, extracted by
reference from the `claude-elixir-phoenix` plugin) and [`faber-python`](adapters/faber-python/)
(hand-curated). The second one is the proof the engine is **domain-free** — it stood up with
zero `lib/faber` diffs, driving Python-flavored detection/generation purely from declarative
pack data (contract v0.2 §4.1).

**New here? Start with the [User Guide](docs/GUIDE.md)** — a step-by-step walkthrough of the
whole workflow (scan → propose → eval → refine → install → sync → feedback), every CLI flag,
the configuration reference, and troubleshooting.

See [`HANDOFF.md`](HANDOFF.md) for the full thesis and architecture rationale,
[`docs/ADAPTER_CONTRACT.md`](docs/ADAPTER_CONTRACT.md) for the adapter pack spec (v0.2), and
[`.claude/research/`](.claude/research/) for the calibration and source-study notes.

**Defaults are local-first & keyless:** the LLM backend defaults to the Claude Code CLI
(`claude -p`, uses your existing auth — no API key); structural eval runs **natively in
Elixir** (no `python3` on the hot path). Opt into the network path with
`config :faber, :llm, Faber.LLM.ReqLLM` + a key, and the Python matcher engine with
`config :faber, :eval_engine, :sidecar`.

Trigger-accuracy eval is implemented as an opt-in **behavioral** dimension (`Eval.score(…,
trigger: true)`): it runs the proposal's `should_trigger`/`should_not_trigger` fixtures through the
configured LLM and folds a **continuous** score — the mean of accuracy/precision/recall — into the
composite (weight `0.10`, so it never sinks a structurally-sound skill; precision uses the sklearn
`zero_division=0` convention so a never-fires skill isn't rewarded). Because routing is stochastic,
`trigger_samples: N` (`mix faber.propose --trigger-samples N`) repeats the eval N times and **pools**
the result into a stable estimate with a reported `σ`. It's off the structural hot path (one LLM call
per fixture per sample), and covered by `eval_trigger_test` plus the live tests.

The self-improving loop can optimize this dimension too: `Faber.Loop.refine(result, adapter,
trigger: true)` scores every candidate as a proposal — always against the **seed proposal's
fixtures, pinned** for the whole run, so a candidate can never game the objective by generating
fixtures its own description trivially routes (mutation-tested). Trigger mode pools
`trigger_samples: 3` by default and accepts `min_improvement:` as a keep-margin above the
routing noise; `seed:` starts the loop from an existing proposal instead of minting a new one;
`trigger_holdout: true` splits the fixtures and reports the final best against a validation half
the loop never optimized (`State.holdout`) — the overfit detector. The loop has a CLI surface
too: **`faber refine`** (`mix faber.refine` in dev) runs scan → seed → reflect-loop with tight
defaults (5 iterations) and `--install` for the final best.

After installing, **`faber feedback`** closes the outer loop: for every Faber-installed skill it
reports whether sessions since install actually used it (`skills_used`) and how friction compares
with vs. without — `:unused` skills are the ones to `faber refine --trigger` or retire.

**Known runtime gaps** (wired + tested with stubs; live use needs the runtime): the GEPA
`optimize` command is implemented as a capability-gated seam — its orchestration (the eval-matcher
metric, budget guardrail, result shaping) is unit-tested and the real subprocess boundary is
covered, but the live `dspy.GEPA` path needs the optional `gepa` extra + a provider key and is
**unvalidated until you opt in to spend** (without them it degrades to `not_implemented`; the
keyless reflective loop covers v1 self-improvement).

## Development

```sh
mix deps.get
mix verify                     # the pre-commit gate: format, compile, credo, dialyzer, test
mix test                       # hermetic — Elixir suite incl. LiveView, no python3 needed
mix test.full                  # also runs @tag :sidecar (needs python3) + :ccrider/:opencode (need sqlite3)
mix faber.scan                 # rank your real ~/.claude sessions by friction
iex -S mix phx.server          # dashboard at http://localhost:4010 (+ Tidewave MCP at /tidewave/mcp)
```

The Python eval sidecar lives in `python/` (stdlib-only; `python3 -m unittest discover -s python/tests`).

**Tidewave** (`only: :dev`) mounts runtime introspection at `/tidewave/mcp` on the dev server —
`project_eval`, `get_logs`, `get_source_location`, `get_docs`. See
[`docs/TIDEWAVE.md`](docs/TIDEWAVE.md) for setup and Faber-specific recipes. It never ships: the
endpoint plug is behind a compile-time guard, so the release has no arbitrary-eval surface.

### MCP server

`faber serve` exposes an MCP server at `http://localhost:<port>/mcp` (localhost-bound, single-user,
no auth). Connect a coding agent with:

```sh
claude mcp add --transport http faber http://localhost:4710/mcp
```

Read-only tools (no opt-in): `faber_search_friction` (ranked friction findings — **aggregates only,
never raw transcript text**), `faber_list_skills`, `faber_get_skill`. One opt-in, side-effecting
tool: `faber_propose_skill` — proposes + gates (and optionally installs) a skill for a ranked
finding; it calls an LLM (spends tokens), so it stays **disabled** unless you set
`config :faber, :mcp_allow_propose, true`. The server starts only under `faber serve` /
`mix phx.server` (never for one-shot CLI commands).

The dashboard's per-row **Propose** button spends tokens too, but is human-initiated, so it
defaults **on** behind a browser confirm (origins are pinned to loopback); disable it outright
with `config :faber, :web_allow_propose, false`.

### Cross-agent ingest

Faber is agent-agnostic: each coding agent's on-disk transcript shape is a small format module
behind one behaviour (`Faber.Ingest.Format`), so the detect/score/propose engine never learns whose
session it's reading. Pick a format with `format:` (or `config :faber, :ingest_format`):

| Format | Agent | Storage | Validation |
|--------|-------|---------|------------|
| `:claude` (default) | Claude Code | `~/.claude/projects/**/*.jsonl` | real |
| `:codex` | OpenAI Codex | `~/.codex/sessions/**/rollout-*.jsonl` | real |
| `:cline` | Cline (VS Code) | `**/saoudrizwan.claude-dev/tasks/*/api_conversation_history.json` | documented shape |
| `:gemini` | Gemini CLI / Qwen Code | `~/.gemini/tmp/*/chats/session-*.json` (Qwen: `~/.qwen/tmp`) | documented shape |
| `:opencode` | OpenCode | `~/.local/share/opencode/opencode.db` (SQLite, via `sqlite3` CLI) | real DB |

```elixir
Faber.Scan.run(format: :opencode)        # rank an agent's sessions by friction
```

Each format canonicalizes its tool names to Faber's vocabulary (`Bash`/`Read`/`Edit`/`Write`/…) so
the same detection signals fire across agents. Adding one is a single module + a `format` alias — no
engine changes. (Pi is deliberately absent rather than guessed: it needs a real transcript spec before a faithful module.)

## License

MIT — see [`LICENSE`](LICENSE).
