# Deep audit — features, docs accuracy, bugs & suggestions (2026-07-03)

Five-agent parallel audit of the whole repo: docs-vs-code accuracy, ingest+detect,
adapter+propose+eval+sidecar, loop+install+CLI+MCP+web, and a verification runner that
executed every suite. Goal: confirm the docs are correct, confirm the features work, and
inventory bugs/improvements. Code was **not** modified; only confirmed doc drift was fixed
(python/README.md, README.md "Pi stub" phrasing, HANDOFF.md staleness).

## Verification — everything green

| Step | Result |
|---|---|
| `mix format --check-formatted` | PASS |
| `mix compile --warnings-as-errors` | PASS, zero lib warnings |
| `mix test` (hermetic) | 331 passed / 0 failed (11 excluded) — 4.7s |
| `mix test.full` (+sidecar +ccrider +opencode) | 340 passed / 0 failed — 2.8s |
| Python (`python3 -m pytest`, uv absent locally) | 41 passed — 0.2s |
| `mix test.live` (keyless real `claude -p`) | 332 passed / 0 failed — 112.8s |

342 total Elixir tests (tag math consistent across suites) + 41 Python. `test.live.api` not run
(paid). Local env note: **uv not installed** — non-blocking (sidecar is pure stdlib; uv only
matters for reproducible env + the optional `[gepa]` extra). Two harmless dead-`is_list`
warnings in `test/faber/live_propose_test.exs:28` and `live_propose_req_llm_test.exs:46`
(Proposal types `iron_laws` as a list so `is_list/1` is statically true; the `!= []` conjunct
still bites).

## Docs accuracy — verdict

README.md, CLAUDE.md, docs/ADAPTER_CONTRACT.md and both adapter packs' docs were checked
claim-by-claim: **~55 checkable claims CORRECT**, drift was concentrated in two files (both
fixed this session):

- **HANDOFF.md** — was WRONG about Oban (`Faber.Schedule` is deliberately DB-less/Oban-free;
  no oban dep exists), stale about "dashboard (later)" (shipped), stale "Later" milestone list
  (Codex/OpenCode/trigger-eval all shipped), dated build-state snapshot. **Fixed.**
  ⚠️ Open decision: HANDOFF.md is **untracked** — hidden via `.git/info/exclude`, never
  committed — yet tracked docs (CLAUDE.md, README) say "read HANDOFF.md first". A fresh clone
  gets a dangling reference. Either commit it or soften the references.
- **python/README.md** — claimed `score` was an M0 stub returning `not_implemented` (it's fully
  implemented); example showed a response shape (`echo`, `not_implemented`) that never existed;
  the `--input PATH` mechanism (the one the Elixir spine actually uses) was undocumented; test
  command didn't mention the `dev` pytest extra. **Fixed** (example output verified by running
  the real sidecar).
- Minor: README said "Pi still a stub" — Pi is deliberately *absent*, not stubbed. **Fixed.**
  `adapters/faber-elixir/EXTRACTION_PROBE.md` uses `entrypoint` (singular) vs shipped
  `entrypoints:` — left as-is (historical probe doc).

## Bugs found (code — NOT fixed, reported for triage)

Ranked by severity; all verified against the actual code path by the auditing agents.

### Medium

1. **Dashboard `propose` spends LLM tokens with no opt-in gate.**
   `lib/faber_web/live/dashboard_live.ex:48-60` → `do_propose/1` calls `Propose.propose/2`
   (default backend `claude -p` = real token spend). The MCP twin `faber_propose_skill` is
   deliberately gated behind `config :faber, :mcp_allow_propose`
   (`lib/faber/mcp/tools/propose_skill.ex:93`); the web button has no gate, and the LiveView
   moduledoc's no-auth justification ("only triggers a read-only scan") predates the button.
   Aggravated by `check_origin: false` (`config/runtime.exs:41`, `config/dev.exs:8`): a DNS-
   rebinding page can drive propose clicks against `127.0.0.1:4710`. Fix: same flag as MCP (or
   a confirm step) + pin `check_origin` to loopback.

2. **No subprocess timeout anywhere.** `System.cmd/3` call sites have no timeout:
   `lib/faber/llm/claude_cli.ex:52`, `lib/faber/sidecar/system.ex:31`, `lib/faber/loop/git.ex:61`,
   the sqlite readers. Consequences: a hung `claude -p` **permanently wedges the scheduler**
   (`schedule.ex:184` `running: true` never resets; every future tick skipped silently), stalls
   the loop (`loop/server.ex:37` awaits `:infinity`), and hangs one-shot `faber propose`
   (`cli.ex:118-127`). Also `sidecar/system.ex` drops stderr, so a Python traceback is lost
   (`{:sidecar_exit, code, ""}`). Fix: `Task.yield/2` + `Task.shutdown/2` wrapper (or shell
   `timeout`), scheduler max-run guard, fold stderr into the error tuple.

