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

**M0 (scaffold) → start of M1 (adapter contract).** The Elixir spine, the Python sidecar
stub, the `faber-elixir` adapter skeleton, and the adapter contract spec are in place.
See [`HANDOFF.md`](HANDOFF.md) for the full thesis, architecture rationale, and
milestones, and [`docs/ADAPTER_CONTRACT.md`](docs/ADAPTER_CONTRACT.md) for the adapter
pack specification.

## Development

```sh
mix deps.get
mix test
mix compile --warnings-as-errors
```

The Python sidecar lives in `python/` (uv-managed). See `python/README.md`.

## License

MIT — see [`LICENSE`](LICENSE).
