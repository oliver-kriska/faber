# CLAUDE.md — Faber

Project instructions for AI agents and humans working in this repo.

## What this is

**Faber** is a local-first, cross-agent, stack-aware improvement engine for AI coding
agents: it mines real coding-agent sessions for friction, proposes skills, and gates them
through a stack-specific **adapter** + an **eval** step, with an optional self-improving
loop.

**Read [`HANDOFF.md`](HANDOFF.md) first** — it is the cold-start context: full product
thesis, the moat, the competitive landscape, the architecture decision (Elixir/OTP spine
+ Python eval sidecar), the adapter contract, source material to extract from, and the
milestones (M0–M6). Everything here assumes it.

## Architecture at a glance

- **Elixir/OTP spine** (this app) — `lib/faber/` contexts map onto the pipeline:
  `Faber.Ingest` → `Faber.Detect` → `Faber.Adapter` → `Faber.Eval` → `Faber.Loop`.
- **Python eval sidecar** (`python/`, uv-managed) — GEPA/DSPy optimizer + eval matchers,
  reached via a JSON-in/JSON-out subprocess boundary (`python -m faber_eval`) for v1.
- **Adapters** (`adapters/<name>/`) — declarative packs (yaml + markdown + templates);
  the engine stays domain-free. Spec: [`docs/ADAPTER_CONTRACT.md`](docs/ADAPTER_CONTRACT.md).
  Reference adapter: `adapters/faber-elixir/`.

## Conventions (HANDOFF §10)

- **Commit per feature / cohesive unit**, conventional-commit style messages.
- **Verify before every commit** (Iron Law #22): run, in order, and confirm all pass —

  ```sh
  mix format
  mix compile --warnings-as-errors
  mix test          # hermetic — no python3 needed
  ```

  `mix test` excludes the `:sidecar`-tagged native↔Python parity tests so it needs no
  interpreter. Run **`mix test.full`** (alias for `mix test --include sidecar`) — which needs
  `python3` — before committing changes that touch the eval matchers or the sidecar boundary,
  and in CI, to catch native/sidecar drift.

- **NEVER push to a remote** until explicitly told. The `origin/main` ref shows `[gone]` —
  it is stale; ignore it. Do not create PRs.
- **Co-author trailer** on every commit:

  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  ```

## Elixir Iron Laws apply

The Elixir/Phoenix Iron Laws apply to all Elixir code here (OTP supervision; no bare
`start_link` outside a supervision tree; verify before claiming done; etc.). The
canonical list lives in the reference plugin's `CLAUDE.md`
(`/Users/oliverkriska/Projects/elixir-live-claude-engineer`), which is also Faber's
reference adapter source.

## Boundaries

- **Do not modify the plugin repo** (`elixir-live-claude-engineer`). Faber *reads* it to
  assemble the `faber-elixir` adapter; the extraction premise is that this needs **zero
  diffs** to the plugin. If something seems to require a plugin edit, that's a finding to
  report, not a change to make.
- The Python sidecar boundary is **JSON over stdin/stdout** for v1. Keep the contract
  stable; embedded CPython (Pythonx) is a later evaluation, not a v1 dependency.