3. **Native eval is missing 3 matchers the Python sidecar has** (native↔python drift).
   `python/faber_eval/matchers.py:368-388` registers `description_keywords`, `content_present`,
   `content_absent`; `lib/faber/eval/matchers.ex:378-397` `run_check/3` doesn't — on native they
   score `{false, "unknown check_type"}` and drag the dimension down. Vendored adapters (which
   *only* run native) using these — matchers.py's docstring invites `description_keywords` —
   get silently mis-scored. Fix: port the three, or neutral-pass unknown types.

4. **Per-check `weight` from a vendored adapter's eval.yaml is dropped by native.**
   `lib/faber/eval.ex:203-211` `build_native_def/1` extracts only `type`+`params`; Python's
   `scorer.py` honors sibling `weight`. A weighted adapter eval is silently flattened to 1.0 on
   the only engine vendored adapters reach. Fix: thread `c["weight"]` through.

### Low-medium / low

5. **Adapter template path traversal.** `lib/faber/adapter.ex:208` `read_templates/1` joins
   manifest `file:` straight into `File.read` — a malicious pack can read
   `../../../../…/.ssh/id_rsa` into the template map (adapters are declared untrusted input).
   Fix: `Path.safe_relative` containment check at load + a `validate/1` problem.

6. **`Claude.normalize/1` crashes on non-map `message`.**
   `lib/faber/ingest/format/claude.ex:71` `message["role"]` raises on a valid-JSON line like
   `{"type":"user","message":42}`; the raise kills the whole session parse (session silently
   vanishes from scan ranking). Every other format guards this; Claude (the oldest) is the
   outlier. Fix: `is_map` guard, like the other formats.

7. **`Detect.context/1` crashes on non-string `message.model`.**
   `lib/faber/detect.ex:471-482`: `String.replace_suffix(123, …)` raises when the session's
   most-frequent model value is non-string (single adversarial assistant line suffices). Same
   blast radius as #6. Fix: filter `&is_binary/1` in `primary_model` or a non-binary
   `context_window` clause.

8. **`eval_set: :full` silently ignored for a vendored adapter with no `dimensions`**
   (e.g. faber-python). `lib/faber/eval.ex` `run_adapter_eval` → `build_native_def(nil)` = `[]`,
   and `[] || native_default(opts)` never falls through (`[]` is truthy) → 6-dim default, no
   accuracy dims, refs unused. Fix: treat empty dims as "use native_default".

9. **`error_index` collapses on shared/nil tool_use ids** (`lib/faber/detect.ex:630-634`) —
   `Map.new` overwrites; nil-id results (Gemini message-level toolCalls, OpenCode patch edits)
   mis-attribute failures in retry-loop detection. Low impact.

10. **ccrider `query!` outside scan's task isolation** (`lib/faber/ingest/source/ccrider.ex:97-116`)
    — a corrupt DB crashes the entire `Scan.run` instead of one row (opencode degrades
    gracefully; ccrider raises). Inconsistent convention.

### Verified non-bugs (checked, don't re-flag)

- No atom-minting anywhere (all decode `keys: :strings`; `Format.cast/1` string-compares;
  `safe_atom/1` falls back on missing atoms).
- Template rendering is injection-safe (sections render before var substitution; `{{…}}` in LLM
  values inserted literally). `escape/1`/`fence_safe/1` block frontmatter/fence forging.
- No Goodhart shim: renderer guarantees (≥2-line usage block, presence-gated sections) are
  raise-the-floor-by-construction, sanctioned.
- OTP supervision clean throughout; provenance (`.faber.json`, `list_faber_installed/1`) used by
  MCP/sync everywhere; skill-name + git-path validation solid; no API-key logging; sidecar temp
  file O_EXCL 0600.
- Privacy: raw transcript text never reaches LLM prompts, SKILL.md output, or MCP results.
  One deliberate caveat: `SearchFriction.summarize/1` returns absolute `cwd`/`file_paths`
  (defensible local-first; would be an info-leak if MCP ever leaves loopback).

## Confirmed design limitation — loop can't optimize behavioral recall

