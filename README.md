# Faber

**A local-first, cross-agent, stack-aware improvement engine for AI coding agents.**

Faber mines your *real* coding-agent sessions (Claude Code first; Codex / OpenCode / Pi
later) for repetitive, painful workflows, then generates **skills** that automate them —
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

See [`HANDOFF.md`](HANDOFF.md) for the full thesis and architecture rationale,
[`docs/ADAPTER_CONTRACT.md`](docs/ADAPTER_CONTRACT.md) for the adapter pack spec, and
[`.claude/research/`](.claude/research/) for the calibration and source-study notes.

**Known external-runtime gaps** (code is wired and tested with stubs; live use needs the
runtime): a live LLM call needs a provider key (e.g. `ANTHROPIC_API_KEY`); the GEPA
`optimize` command is a documented stub (needs `dspy` + a key — the M5 loop covers v1
self-improvement instead); the eval sidecar runs on plain `python3` (no `uv` required).

## Development

```sh
mix deps.get
mix test                       # 60 tests (incl. LiveView + a real-python sidecar round-trip)
mix compile --warnings-as-errors
mix faber.scan                 # rank your real ~/.claude sessions by friction
iex -S mix                     # dashboard at http://localhost:4000 (mix phx.server style boot)
```

The Python eval sidecar lives in `python/` (stdlib-only; `python3 -m unittest discover -s python/tests`).

## License

MIT — see [`LICENSE`](LICENSE).
