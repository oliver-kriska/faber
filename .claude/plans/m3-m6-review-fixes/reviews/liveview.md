# LiveView Architecture Re-Review: DashboardLive async fix

**Diff base:** f9ded78..HEAD  
**Date:** 2026-06-18  
**Verdict: CLEAN — prior BLOCKER resolved; no new issues.**

---

## 1. start_async / handle_async correctness

**CLEAN.**

`start_async(:scan, fn -> Scan.run(opts) end)` is correct. The callback returns
a bare value (not `{:ok, _}` — that is the job of `assign_async`). LiveView wraps
the return in `{:ok, value}` on success and `{:exit, reason}` on crash/exit, which
is exactly what the two `handle_async` clauses match.

All six assigns the template reads (`@scanned`, `@scanning`, `@total`, `@tier2`,
`@results`, `@shown`) are set unconditionally in the very first `assign/3` call
at the top of `mount/3` (line 18), before the `connected?` branch. Both the
disconnected render (first paint) and the connected render see all keys. No
KeyError risk.

The plan task (P1-T2) originally suggested `assign_async` with a key map, but
the implementation used `start_async` + explicit assigns instead. This is
**preferable** here: the scan produces multiple independent assigns and there is
no `AsyncResult` struct that the template would need to pattern-match.

## 2. :scanning debounce and stuck-true risk

**CLEAN with one SUGGESTION (non-blocking).**

Clause ordering is correct. Elixir pattern-matches top-to-bottom; the
`%{assigns: %{scanning: true}}` guard fires first and short-circuits. The button
carries `disabled={@scanning}` as a belt-and-suspenders guard in the browser.

**Stuck-true analysis:** The only path that sets `scanning: true` is `start_async`
inside `start_scan/1`. Both `handle_async` clauses — success (`{:ok, results}`)
and failure (`{:exit, _}`) — reset `scanning: false`. LiveView's `start_async`
uses a monitored Task; a process kill produces `{:exit, :killed}`, which the
second clause catches. There is no reachable code path where `@scanning` stays
`true` permanently.

**SUGGESTION:** The `{:exit, _}` branch currently silently swallows the reason.
Consider `assign(socket, :scan_error, inspect(reason))` and rendering a brief
"Scan failed — check logs" message when `@scan_error` is set, so the user is not
left with a blank "scanning sessions…" spinner on error.

## 3. flash_group / @flash availability

**CLEAN.**

`plug :fetch_live_flash` (added to the `:browser` pipeline) replaces the default
`fetch_flash` and populates `@flash` in the conn assigns for both dead and live
renders. The root layout reads `@flash` via `<.flash_group flash={@flash} />`.

- **Dead render (GET /):** The conn passes through the browser pipeline;
  `fetch_live_flash` runs; `@flash` is always a map (empty `%{}` if no flash set).
  No raise risk.
- **Live render (connected mount):** LiveView injects flash into root layout assigns
  from the session automatically once `fetch_live_flash` is in the pipeline. Same
  guarantee.

`flash_group/1` declares `attr :flash, :map, default: %{}` — the `default: %{}`
means even if a caller omits the attribute entirely the component renders safely
(iterates over an empty map, emits nothing). The `:for` loop on `{kind, msg} <-
@flash` is correct HEEx.

## 4. Async race and cancellation semantics

**CLEAN.**

**Rescan before first scan resolves:** If the user somehow triggers rescan before
the first `handle_async` fires (practically impossible since the button is hidden
until `@scanned` is true, but worth auditing), `start_async/3` with the same key
`:scan` cancels the previous task and starts a new one. LiveView's `start_async`
guarantees that `handle_async` for a superseded task is never called. No lost
results or double-application risk.

**Results visibility during rescan:** `handle_event("rescan", _, socket)` sets
`scanned: false` and immediately calls `start_scan`. This hides the table and
shows "scanning sessions…" during the rescan. The previous results are cleared
from assigns. This is correct behavior for a local dashboard with fast scans.

**Cancel on disconnect/navigate:** When the LiveView process terminates, the async
task is killed automatically (it is a linked Task monitored by the LiveView
process). No orphan processes.

## 5. Test quality

**CLEAN.**

`async: true` is correct — no shared global state, no DB, no `Application.put_env`
in setup. Tests use a fixture-backed scan (hermetic config). The test correctly
asserts the disconnected state first, then calls `render_async/1` to await the
async task resolution. `render_click(view, "rescan")` exercises the rescan path.

One minor gap: there is no test for the `{:exit, _}` branch (scan crash). This
is low severity given the current read-only scan implementation, but a future
`Scan.run` that raises would benefit from a test asserting the UI recovers
gracefully.

---

## Summary

| Area | Status |
|------|--------|
| start_async / handle_async usage | CLEAN |
| All assigns initialized before connected? branch | CLEAN |
| :scanning stuck-true risk | CLEAN (no reachable path) |
| Debounce clause ordering | CLEAN |
| @flash in dead + live renders | CLEAN |
| flash_group attr/HEEx | CLEAN |
| Async race / cancel semantics | CLEAN |
| Test async: true + render_async | CLEAN |

**Prior BLOCKER (synchronous Scan.run in mount) is resolved.** The fix is
idiomatic, conservative, and introduces no new LiveView anti-patterns.
