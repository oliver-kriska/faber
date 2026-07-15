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

The end-user walkthrough (every command, flag, config key, and the intended workflow) is
[`docs/GUIDE.md`](docs/GUIDE.md) — keep it in sync when CLI flags or config keys change.

## Conventions (HANDOFF §10)

- **Commit per feature / cohesive unit**, conventional-commit style messages.
- **Verify before every commit** (Iron Law #22): run **`mix verify`** (or `make verify`) and confirm
  it passes. It is the whole gate, in order, cheapest-first:

  ```sh
  mix verify        # = format · compile --warnings-as-errors · credo --strict · dialyzer · test
  ```

  It formats in place rather than checking (CI re-checks with `--check-formatted`, so an
  unformatted tree still fails there). Static analysis is configured in
  [`.credo.exs`](.credo.exs) and `mix.exs`'s `dialyzer/0`; both are expected to stay green, so
  fix a finding rather than widen the config. Dialyzer's first run builds a PLT into `_build/plts`
  (a few minutes; cached after). The rare warning that is *correct about deliberate code* goes in
  [`.dialyzer_ignore.exs`](.dialyzer_ignore.exs) **with a reason** — `list_unused_filters: true`
  fails the gate if such an entry outlives the code it was written for.

  `mix test` excludes the `:sidecar`/`:ccrider`/`:opencode`/`:plugin_eval`/`:live`/`:live_api` tags
  so it needs no interpreter, key, or external index. Run **`mix test.full`** (alias for `mix test
  --include sidecar --include ccrider --include opencode`) — which needs `python3` (sidecar) and
  `sqlite3` (the ccrider/OpenCode SQLite readers) — before committing changes that touch the eval
  matchers, the sidecar boundary, or a SQLite-backed ingest format, and in CI, to catch
  native/sidecar drift.

  The other three tags are **environment-bound** — no runner can satisfy them by installing
  tooling — so they each get their own alias and stay out of `test.full` (which is CI's command):
  **`mix test.plugin`** (`:plugin_eval`) runs the adapter's exec-in-place eval against the real
  plugin repo at the adapter's machine-local `metadata.source_repo`, catching drift in that
  scorer's JSON shape that a fake scorer never would; **`mix test.live`** is the keyless
  end-to-end run (real `claude -p`, no key); **`mix test.live.api`** is the paid ReqLLM/Anthropic
  backend (needs `CLAUDE_API` in `.env`).

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

## Generators & eval gates (learned from dogfooding)

- **Eval proxies are renderer guarantees, not prompt wishes.** When the deterministic eval
  (`Faber.Eval.Native`) gates a generated skill, make the **renderer** satisfy each check by
  construction (presence-gate optional sections, guarantee a ≥2-line example block, etc.) — don't
  rely on the LLM happening to comply. Conversely, **never clamp/truncate to force a proxy green**
  when the content is genuinely good (e.g. an over-length but well-structured description): that
  games the metric against its intent. Tighten the renderer (raise the floor) or let the reflective
  loop optimize the content; do not degrade the artifact. See
  `.claude/solutions/2026-06-25-eval-clarity-proposer-renderer-gap.md`.
- **Probe matchers against the *rendered* artifact, not a fixture** — the built-in and
  adapter-template render paths can diverge on exactly these checks.
- **Treat the user's dirs as shared.** Anything that writes into `~/.claude` (skills, `CLAUDE.md`,
  hooks) must track *provenance* for what Faber created and never enumerate-and-claim the whole dir
  (`Faber.Install` uses a `.faber.json` marker; `list_faber_installed/1` is the filtered view, while
  `list_installed/1` stays the generic primitive). See
  `.claude/solutions/2026-06-25-sync-pointer-over-claim-provenance.md`.
- **Validate untrusted declarative packs at the `load/1` boundary; fail closed at runtime.** Adapter
  packs are untrusted input — anything turned into a regex or atom must be validated when the pack
  loads (`Faber.Adapter.validate/1`), not trusted deep in a scan. Guard with `is_binary/1` before
  `Regex.escape/1` (it *raises* on non-binaries) and keep a fail-closed runtime guard
  (`~r/(?!)/` never-match) for an in-memory struct that bypassed validation. And **reproduce a
  flagged crash vector before "fixing" it** — a plausible security finding can be empirically false
  for the actual input shape (e.g. `Regex.escape`'d strings don't fail `Regex.compile`); fix the
  real edge and say so. See
  `.claude/solutions/2026-06-26-elixir-regex-escape-compile-validate-boundary.md`.
- **A behavioral eval dimension must reward continuously, and pool over a stochastic objective.**
  Trigger-accuracy (`Faber.Eval.Trigger`) routes fixtures through a real LLM — a *noisy* classifier
  (same skill scored 0.75 then 1.0 across runs). Two consequences the loop depends on: (1) score it
  as a **continuous** mean of accuracy/precision/recall, not `passed/total` over pass/fail thresholds
  — a step-function pins at 1.0 and leaves the reflective loop no gradient; (2) use precision's
  sklearn `zero_division=0` convention so a never-fires skill isn't handed a vacuous 1.0 that inflates
  its behavioral score (~+0.33, empirically reproduced). Because one call is a single Bernoulli draw,
  optimize a **pooled** estimate (`trigger_samples: N` micro-averages N runs + reports `σ`), never one
  draw — a greedy keep/revert over a single sample banks lucky noise. Behavioral weight stays `0.10`
  so it never sinks a structurally-sound skill. See
  `.claude/research/2026-06-26-dogfood-real-friction-correction-ledger.md`.
