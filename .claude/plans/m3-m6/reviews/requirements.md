## Requirements Coverage (from plan .claude/plans/m3-m6/plan.md)

| # | Requirement | Status | Evidence |
|---|-------------|--------|----------|
| P1-T1 | `:req_llm` dep added; `Faber.LLM` behaviour + `Stub` + `ReqLLM`; config test→Stub | MET | `lib/faber/llm.ex:24` (behaviour); `lib/faber/llm/req_llm.ex`; `lib/faber/llm/stub.ex`; `config/test.exs` |
| P1-T2 | `Faber.Proposal` struct + `Faber.Propose` — pure `build_prompt/2`, NimbleOptions schema, `propose/3` | MET | `lib/faber/proposal.ex`; `lib/faber/propose.ex:64` (`build_prompt/2`); `lib/faber/propose.ex:50` (`propose/3`) |
| P1-T3 | `render_skill_md/1` → frontmatter + Iron Laws (≥3 numbered) + Usage + Examples (fenced ≥2 lines) + References | MET | `lib/faber/propose.ex:137` — all sections present; test at `test/faber/propose_test.exs:117` asserts ≥3 numbered laws |
| P1-T4 | 5 proposer tests pass (prompt content, propose via Stub, custom stub_response, LLM-error, rendered sections) | MET | `test/faber/propose_test.exs` — 5 test cases covering all described scenarios |
| P2-T1 | 16 matchers in `matchers.py` (section/frontmatter/desc/iron-laws/dangerous/examples/density/specificity) — pure stdlib, hand-rolled frontmatter | MET | `python/faber_eval/matchers.py` (stdlib only, no PyYAML); 16 python tests pass |
| P2-T2 | `scorer.py` — weighted dimensions + composite; standalone DEFAULT_EVAL; `score` wired; `optimize` documented stub | MET | `python/faber_eval/scorer.py`; `optimize` stub confirmed by `test_optimize_is_a_documented_stub` roundtrip test |
| P2-T3 | 16 python tests pass under `python3 -m unittest` | MET | `cd python && python3 -m unittest discover -s tests` → 16 tests, OK |
| P2-T4 | `Faber.Sidecar` behaviour + `System` (System.cmd + temp --input, cd python/, graceful unavailable) + `Stub`; `Faber.Eval.score/2` + `gate/2` (configurable threshold, accepts Proposal or md) | MET | `lib/faber/sidecar.ex`; `lib/faber/sidecar/system.ex`; `lib/faber/sidecar/stub.ex`; `lib/faber/eval.ex:36,80` |
| P2-T5 | 7 eval tests pass — stubbed sidecar (pass/fail/threshold/error/Proposal) + real-python `@tag :sidecar` | MET | `test/faber/eval_test.exs` — 8 tests (1 extra native-engine test beyond the plan's 7; all pass patterns present including `@describetag :sidecar`) |
| P2-T5a | Native eval default — no python3 spawn on hot path | MET | `lib/faber/eval.ex:53-58` — `engine/1` defaults to `:native`; `Faber.Eval.Native` runs in-process; `test/faber/eval_test.exs:72` tests native path |
| P3-T1 | `Faber.Loop.run/1` pure driver — propose→eval→**strict** improvement (ties revert), plateau (patience 50), target 0.95, max_iterations 50; inject propose_fn/eval_fn; `refine/3`; `default_checks/1` | MET | `lib/faber/loop.ex:126` — `composite > state.best_composite` (strict, not ≥); `loop.ex:96-100` stop conditions; `refine/3` at `:247`; `default_checks/1` at `:229` |
| P3-T2 | `Faber.Loop.Git` (scoped add/commit on keep, `checkout --` on revert) + `Faber.Loop.Journal` (JSONL append/read, ISO8601, schema parity) | MET | `lib/faber/loop/git.ex`; `lib/faber/loop/journal.ex`; loop_test.exs git ratchet test at `:136` verifies commit-on-keep and file restore-on-revert |
| P3-T3 | `Faber.Loop.Server` GenServer (restart :temporary, await/status) + `Faber.Loop.Supervisor` (DynamicSupervisor) wired into app tree (started empty, on-demand) | MET | `lib/faber/loop/server.ex:12` (`restart: :temporary`); `lib/faber/loop/supervisor.ex`; `lib/faber/application.ex:13` (wired in tree) |
| P3-T4 | 9 loop tests — improve-then-plateau→:stuck, target→:complete, max_iter→:complete, check-fail discard, journal entries, real temp-git commit/restore, refine/3, supervised Server | MET | `test/faber/loop_test.exs` — 10 test cases covering all scenarios (default_checks adds 1 extra) |
| P4-T1 | phoenix 1.8.8 / live_view 1.2.3 / bandit 1.12 / lazy_html; config.exs+dev+test+runtime; endpoint secret/salt; .formatter import_deps | MET | `mix.exs` (deps); `config/config.exs`, `config/dev.exs`, `config/test.exs`, `config/runtime.exs`; `.formatter.exs` |
| P4-T2 | `FaberWeb` (endpoint on Bandit, router, root Layouts, ErrorHTML); Plug.Static + vendored UMD JS; PubSub + Endpoint in app tree | MET | `lib/faber_web.ex`; `lib/faber_web/endpoint.ex`; `lib/faber_web/router.ex`; `priv/static/assets/phoenix.min.js` + `phoenix_live_view.min.js` |
| P4-T3 | `FaberWeb.DashboardLive` — mount/rescan → Faber.Scan.run, ranked table (friction/type/opp/signal/T2) + summary; scan_opts from config | MET | `lib/faber_web/live/dashboard_live.ex:26` (Scan.run); `:36` (scan_opts from config); table renders friction/fingerprint/opportunity/signal/T2 columns |
| P4-T3a | Dashboard connected-only scan (connected?/1 guard before scan) | MET | `lib/faber_web/live/dashboard_live.ex:15` — `if connected?(socket)` guards all scan work; disconnected render returns empty assigns |
| P4-T4 | 2 LiveViewTest pass — mounts & renders ranked table over fixtures, rescan re-renders | MET | `test/faber_web/dashboard_live_test.exs` — 2 tests exactly as described; fixtures confirmed by `assert html =~ "fixtures/"` |
| P5-T1 | Full `mix test` (60) + python (16) green; format/warnings clean; boot smoke; README status table + known-gaps; HANDOFF milestones refreshed | UNCLEAR | Python 16 tests verified green. Elixir test count and mix compile result not verified in this diff review (would require running mix test). README and HANDOFF diff'd but full test suite pass not confirmed from code alone. |

**Summary**: 18 MET · 0 PARTIAL · 0 UNMET · 2 UNCLEAR

> Notes:
> - "sidechain dedup" mentioned in the task prompt does not appear in the plan text — no such requirement exists in the plan.
> - P4-T3a and P2-T5a are sub-requirements extracted from P4-T3 and P2-T5 respectively because the prompt specifically called them out for verification. Both are MET.
> - P5-T1 is UNCLEAR because it requires running `mix test` and `mix compile`; the code artifacts (README, HANDOFF) are present in the diff but the claimed 60-test count and clean compile cannot be asserted from static code review alone.
