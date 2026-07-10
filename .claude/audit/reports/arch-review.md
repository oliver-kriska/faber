# Faber — Architecture Follow-up Review (post 2026-06-26)

Scope: delta since the prior architecture review (`.claude/plans/review/reviews/architecture-review.md`,
2026-06-26). Verifies which prior findings are fixed, then reviews the new/grown surface: `loop.ex`
(276→582 LOC), `consolidate.ex`, `feedback.ex`, `subprocess.ex`, `mix/tasks/faber.refine.ex`, plus
growth in `schedule.ex`, `ccrider.ex` (now `ingest/source/ccrider.ex`), `dashboard_live.ex`.

## Status of the 2026-06-26 findings

| # | Finding | Status |
|---|---|---|
| Theme 2 | `/mcp` CSRF/DNS-rebind (`check_origin: false`) | **FIXED** — `config/runtime.exs:42` now pins `check_origin: ["//localhost", "//127.0.0.1"]`. |
| Theme 2 | `dashboard_live.ex:48` unauthenticated `propose` event | **FIXED** — `dashboard_live.ex:54-77` now has a server-side `allow_propose?/0` gate (`config :faber, :web_allow_propose`) independent of the UI, plus a browser `data-confirm`. |
| Theme 3 | `loop/server.ex:46` bare linked `Task.async` kills mid-commit on shutdown | **STILL OPEN** — see below, now a sharper finding. |
| Theme 1 | `detect.ex` default fingerprint rules / `tidewave?` bake Elixir into the domain-free engine | **STILL OPEN** — unchanged (`detect.ex:85-107`, `226`, `264`, `275`). |
| adapter.ex:317 `acc ++ fun.(entry)` (O(n²)) | **STILL OPEN** — now `adapter.ex:346`, unchanged. |
| eval.ex:93 `adapter_eval(opts)` evaluated twice | **STILL OPEN** — now `eval.ex:92`, unchanged. |
| cli.ex:118 bare `spawn/1` | **STILL OPEN** — now `cli.ex:173`, unchanged. |
| `detect.ex` split suggestion (713 LOC) | **STILL OPEN** — now 724 LOC. |
| `ccrider.ex:46` SQL string interpolation of `provider` | **STILL OPEN** (minor) — `ingest/source/ccrider.ex:49`, unchanged escaping pattern. |

## Fresh findings

### WARNING — `Loop.Server` still uses a bare linked `Task.async`; the fix pattern now exists in the same codebase and wasn't applied here

