# Plan — Faber deferred features (ordered easiest → hardest)

**Date:** 2026-06-25
**Context:** The core pipeline is fully tested (both LLM backends live-tested, scheduler +
optimizer error paths covered). These are the four deliberately-deferred items, now planned and
ordered by implementation difficulty so they can be picked off in sequence.

> **STATUS (2026-06-25) — all four implemented.**
> - **#1 stdin fix** — DONE (`06248b5`). `claude -p` runs with stdin from `/dev/null`; the 3s wait is gone.
> - **#2 managed-block install** — DONE (`ed5ee7c`). `faber sync [--target a,b] [--check] [--force]`; digest-guarded, idempotent, traversal-safe; 20 tests.
> - **#3 MCP server** — DONE (`2f5020e`). `anubis_mcp ~> 1.6`; 3 read-only tools; localhost; started only under `serve`; privacy + no-egress + traversal + boot tests; **verified end-to-end over real HTTP**.
> - **#4 GEPA optimizer** — SCAFFOLDED (`1b97fe2`). Orchestration (metric, budget, gate, result) implemented + unit-tested; optional `gepa` extra; real-subprocess `:sidecar` test (free). **Still open** (deliberately, post-v1, needs opt-in spend): validate the live `dspy.GEPA` path, and the GEPA-vs-reflective cost/benefit comparison.

| # | Feature | Effort | New deps | Risk | One-line |
|---|---------|--------|----------|------|----------|
| 1 | `claude -p` stdin latency fix | **XS** (~30 min) | none | low | kill the 3s `no stdin data received` wait |
| 2 | Managed-block cross-agent install | **M** (~0.5 day) | none | low | idempotently write skills/pointers into each agent's location |
| 3 | MCP server (hermes/Anubis, enaia-inspired) | **L** (~1–2 days) | `anubis_mcp` (Hermes) | med | expose mined skills/friction as read-only MCP tools |
| 4 | GEPA heavy optimizer (dspy sidecar) | **XL** (~2–3+ days) | `dspy` (Python, optional) | high | wire `Optimize.run/2`'s GEPA seam; post-v1 |

Sequencing rationale: 1 is a one-file fix; 2 is pure Elixir file I/O, no deps; 3 adds a dependency
+ Phoenix transport + session lifecycle; 4 breaks the stdlib-only sidecar contract, needs a key +
dspy, and is explicitly post-v1 per the keyless-evolution decision.

---

## 1. Fix `claude -p` stdin latency (XS)

**Problem.** `Faber.LLM.ClaudeCLI.generate_object/3` calls `System.cmd(bin, args, …)`, which leaves
the child's stdin open. `claude -p` then waits 3s logging `no stdin data received in 3s, proceeding
without it` before generating — ~3s wasted on every keyless propose. Stderr-only and harmless, but
it's the headline keyless path.

**Design.** Run `claude` with stdin redirected from `/dev/null`. `System.cmd/3` has no stdin
option, so wrap in a shell and pass dynamic values via `env:` (so the prompt/system never go through
shell word-splitting — injection-safe):

```elixir
script = ~s(exec "$FB_BIN" -p "$FB_PROMPT" --output-format json) <>
         ~s( ${FB_SYS:+--append-system-prompt "$FB_SYS"} ${FB_MODEL:+--model "$FB_MODEL"} < /dev/null)