`Faber.Loop.refine/3` (`lib/faber/loop.ex:259-267`) only accepts a `%Scan.Result{}` (no
`%Proposal{}` seed), and its eval path scores a rendered **string**, whose `Eval.score` clause
(`lib/faber/eval.ex:69-76`) never folds the behavioral trigger dimension (only the `%Proposal{}`
clause carries fixtures). So the loop's composite is structural-only; once structural dims max
out the ratchet has no gradient. Partly deliberate (`cli.ex:181-184`: keeps the LLM-judged dim
out so the loop can't game its own generated fixtures) — but it means the recall-lift we did by
hand on enaia's `bugfix-ledger` (0.52→0.72) cannot be done by `Faber.Loop` today. The natural
next feature: accept a `%Proposal{}` seed + score candidates as proposals with pooled
`trigger_samples` (or held-out routing fixtures to dodge fixture-gaming).

## Native↔Python parity (beyond bugs 3-4)

- Rounding convention differs: `Float.round/2` (half-away-from-zero) vs Python banker's
  rounding at 4dp — latent divergence class, rare in practice.
- Python `split_frontmatter` tolerates trailing whitespace on the opening `---`; native doesn't.
- `description_length`: graphemes (Elixir) vs code points (Python) — emoji-boundary only.
- `parity/` is the **friction-signal** oracle, not an eval-matcher oracle; matcher parity rests
  on 2 fixtures in the `:sidecar` test which exercise none of the above. Add a parity fixture
  set covering the D1 matchers, per-check weights, boundaries, unicode.
- `_VAGUE_PHRASE` in `matchers.py:292` is dead code — delete or wire.

## Suggestions (ranked by value)

1. **Relax `description_structure.has_what`** (`^[A-Z][a-z]+\s`): rejects descriptions leading
   with CamelCase/acronym tech terms — "GenServer …", "LiveView …", "OTP …", "N+1 …" all fail.
   This is LLM content the renderer can't fix by construction, and it's exactly the "lead with a
   concrete noun" style the proposer prompt asks for (we hit this ourselves dogfooding:
   "Survive-compaction" failed has_what). Change on **both** engines in lockstep.
2. Loop seed-proposal + behavioral scoring (limitation above).
3. Subprocess timeout wrapper (bug 2) + scheduler max-run guard + a wedge-recovery test.
4. Adversarial-shape ingest fixtures (`message: 42`, `model: 123`) asserting degrade-not-raise;
   a scan-isolation test (one crashing session doesn't sink the scan).
5. Size cap before whole-file reads in Cline/Gemini (`File.stat` guard → `{:error, :too_large}`);
   cap `fingerprint/2` per-message text like `count_corrections` does (500 chars).
6. Decide `priv/skills/*` (5 SKILL.md files shipped but referenced by no code — wire as seed
   skills, move to docs, or drop).
7. Unify the two CLI surfaces: release `faber scan/propose` vs `mix faber.scan/propose` accept
   different flags; `cli.ex:159` `Keyword.take`s `:base`/`:min_messages` that its own parser
   never produces (dead keys).
8. Test-coverage gaps: Mix task wrappers (arg parsing untested), `error_html.ex`,
   `loop/git.ex` error/revert branches, `layouts.ex`.
9. MCP `search_friction`: consider relativizing `cwd`/`file_paths` if the surface could ever
   leave loopback.

## Feature inventory (what the app does today — confirmed working)

- **Ingest**: 5 formats (claude, codex, cline, gemini/qwen, opencode-SQLite) behind
  `Faber.Ingest.Format`; 2 sources (files, ccrider-SQLite); canonical tool vocabulary;
  streaming where the format allows; malformed lines degrade to `{:error, _}`.
- **Detect**: 6 weighted friction signals → sigmoid score; tool profile; fingerprint
  (session type + confidence); opportunity→skill rules; context-pressure (peak window fill);
  adapter-extensible via contract v0.2 §4.1 vocab; fail-closed regex guards.
- **Scan**: bounded `Task.async_stream` fan-out, 60s/session timeout + kill, sidechain dedupe,
  even-spread sampling, rank by raw|rate.
- **Adapter**: declarative untrusted packs validated at `load/1` (name/semver/enums/regex/glob
  compile checks); stack gating via suffix-glob matching; 2 shipped packs (faber-elixir
  reference w/ 26 laws, faber-python w/ 15 laws proving domain-freedom).
- **Propose**: adapter-informed prompt (aggregates only — no raw transcript text/paths),
  structured LLM output, two render paths both satisfying the eval by construction,
  injection-safe templating.
- **Eval** (the moat): native 6-dim structural gate (threshold 0.75), 8-dim `:full`,
  optional behavioral trigger dim (continuous mean acc/prec/recall, pooled samples, σ,
  zero_division=0, weight 0.10), sidecar engine option with exact-parity test.
- **Loop**: propose→eval→keep-strict-winner with git ratchet + JSONL journal under
  DynamicSupervisor; `Optimize.reflect/3` keyless GEPA-style; sidecar `optimize` seam degrades
  keyless.
- **Install/Sync**: provenance-marked installs (`.faber.json`), digest-guarded managed blocks
  in agent context files, never claims user's own skills.
- **Surfaces**: Burrito single binary (`faber scan|propose|serve|sync`), mix tasks, MCP server
  (4 tools, propose opt-in, aggregates-only), LiveView dashboard, inert-by-default scheduler.
- **LLM**: pluggable behaviour — ClaudeCLI keyless default, ReqLLM (paid), Stub; keyless live
  e2e proven by `mix test.live`.

Full agent reports (session-scoped): scratchpad `audit-{docs,ingest,eval,surface,verify}.md`.
