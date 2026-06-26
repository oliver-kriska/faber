# Main-feature test-coverage audit + live-LLM gap closed

**Date:** 2026-06-25
**Trigger:** "we should improve and have fully actually tested main features before nice-to-haves."
Honest audit of what's *actually* tested (real components) vs stubbed vs untested, then close
the biggest gap.

## Coverage map (after this session)

| Feature | State | How it's tested |
|---|---|---|
| Ingest (Claude + Codex) | ✅ real | real transcript fixtures, normalization |
| Detect / Scan | ✅ real | real fixtures, friction/opportunity/ctx scoring |
| Eval (native + sidecar) | ✅ real | exact per-assertion parity, regression-injection, no-egress |
| Adapter / stack-gating | ✅ real | real adapter load, glob→regex matching |
| Install | ✅ real | real tmp writes, name-safety boundary |
| Loop (self-improving) | ✅ real | **real git** (init/commit/revert, asserts file restore + commit count), real eval scoring, supervised Server |
| LLM — ClaudeCLI backend | ✅ real + **live** | fake-binary shell-out/parse + **live `claude -p`** smoke test |
| LLM — ReqLLM backend | ✅ unit | pure `build_call/1` (model/opts resolution) + error passthrough (unknown-provider, no network) |
| LLM — dispatch | ✅ unit | `:llm` override routing + pop, fallback to configured impl |
| CLI | ✅ real | parse all cmds, scan, propose (happy/mismatch/force/**install**), serve, help/version |

## The gap that was closed: the real model had never run

Every propose/loop test stubbed the LLM (`Faber.LLM.Stub`). So the headline feature — mine a
session → a **real model** drafts a stack-aware skill → gate → install — had never actually
executed. No API keys are set in this env, **but the `claude` CLI is on PATH**, and the default
backend is `Faber.LLM.ClaudeCLI` (`config/config.exs`), which shells out to `claude -p`
(`--output-format json`, schema rendered into an appended system prompt). So the core is fully
runnable **keyless**, on the Claude Code subscription.

**Proven (real run, sonnet):** from the Elixir fixture's retry-loop friction it drafted
`fix-loop-guard` — routed to the adapter's *Elixir* playbooks (`investigate-bug`,
`ecto-constraint-violation`, `call-tracing`) and cited its LiveView authorization Iron Law (both
from the adapter, not generic), cleared the native gate at **composite 0.8167 ≥ 0.75**, and
installed. Round-trip ~70s.

### What landed (commits)
- `86d6e77` — `test/faber/live_propose_test.exs`: `@moduletag :live` + `timeout: 240_000`. Scan →
  propose(`claude -p`) → native eval → install. Asserts **structure** not content (model is
  nondeterministic) with a 0.6 composite floor. Excluded from `mix test` AND `mix test.full`; run
  with the new **`mix test.live`** alias (`--include live`). Verified green (72.8s).
- `98d6cb5` — `Faber.LLM` dispatch + `Faber.LLM.ReqLLM` tests. Refactored ReqLLM to expose the pure
  `build_call/1` (model precedence opts→config→default; only whitelisted Req opts forwarded, engine
  plumbing dropped). Error branch covered via `model: "bogusprovider:nope"` →
  `{:error, :unknown_provider}` (synchronous, no HTTP).
- `0427a42` — CLI `propose --install` execution path (writes SKILL.md into a tmp `:skills_dir`).

## Known minor item (NOT a correctness bug)
`Faber.LLM.ClaudeCLI` doesn't close the child's stdin, so `claude -p` logs
`no stdin data received in 3s, proceeding without it` and waits 3s before generating (~3s of the
~70s round trip). It's stderr-only (`stderr_to_stdout: false`), never pollutes the parsed stdout,
and doesn't affect tests. Fixing it cleanly needs `sh -c "$BIN" … < /dev/null` with values passed
via env (injection-safe) + updating the missing-bin error path — deferred as a latency nicety per
the "features before nice-to-haves" steer.

## Edges now closed (update — API key provided 2026-06-25)
- `ReqLLM.generate_object` **success** mapping → `ReqLLM.Response.object/1` is now covered by a
  live API test (`test/faber/live_propose_req_llm_test.exs`, `@moduletag :live_api`, commit
  `6b6fa25`). It drives scan → propose(ReqLLM) → native eval → install against the real Anthropic
  API. Tagged separately from `:live` (keyless) because it costs money + needs a key; run with
  `set -a; . ./.env; set +a && mix test.live.api`. The test maps `CLAUDE_API` → `ANTHROPIC_API_KEY`
  and **skips cleanly (no failure) when no key is set**. Verified green (~22s, ~$0.02/run).
- **Security fix:** `.env` was not gitignored — added `.env`/`.env.*` to `.gitignore` (commit
  `9178fc8`) so the local `CLAUDE_API` key can never be committed. The file was never tracked.

So BOTH LLM backends are now live-tested end to end: ClaudeCLI (keyless, `mix test.live`) and
ReqLLM (API, `mix test.live.api`). No irreducible untested LLM edge remains.

## Schedule + Optimize firmed up (commit 973d9fb)
- **Schedule** — the two documented guarantees are now tested: **no-overlap** (a `:tick` or
  `run_now` while a run is in flight is skipped/ignored — forced the in-flight flag with
  `:sys.replace_state`, no real job/timing needed) and **crash isolation** (async_nolink: a
  hard-crashing job → `:DOWN` → recorded `{:job_crashed, _}`, scheduler survives; a raising job →
  caught → clean error summary). Both driven by LLM doubles that crash *inside* the scheduler's
  Task. `status` now asserted to expose `last_summary` + `every_ms`.
- **Optimize** — `run/2`'s remaining sidecar branches covered: `status:error` (with message + the
  `:sidecar_error` fallback), the `unexpected_response` wrap, and `:budget` passthrough.
  `reflect/3` was already covered in `loop_test.exs`.

## Coverage status: complete for the core
Every main feature is now tested with real components, both LLM backends are live-tested, and the
scheduler's reliability guarantees + optimizer error paths are covered. Hermetic suite: 210 passed
/ 6 excluded; `mix test.full` 214 / 2. No known untested behavior remains in the core pipeline.