`lib/faber/loop/server.ex:46`:
```elixir
task = Task.async(fn -> Loop.run(state.loop_opts) end)
```
This is unchanged from the prior review (Theme 3): on supervisor shutdown the DynamicSupervisor's
`:shutdown` signal kills the linked task, which can land mid `Faber.Loop.Git.commit`
(`System.cmd("git", …)` in `loop.ex`'s `Git.commit/3`), leaving a dirty index or a half-written
journal entry.

What makes this a sharper finding now: `lib/faber/schedule.ex:198-211` implements the *exact* fix
this needed, in the same commit range (`Faber.Schedule` predates the review, but a `Task.Supervisor`
child was added at `lib/faber/application.ex:25` for it) — `Task.Supervisor.async_nolink/2` under a
supervised `Task.Supervisor`, `Process.send_after/3` for a wedge deadline
(`schedule.ex:209`), and explicit `{ref, result}` / `{:DOWN, ref, ...}` / `{:run_deadline, ref}`
handling (`schedule.ex:150-186`). The reference implementation to copy is no longer hypothetical —
it's sitting in the same lib tree. `Loop.Server` also has no `max_run_ms`-style wedge guard at all;
`await/2` defaults to `:infinity` (`server.ex:33`), so a loop that never completes (e.g. `Loop.run/1`
looping without ever satisfying a stop condition, or many iterations each just under a per-call LLM
timeout) has no operator-visible kill switch analogous to `Schedule`'s.

**Fix:** add `{Task.Supervisor, name: Faber.Loop.TaskSupervisor}` under `application.ex`, swap
`Task.async` for `Task.Supervisor.async_nolink(Faber.Loop.TaskSupervisor, fn -> Loop.run(...) end)`
in `server.ex`, and handle `{:DOWN, ref, :process, _, reason}` by recording a crashed status instead
of taking the server down. Optionally add a `max_run_ms` deadline mirroring `schedule.ex:169-182`.

### WARNING — `Faber.Feedback` reimplements `Faber.Install`'s marker-path convention instead of calling it

`lib/faber/feedback.ex:100-110`:
```elixir
defp read_installed_at(skill_path) do
  marker = skill_path |> Path.dirname() |> Path.join(".faber.json")
  ...
```
`lib/faber/install.ex:168-170` already encodes the identical path convention (skill dir + the
marker filename) in `faber_installed?/1`, keyed off the private `@marker` module attribute
(`install.ex:25`). Two modules now independently hardcode `.faber.json` and the
"marker lives in `Path.dirname(skill_path)`" relationship. If `Install` ever moves or renames the
marker (e.g. to support per-skill vs per-agent-dir provenance), `Feedback` silently degrades to
"unknown install time → count every session" (its own documented fallback,
`feedback.ex:12-14`) rather than failing loud — a correctness regression with no test to catch it,
since the two implementations would still independently agree by coincidence in the test fixtures.

**Fix:** add a public `Faber.Install.installed_at(skill_path)` (or `read_marker/1` returning the
parsed map) next to `list_faber_installed/1`, and have `Faber.Feedback.read_installed_at/1` call it.
This also removes the `Jason.decode` + `DateTime.from_iso8601` duplication between the two modules.

### SUGGESTION — `Faber.Loop` is accumulating a second responsibility (reflective prompt engineering) on top of the generic engine

`loop.ex` was already the pipeline-wiring module (`refine/3`) sitting next to the pure engine
(`run/1`/`State`) before this review cycle; the growth from 276→582 LOC added a third concern:
`reflection_feedback/3` + `feedback_string/4` (`loop.ex:547-578`) hand-build a multi-paragraph LLM
revision-instruction prompt inline, plus the holdout-split statistics (`holdout_split/2`,
`alternate/1`, `attach_holdout/3`, `loop.ex:404-454`). Every other prompt in the codebase
(`propose.ex:83,143` `system_prompt/1` + `user_prompt/2`; `consolidate.ex:144,165`
`merge_system_prompt/1` + `merge_user_prompt/1`) lives in the module that owns the LLM call it feeds
— `loop.ex`'s `feedback_string/4` is the one prompt fragment that lives one hop away from its
consumer (`Propose.propose/3` via the `:feedback` opt, `propose.ex:58,67-71`). This is not a
correctness bug (test coverage at `loop_test.exs:411-458` is solid, and the module compiles/passes
today), but the module now mixes: (1) the domain-free step/keep/reject engine, (2) pipeline glue
(`refine/3`, `:regenerate`/`:reflect` strategy selection), (3) the fixture-pinning anti-gaming
contract, (4) holdout-split experiment statistics, and (5) prompt-template authoring. A fourth
consumer of "reflective feedback" (e.g. a future `Consolidate`-driven refinement) would have to
either duplicate `feedback_string/4` or reach into `Faber.Loop`'s private functions.

**Fix:** extract `reflection_feedback/3` + `feedback_string/4` into `Faber.Loop.Reflect` (or fold
them into `Faber.Optimize`, which already owns the "what reflection means" narrative in its
moduledoc but currently just delegates 3 lines to `Loop.refine/3`) — leaving `loop.ex` as engine +
pipeline-wiring only, with the prompt-shaping logic co-located with the module whose moduledoc
already claims ownership of "reflective evolution."

### SUGGESTION — `Faber.Consolidate` ships with tests but zero integration into any entry point

`lib/faber/consolidate.ex` is referenced nowhere outside its own module and `consolidate_test.exs`
(`grep -rn Consolidate lib/` returns only the module's own definition). There is no `mix
faber.consolidate` task, no CLI subcommand, no MCP tool, and no dashboard action — the only way to
invoke it is from `iex` or a custom script, as `docs/GUIDE.md:410-413` documents. This appears
intentional (the moduledoc says "Library-level v1"), but it's an inconsistency worth flagging:
`Faber.Feedback`, shipped in the same window for the same "+" milestone row in `README.md:57-58`,
*did* get a symmetric `faber feedback` CLI command (`cli.ex:110-124,312-325`) and dashboard-free but
CLI-reachable treatment, while `Faber.Consolidate` did not. If consolidation is meant to be used in
the real workflow soon (its own moduledoc frames it as needed because "dogfooding against a real
external project yielded several variants of the same skill"), the gap between "library primitive"
and "something a user can actually run" is the same gap `Faber.Feedback` just closed — worth closing
here too before it's forgotten as a permanent library-only feature.

## Clean areas (one line each, not re-litigated)

- `Faber.Subprocess` is a clean, minimal, well-tested boundary (`subprocess_test.exs`), and its
  timeout is now correctly threaded through both `claude_cli.ex` and `sidecar/system.ex` and the new
  `ccrider.ex` sqlite3 call — closes a real robustness gap from before this review.
- `Faber.Schedule`'s growth (async_nolink + wedge guard + DOWN handling) is exactly the OTP pattern
  the prior review wanted elsewhere; no new issues found in it.
- `mix xref graph --format stats`: still 5 cycles (all pre-existing benign runtime dispatch cycles),
  9 compile edges, `Adapter` remains the top fan-in hub (12) — the domain-free DAG shape has not
  regressed with the new modules.
- `Faber.Consolidate`'s `cluster/2` (pure, deterministic, single-linkage Jaccard) and gate-before-merge
  design (`run/3` → `Eval.gate/2`) correctly reuse the existing eval boundary rather than inventing a
  parallel quality bar.
- CLI parsing/dispatch for `refine` and `feedback` is tested at the `CLI.run/2` layer
  (`cli_test.exs:38-46,124-161`), consistent with the project's existing convention of not
  unit-testing `Mix.Tasks.*` modules directly.