env = [{"FB_BIN", bin}, {"FB_PROMPT", to_string(prompt)}, {"FB_SYS", system}, {"FB_MODEL", model || ""}]
System.cmd("sh", ["-c", script], env: env, stderr_to_stdout: false)
```

**Watch-out (preserve error semantics).** Today a missing binary surfaces as
`{:error, {:claude_cli_unavailable, _}}` via the `rescue ErlangError`. Under `sh -c`, a missing bin
becomes `sh: exit 127`, changing the error shape. Preserve it by pre-checking:
`if System.find_executable(bin) == nil -> {:error, {:claude_cli_unavailable, bin}}`. **Verify
`System.find_executable/1` resolves an *absolute* path** (the fake-binary test passes an absolute
script path); if it only searches `$PATH`, use `File.exists?/1` + executable-bit check instead.

**Files:** `lib/faber/llm/claude_cli.ex`; `test/faber/llm_claude_cli_test.exs` (missing-bin test may
need its expectation re-confirmed).

**Steps**
- [x] Pre-check bin existence → `:claude_cli_unavailable` (keep the tuple shape).
- [x] Switch to `sh -c … < /dev/null` with env-passed values.
- [x] Re-run the fake-binary test (absolute-path bin) + missing-bin test; both green.
- [x] Manually confirm the 3s warning is gone (one `claude -p` run; subscription, free).

**Tests:** existing `generate_object/3` fake-binary + missing-bin tests; optionally assert no `< 3s`
stall isn't worth a flaky timing test — manual confirm suffices.

**Risk:** low. Only touches one I/O function; the parsing helpers are unchanged.

---

## 2. Managed-block cross-agent install (M)

**Goal.** Install a proposed skill so *any* agent actually loads it — not just write
`<skills_dir>/<name>/SKILL.md` (Claude-only). Two sub-capabilities:
  1. **Per-agent skill dirs** — write the skill to each target agent's expected location
     (Claude `~/.claude/skills/<name>/SKILL.md`, Codex/AGENTS, Cursor, etc.).
  2. **Managed-block pointers** — when an agent loads context from a *shared* file
     (`CLAUDE.md` / `AGENTS.md` / `.cursor/rules`), inject a small, digest-guarded, idempotent
     "managed block" that points at the installed skills, updatable/removable without clobbering
     user content. (Lore §4b — managed-block injection.)

**Design (inspired by Lore + dotfile managers).**
- A delimited block: `<!-- FABER:BEGIN (digest) --> … <!-- FABER:END -->`. Re-install replaces the
  block in place; the digest lets `--check` detect drift; absence of the block ⇒ append.
- `Faber.Install.ManagedBlock` (new) — pure functions: `upsert(content, block) :: new_content`,
  `extract(content) :: {:ok, block} | :none`, `digest(block)`. Pure ⇒ fully unit-testable, no I/O.
- `Faber.Install` gains `install_pointer(target_file, skills, opts)` that reads → `upsert` → writes,
  and a `--check` mode returning `:in_sync | {:drift, diff}` (never writes).
- **Targets are declarative**, mirroring the adapter philosophy: a small registry mapping an agent
  id → `{skills_dir, shared_context_file}` so the engine stays agent-agnostic. Start with `claude`
  + `codex`; the ingest layer already knows both formats.
- **Safety:** never write outside the managed block; back up nothing (block is self-delimiting);
  refuse to write if the existing block's digest doesn't match AND `--force` not set (don't stomp
  manual edits inside the block).

**Files:** `lib/faber/install/managed_block.ex` (new, pure); extend `lib/faber/install.ex`; CLI flag
`--target <agent>` / `--pointer` in `lib/faber/cli.ex`; `test/faber/install_managed_block_test.exs`.

**Steps**
- [x] `ManagedBlock` pure module: begin/end markers, digest, `upsert/extract`. Unit test first.
- [x] `Install.install_pointer/3` (read→upsert→write) + `:check` mode.
- [x] Declarative agent-target registry (claude, codex).
- [x] CLI wiring: `faber sync --target claude,codex` / `--check` (+ provenance marker so a shared
  skills dir isn't over-claimed — `list_faber_installed/1`, post-v1 dogfood fix).
- [x] Tests: idempotent re-upsert (byte-stable), drift detection, append-when-absent, never touch
  text outside the block, `--check` is read-only (no-egress/no-write assertion).

**Tests:** pure `upsert/extract/digest` round-trips; install into a tmp shared file twice → identical
bytes; manual edit inside block + re-install without `--force` → refused; `--check` reports drift.

**Risk:** low–med. Pure core keeps it testable; main hazard is clobbering user files — mitigated by
the digest guard + block delimiters + a no-write `--check`.

---

## 3. MCP server — expose Faber to coding agents (L)

**Goal.** Serve Faber's mined skills + friction findings as **read-only MCP tools** so a coding
agent (Claude Code, etc.) can query them live. (Lore §4a / takeaway #2.)

**Prior art — enaia (`hermes_mcp` / Anubis).** enaia runs `Hermes.Server` over **streamable HTTP**
at `/mcp/*`, with `Enaia.MCP.UserTool` behaviour (`call/3` + `to_reply/2`), a registry/session-
supervisor adapter, Horde for clustering, and OAuth 2.1. **Faber is local-first, single-node,
single-user, localhost-bound** → drop OAuth, Horde, clustering, multi-tenant auth. Keep only the
`Hermes.Server` + tool-module + thin-adapter pattern.

**Library.** enaia pinned `hermes_mcp` v0.14.1 (neilberkman fork). The project was **renamed Hermes
→ Anubis** (`anubis_mcp`). **Research step:** confirm the current maintained package/version
(`anubis_mcp` vs `hermes_mcp`) and whether the upstream release suffices (enaia needed a fork for
OAuth/cluster features Faber won't use, so upstream likely fine). KB: `qmd query "hermes mcp anubis
elixir version"`.

**Design.**
- **Transport:** streamable HTTP mounted in `FaberWeb.Router` at `/mcp` (Faber already runs the
  endpoint under `faber serve`). Agents connect via `claude mcp add --transport http
  http://localhost:<port>/mcp`. (Optional later: stdio transport for direct spawn.)
- **No auth, localhost only.** Single-user local tool. **Security note:** ensure the endpoint binds
  `127.0.0.1`, not `0.0.0.0`; if it ever binds publicly, this becomes an unauthenticated data
  surface — gate or warn.
- **Supervision:** add the Hermes server to the tree, started **only under `serve`** (mirror
  `web_children/1` in `application.ex`) so one-shot CLI commands never start it. Single server ⇒ the
  enaia per-module session-supervisor-name collision (`:already_started`) does **not** apply — but
  if a 2nd server is ever added, make session-supervisor names unique per module (`Module.concat`).
- **Tools (thin adapters over existing contexts — engine stays source of truth, like the CLI):**
  - `faber_search_friction` → `Scan.run` → ranked findings. **Returns aggregates only**
    (`Scan.Result`: scores, signals, file_paths, cwd) — **never raw transcript text** (privacy
    boundary, same as the LLM path).
  - `faber_list_skills` → installed skills (name + description) from the skills dir.
  - `faber_get_skill` → a skill's `SKILL.md` by name (name validated as a safe path segment, reuse
    `Install`'s `@name_re`).
  - `faber_propose_skill` (phase 2) → `Propose` + `Eval.gate` for a chosen finding. **Side-effecting
    + costs tokens** — ship read-only tools first; add propose behind an explicit opt-in.
  - Lore §4a hygiene: engineered tool descriptions, per-tool output **char budget**, **structured
    errors**, stateless handlers.
- **Bake in the enaia session gotcha:** a stale/unknown `Mcp-Session-Id` must not silently become a
  fresh uninitialized session (the 404 decision) — use the library's current handling; add a test
  for re-init.

**Files:** `mix.exs` (+`anubis_mcp`); `lib/faber/mcp/server.ex`; `lib/faber/mcp/tools/*.ex`;
`lib/faber_web/router.ex` (mount); `lib/faber/application.ex` (supervise under `serve`);
`test/faber/mcp/*_test.exs`.

**Steps**
- [x] Research/confirm `anubis_mcp` package + version; add dep.
- [x] `Faber.MCP.Server` (Anubis.Server) + register read-only tools.
- [x] Implement `faber_search_friction`, `faber_list_skills`, `faber_get_skill` as thin wrappers.
- [x] Mount at `/mcp`; supervise under `serve` only; bind localhost.
- [x] Tests: per-tool handler in isolation (params → structured reply); **privacy test** (tool
  output contains only aggregates, no raw transcript substrings); **no-egress** for read-only tools
  (extend the existing BEAM-trace test to the MCP path); session re-init test.
- [ ] (Phase 2 — not built) `faber_propose_skill` behind opt-in; gate + cost note.
- [x] Docs: `claude mcp add` one-liner in README/HANDOFF.

**Tests:** Hermes test helpers for tool invocation; the privacy + no-egress isolation tests are the
moat-defining ones (Lore: "isolation test").

**Risk:** med. New dependency + transport/session semantics are the unknowns; the enaia precedent
(and its documented gotchas) de-risks both. Keeping it read-only + localhost removes the auth
attack surface entirely.

---

## 4. GEPA heavy optimizer — wire the dspy sidecar (XL, post-v1)

**Goal.** Make `Faber.Optimize.run/2`'s GEPA seam real: the Python sidecar's `optimize` command
currently returns `not_implemented`; implement it with `dspy.GEPA` (Pareto-selection prompt
optimization) so a skill can be optimized by the heavy engine when a key + dspy are available.

**Why last / post-v1.** Per `.claude/research/2026-06-23-gepa-reflective-loop-decision.md`, v1 ships
the **keyless reflective loop** (`Optimize.reflect/3`) and explicitly defers GEPA. GEPA **breaks the
stdlib-only sidecar contract** (needs `dspy` + a provider key), so it must be an **optional extra**,
gated, degrading to `not_implemented` when absent (the current behavior).

**Design.**
- Python-side only — the Elixir seam (`run/2`, request/response shape, `:sidecar` injection) already
  exists and is tested.
- Add `dspy` as an **optional uv dependency group** (`[project.optional-dependencies] gepa = [...]`);
  the base sidecar stays stdlib-only and hermetic.
- Implement `optimize` in the sidecar: input `{skill_md, eval_def, budget}` → build a dspy program
  whose metric is the **existing eval matchers** (reuse `faber_eval.scorer`) → run `dspy.GEPA` with
  the budget (rollouts) → return `{status: "ok", result: {best_skill_md, score, history}}`.
- Provider: use the now-available `CLAUDE_API` (`ANTHROPIC_API_KEY`) via dspy's LM config.
- Selection: GEPA's Pareto frontier over the eval dimensions (the "named factors") — aligns with the
  reflective loop's credit-assignment but heavier/global.

**Files:** `python/pyproject.toml` (optional `gepa` extra); `python/faber_eval/optimize.py` (new);
`python/faber_eval/__main__.py` (route `optimize`); Python tests; Elixir `optimize_test.exs`
(already covers the seam — add a `:live_api`-gated integration).

**Steps**
- [x] Decide cost guardrails (budget/rollouts cap; this spends real tokens). — `clamp_rollouts` default 8 / max 40.
- [x] Optional `gepa` extra; `optimize` returns `not_implemented` unless dspy + key present.
- [x] Python unit tests (mock LM) for the orchestration (metric/budget/gate/shape).
- [~] Implement the live `dspy.GEPA` program with the eval matchers as the metric. **(DEFERRED — gated by the decision below)**
- [~] Elixir: `:live_api` integration through `Optimize.run/2`. **(DEFERRED — gated by the decision below)**
- [x] Compare GEPA vs reflective on a fixture: is the extra cost worth it? (decision gate) — **RESOLVED 2026-06-26: DEFER GEPA.** Regime mismatch (Faber's eval is deterministic + single-document; GEPA's edge is in the stochastic / multi-objective / dataset regime, per the enaia precedent), the keyless reflective loop already carries the credit-assignment mechanism that matters, and live GEPA breaks the keyless boundary + spends tokens for uncertain headroom. Cheap pre-req before any build: measure the reflective loop's ceiling on real skills. Falsifiable revisit conditions in `.claude/research/2026-06-23-gepa-reflective-loop-decision.md`.

**Tests:** Python optimizer with a mocked LM (deterministic); gated live run; Elixir parity for the
request/response.

**Risk:** high. New heavy Python dep, real token cost, contract change, and uncertain payoff over the
keyless reflective loop. **Recommend only if reflective evolution proves insufficient in practice.**

---

## Suggested order of attack
1 → 2 → 3 → (evaluate need) → 4. Items 1–3 are all v1-appropriate and independently shippable; 4 is a
post-v1 research bet gated on whether the keyless loop is good enough.
