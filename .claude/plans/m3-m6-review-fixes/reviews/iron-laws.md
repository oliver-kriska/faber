# Iron Law Violations Report — m3-m6 Fix Verification

Diff base: `f9ded78..HEAD`. Checked new/changed code only.

## Summary

- Files scanned: 9 (loop/server.ex, loop.ex, loop/git.ex, loop/supervisor.ex, sidecar/system.ex, dashboard_live.ex, layouts.ex, application.ex, mix/tasks/faber.propose.ex)
- Iron Laws checked: 16 of 26
- **Prior violations: all 3 RESOLVED**
- **Fresh violations: 0**

---

## Prior Violation Resolution Status

### [RESOLVED] #1 — faber.propose mix task: app.start → app.config (HIGH/WARNING)

`lib/mix/tasks/faber.propose.ex:45` now calls `Mix.Task.run("app.config")` followed by
`Application.ensure_all_started(:req_llm)`. The endpoint is NOT started; no port is bound.
The inline comment documents the intent. **Fully resolved.**

### [RESOLVED] #2 — Sidecar exit code discarded (HIGH/WARNING)

`lib/faber/sidecar/system.ex:35-44` now explicitly matches `{out, 0}` for success and
`{out, code}` for any non-zero exit, returning `{:error, {:sidecar_exit, code, out}}`.
Partial stdout on failure is correctly rejected. **Fully resolved.**

### [RESOLVED] #3 — Dashboard rescan: no auth guard (MEDIUM/SUGGESTION)

`lib/faber_web/live/dashboard_live.ex` moduledoc explicitly states the local-first design
rationale and calls out that an `on_mount` guard is needed before exposing over a network
interface. The rescan handler adds a `:scanning` debounce guard. No auth was added (by
design — local tool), and the residual risk is appropriately documented at the module level.
**Resolved as acknowledged residual.**

---

## Fresh Violations

None found. Specific checks performed:

- **Iron Law #16 (Mix task app.start):** `faber.propose` uses `app.config` — CLEAN.
- **Iron Law #10 (String.to_atom):** No `String.to_atom/1` calls in `lib/`. Untrusted JSON
  keys decoded with `keys: :strings` per `Faber.Ingest` moduledoc — CLEAN.
- **Iron Law #12 (raw/):** No `raw(` in HEEx or LiveView files — CLEAN.
- **Iron Law #13 (Process without runtime reason):** `Faber.Loop.Server` is a GenServer
  managing long-lived loop state + Task link; `Faber.Loop.Supervisor` is a `DynamicSupervisor`.
  Both are registered in the supervision tree via `Faber.Application`. Runtime reason is
  clear (concurrency + crash isolation). CLEAN.
- **Iron Law #8 (OTP supervision):** No bare `start_link` outside a supervision tree. All
  processes go through `Faber.Loop.Supervisor.start_loop/1` → `DynamicSupervisor`. CLEAN.
- **Task.async in loop/server.ex:** `Task.async` (not `Task.Supervisor.async_nolink`) is
  used intentionally — the link is the crash-propagation mechanism documented in the moduledoc
  (loop Task crash → GenServer crash → `:temporary` strategy leaves it down). Handle_info
  correctly demonitors on success. CLEAN.
- **Iron Law #15 (@external_resource):** `File.stream!` in `Faber.Ingest.stream_file!/1` is
  inside a function body (runtime, not compile-time) — no `@external_resource` needed. CLEAN.
- **Iron Law #5 (pin values in queries):** No Ecto queries in new code. CLEAN.
- **Iron Law #3 (connected? before PubSub):** No PubSub in new code. CLEAN.
- **Iron Law #1 (mount DB queries):** `dashboard_live.ex` correctly uses `connected?` guard +
  `start_async` — disconnected render returns loading skeleton, scan runs only on connect. CLEAN.
- **loop/git.ex safe_paths:** LLM/adapter-supplied paths are validated via `Path.safe_relative/2`
  and leading-dash rejection before being passed to `git`. CLEAN.
- **layouts.ex flash_group:** `{msg}` renders via HEEx interpolation (auto-escaped), not
  `raw(`. CLEAN.

Checked 16 of 26 Iron Laws. Remaining 10 laws (Oban-specific, money fields, has_many joins,
cross joins, compile-time dedup, hidden inputs, locale capture, assign_new misuse) are not
applicable to the changed files.
