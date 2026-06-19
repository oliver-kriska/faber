# Test Review: test/faber/{template,schedule,optimize,ingest_format,install,propose}_test.exs + test/faber_web/dashboard_live_test.exs

## Summary

Seven new test files cover the Stage 3–6 pipeline modules. Overall quality is high: tests are hermetic (no network, no Python spawn), proper behaviour stubs are used, tmp_dir is leveraged correctly, and the LiveView uses `render_async`. Three issues require attention: one BLOCKER (flaky polling helper), one WARNING (async/false scheduling risk), and several suggestions.

---

## Iron Law Violations

None — no DB, no Oban, no Mox (inline behaviour stubs are used instead, which is correct). No global state mutations found in `async: true` suites.

---

## Issues Found

### BLOCKER

- [ ] **`eventually/2` with `Process.sleep` in `schedule_test.exs` lines 82–92 is a flaky polling loop.**
  The helper spins 100 × 20 ms = 2 000 ms max. If CI is under load the GenServer `Task.async` may not complete within that window, causing intermittent failures. The underlying job signals completion via a `{ref, result}` message back to the GenServer — a clean alternative is to use `assert_receive` directly, or refactor `Schedule.status` to block until `running: false` with a timeout. The `Process.sleep` itself violates Iron Law #6 ("NO PROCESS.SLEEP"). Minimum fix: replace with `assert_receive`-style polling via `:sys.get_state/2` loop, or add an explicit `Schedule.await_run/2` API that does `GenServer.call` with a timeout.

### WARNING

- [ ] **`schedule_test.exs` is `async: false` but could race if the test suite is ever run with multiple named-schedule processes or a globally registered `Schedule` name.** Line 74: `start_supervised!({Schedule, name: nil, ...})` correctly avoids registering a name, so this is safe for now. However the module comment says `async: false` is due to "named-but-unique GenServers" — the actual reason is the `Process.sleep` polling. If `eventually` were replaced, this suite could likely become `async: true`, reducing test suite time. Consider clarifying in the comment or enabling async after fixing the BLOCKER.

- [ ] **`schedule_test.exs` line 74: `run_now` test does not supply `adapter_dir`.** The call is `{Schedule, name: nil, enabled: false, top: 1, scan: @fixtures}` with no `adapter_dir`. `run_once` defaults to `"adapters/faber-elixir"`. If that path doesn't exist in the CI checkout this test fails silently (the run completes with `%{error: _}`). The test only asserts `runs >= 1` (run count incremented), not that the run succeeded — a run returning `%{error: ...}` also satisfies the assertion, making this test weaker than it appears. Add an assertion on `last_summary` or supply `adapter_dir: "adapters/faber-elixir"` with an explicit check.

- [ ] **`dashboard_live_test.exs`: `handle_async(:scan, {:exit, reason})` path (flash error on scan failure) is not tested.** The LiveView has two async error paths (`:scan` exit and `:propose` exit at lines 76 and 87 of `dashboard_live.ex`) — neither is exercised. These are public `handle_async` callbacks with user-visible flash output.

- [ ] **`propose_test.exs`: `render_skill_md/2` with an adapter whose template contains a nested section (`{{#iron_laws}}`) does test expansion (line 156), but does NOT test the context key `skill_title` (titleize), `effort`, `one_line_purpose`, or `usage_examples` token substitutions.** If `template_context/1` maps a key incorrectly, these fields silently render as empty strings — invisible to the current assertions.

### SUGGESTION

- [ ] **`template_test.exs`: Missing edge cases for the Mustache renderer:**
  - Nested sections (`{{#outer}}{{#inner}}…{{/inner}}{{/outer}}`) — the regex is non-greedy and uses a backreference; deeply nested same-key sections will mis-pair. Worth a test to document the known limitation.
  - Non-map list items (`[1, 2, 3]` — not maps) — `render_sections` falls through to `context` merge without crashing, but the behaviour is undocumented. Line 37 in `template.ex`: `scope = if is_map(item), do: Map.merge(context, item), else: context`. A test with a list of scalars would prevent silent regressions.
  - Empty string falsy case (`""`): listed in the module doc as falsy but not tested. `"" || []` — a blank string should suppress the section body.

- [ ] **`install_test.exs`: `default_dir/0` is not tested.** It reads `Application.get_env(:faber, :skills_dir, ...)` and falls back to `~/.claude/skills`. There is no test confirming the fallback resolves correctly (especially when `System.user_home()` returns `nil`). The private `home/0` path with `File.cwd!()` is entirely untested.

- [ ] **`ingest_format_test.exs` line 19: `FakeFormat.stream_file!/1` hard-codes the path argument as `_path` and always returns one fixed event.** This means `Ingest.parse_file("anything", format: FakeFormat)` passes regardless of path routing. A second test variant where `discover/1` and `stream_file!/1` are coordinated (path actually passed through) would give stronger coverage of the delegation chain.

- [ ] **`dashboard_live_test.exs`: The debounce logic for both `"rescan"` (line 37) and `"propose"` (line 45) when `scanning: true` / `proposing: true` is not tested.** These guards are explicit `handle_event` clauses — worth a line or two confirming the event is ignored while a scan/propose is already in flight.

- [ ] **`optimize_test.exs`: No test for `Optimize.run/2` when sidecar returns `{:ok, %{"status" => "error", ...}}`** (i.e., a successful transport call but an application-level error payload). Depending on `Optimize.run/2`'s implementation this may be an untested branch.
