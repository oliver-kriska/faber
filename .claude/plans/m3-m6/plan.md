# Plan: M3–M6 — proposer, eval gate, loop, dashboard

Finish Faber end to end: the skill **proposer** (M3), the **eval gate** via the Python sidecar
(M4), the self-improving **autoresearch loop** (M5), and the **LiveView dashboard** (M6). Faithful
ports of the plugin's `lab/eval`, `lab/autoresearch`, and skill conventions — see
`.claude/research/2026-06-18-plugin-eval-autoresearch-skill-format.md`. Engine stays domain-free;
all stack knowledge comes through the adapter.

Verify per task: `mix compile --warnings-as-errors`. Per phase: `mix test <affected>` (+ python
unittest for sidecar). Final gate: full `mix test` + sidecar tests. Commit per phase. NEVER push.

Decisions already taken (per "follow your recommendation"): ReqLLM behind a `Faber.LLM` behaviour
with a stub for tests; sidecar boundary = `python3 -m faber_eval <cmd> --input <tmp.json>` →
stdout JSON (no exile/NIF dep; stdin remains canonical); loop = deterministic keep/revert/plateau
(GEPA deferred); M6 = no-build LiveView (vendored UMD JS) on Bandit, no Ecto.

## Phase 1 — M3 Skill proposer ✅
- [x] [P1-T1] `:req_llm` 1.16.0 added (compiles on OTP 29); `Faber.LLM` behaviour + `Faber.LLM.Stub` + `Faber.LLM.ReqLLM` (generate_object → Response.object); config/ with test→Stub
- [x] [P1-T2] `Faber.Proposal` struct + `Faber.Propose` — pure `build_prompt/2` (system: skill rules + adapter laws/playbooks; user: friction signals/fingerprint/missed), NimbleOptions schema, `propose/3`
- [x] [P1-T3] `render_skill_md/1` → frontmatter + Iron Laws (numbered ≥3) + Usage + Examples (fenced ≥2 lines) + References
- [x] [P1-T4] 5 proposer tests pass — prompt content, propose via Stub, custom stub_response, LLM-error passthrough, rendered sections

## Phase 2 — M4 Eval gate (Python sidecar + Elixir boundary) ✅
- [x] [P2-T1] 16 matchers in `matchers.py` (section/frontmatter/desc/iron-laws/dangerous/examples/density/specificity) — pure stdlib, hand-rolled frontmatter (no PyYAML dep); generic defaults, adapter supplies stack params
- [x] [P2-T2] `scorer.py` — weighted dimensions + composite; standalone DEFAULT_EVAL (drops accuracy/behavioral that need a tree/cache); `score` wired; `optimize` documented stub (GEPA needs dspy+key)
- [x] [P2-T3] 16 python tests pass under `python3 -m unittest` (good skill ≥0.9, bad <0.5, custom eval_def, dangerous-pattern section exclusion, --input file, round-trip)
- [x] [P2-T4] `Faber.Sidecar` behaviour + `System` (System.cmd + temp `--input`, cd python/, graceful unavailable) + `Stub`; `Faber.Eval.score/2` + `gate/2` (configurable threshold, accepts Proposal or md)
- [x] [P2-T5] 7 eval tests pass — stubbed sidecar (pass/fail/threshold/error/Proposal) + real-python `@tag :sidecar` end-to-end (composite > 0.5, dimensions present)

## Phase 3 — M5 Autoresearch loop
- [ ] [P3-T1] `Faber.Loop.run/1` pure driver — propose→eval→keep/revert, prev_best, plateau (patience 50 / per-skill 10), target 0.95, max_iterations; inject propose_fn/eval_fn
- [ ] [P3-T2] `Faber.Loop.Git` (scoped add/commit on keep, checkout on revert) + `Faber.Loop.Journal` (JSONL append, schema parity)
- [ ] [P3-T3] `Faber.Loop.Server` GenServer + `Faber.Loop.Supervisor` (DynamicSupervisor) in the app tree (on-demand, not at boot)
- [ ] [P3-T4] Loop tests — deterministic improve-then-plateau keeps winners & stops; temp git repo asserts commit-on-keep / checkout-on-revert; journal schema

## Phase 4 — M6 LiveView dashboard
- [ ] [P4-T1] Add phoenix/phoenix_live_view/phoenix_html/bandit/plug deps; `config/` (config.exs, dev.exs, test.exs, runtime.exs); endpoint secret/salt
- [ ] [P4-T2] `FaberWeb` (endpoint, router, components/layouts), Plug.Static + vendored UMD JS, supervision tree wiring
- [ ] [P4-T3] `FaberWeb.DashboardLive` — mount → Faber.Scan.run, ranked table + summary stats, rescan event
- [ ] [P4-T4] `Phoenix.LiveViewTest` — dashboard mounts and renders the ranked table (no browser)

## Phase 5 — Final gate
- [ ] [P5-T1] Full `mix test` + python sidecar tests; boot smoke (`mix run` / endpoint starts); update HANDOFF status note; final commit; summarize blockers (live LLM key, dspy/GEPA, uv) honestly
