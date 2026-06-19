# Iron Law Violations Report

## Summary

- Files scanned: 5 primary (`schedule.ex`, `application.ex`, `ingest/format/claude.ex`,
  `ingest/format.ex`, `loop/server.ex`) + supporting files
- Iron Laws checked: 13 of 26 (OTP, Task lifecycle, security, process patterns, mix tasks)
- Violations found: 1 blocker, 0 high, 1 suggestion

---

## Critical Violations (BLOCKER)

### [OTP-linked-task] Task.async inside GenServer without trap_exit — scheduler can be killed by job crash

- **File**: `lib/faber/schedule.ex:161`
- **Code**: `Task.async(fn -> ... end)` called directly in `start_job/1` inside the GenServer
- **Confidence**: DEFINITE

`Task.async/1` links the Task to the caller process. When used inside a GenServer, the
GenServer IS the caller. If the Task crashes (despite the `try/rescue` inside it, a BEAM
EXIT signal from an external kill, a linked-process exit, or a `throw` not caught by
`rescue` can still propagate), the GenServer receives an EXIT signal and crashes with it —
unless `Process.flag(:trap_exit, true)` is set.

The `try/rescue` wrapping `run_once/1` catches normal `raise`/exceptions, but NOT:
- `throw` (rescue does not catch throws — only `catch` does)
- External EXIT signals (e.g., `Process.exit(task_pid, :kill)`)
- Any OTP-linked process that the job itself spawns and then crashes

**The current comment at line 150 says "The job Task is trapped to never crash the
scheduler (it rescues internally)"** — this claim is only partially correct. `rescue`
stops exceptions; it does not stop all crash vectors.

**Fix — two options:**

Option A (preferred for supervision intent): Use `Task.Supervisor` so the Task is not
linked to the GenServer:

```elixir
# In application.ex, add before Schedule:
{Task.Supervisor, name: Faber.Schedule.TaskSupervisor},
Faber.Schedule,

# In start_job/1:
task = Task.Supervisor.async_nolink(Faber.Schedule.TaskSupervisor, fn ->
  try do
    run_once(job_opts)
  rescue
    e -> %{scanned: 0, proposals: [], error: Exception.message(e)}
  catch
    :throw, t -> %{scanned: 0, proposals: [], error: "throw: #{inspect(t)}"}
  end
end)
```

With `async_nolink`, the `{ref, result}` message still arrives for success, and the
`handle_info(_msg, state)` catch-all absorbs the `:DOWN` for crashes — but the scheduler
itself survives the job crash and reschedules.

Option B (minimal): Add `Process.flag(:trap_exit, true)` in `init/1` and handle
`{:EXIT, pid, reason}` explicitly. This keeps the link but lets the GenServer intercept
the exit signal.

**Current risk**: A `throw` inside `Propose`, `Eval`, or any dependency, OR a linked
subprocess dying inside the job, will silently crash `Faber.Schedule`. The supervisor
will restart it (`:one_for_one`), but the `running: true` state resets and the in-flight
job is orphaned with no log entry. Since the scheduler is permanent, it will restart, but
the crash itself is avoidable.

---

## Suggestions

### [timer-init] `schedule_next` called in `init/1` even when `enabled: false`

- **File**: `lib/faber/schedule.ex:118`
- **Code**: `{:ok, schedule_next(state, first_delay)}`
- **Confidence**: REVIEW

When `enabled: false`, `schedule_next/2` immediately cancels the (nil) timer and returns
`state` unchanged — correct behaviour. However, `first_delay` is computed before the
branch check (line 117) using `cfg[:initial_delay_ms]`, which defaults to `every_ms`.
This is a no-op in the disabled path, but the logic could mislead a future reader into
thinking a timer fires. Low severity; consider early-returning `{:ok, state}` when not
enabled, or documenting the no-op explicitly.

---

## Confirmed Clean (selected highlights)

- **Iron Law #10 String.to_atom**: No `String.to_atom/1` in any `lib/` file. `jason`
  decodes with `keys: :strings` at line 52 of `format/claude.ex` — explicitly documented.
  CLEAN.

- **Iron Law #5 SQL injection**: No Ecto/SQL usage (DB-less spine). Not applicable.

- **Iron Law #3 PubSub subscribe**: `Phoenix.PubSub` is added to the supervision tree but
  no subscribe calls found outside guarded contexts. Not applicable to this code.

- **Iron Law #8 OTP supervision**: All long-lived processes (`Faber.Schedule`,
  `Faber.Loop.Supervisor`, `Faber.Loop.Server`) are under supervision trees. No bare
  `start_link` calls outside a supervision tree. CLEAN.

- **Iron Law #16 Mix tasks**: `faber.propose` uses `Mix.Task.run("app.config")` +
  `Application.ensure_all_started/1` — correct pattern. CLEAN.

- **`Loop.Server` Task pattern**: Uses the same `Task.async` + `{ref, result}` +
  `demonitor(ref, [:flush])` pattern. Same linked-Task concern applies — BUT the design
  is intentional here: a crash propagates to `Loop.Server`, which is `:temporary` and
  stays down (correct crash-isolation by design, documented at line 7–11). CLEAN by
  design.

- **demonitor/flush correctness**: Both `schedule.ex:143` and `loop/server.ex:62` call
  `Process.demonitor(ref, [:flush])` in the `{ref, result}` handler, correctly flushing
  any pending `:DOWN` before it reaches the mailbox. Pattern is correct.

- **Timer lifecycle**: `schedule_next/2` cancels any pending timer before arming a new
  one (`Process.cancel_timer` then `Process.send_after`). No double-arm path exists
  because both the `:tick` handler and `handle_cast(:run_now)` go through `start_job`
  which does NOT touch the timer — only `schedule_next` does. Timer is single-entry at
  all times. CLEAN.

- **`run_now` while running guard**: `handle_cast(:run_now, %{running: true})` short-
  circuits with a log line and returns unchanged state. CLEAN.

- **`{ref, summary}` DOWN message**: The `handle_info({ref, summary}, ...)` clause
  pattern-matches on `%Task{ref: ref}` which pins the ref to the live task. The catch-all
  `handle_info(_msg, state)` absorbs any stray `:DOWN` message. The `:DOWN` for a
  normally-exiting Task arrives AFTER the `{ref, result}` message; `demonitor(ref,
  [:flush])` removes the monitor and drains any queued `:DOWN` atomically. Correct.

- **Iron Law #19 comments**: No inline ticket tags. Comments are architectural notes
  (durable facts about the design), not change-narration. CLEAN.
