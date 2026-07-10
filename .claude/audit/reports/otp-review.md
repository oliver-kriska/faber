# OTP / Process Architecture Audit — Faber

Scope: `lib/faber/application.ex`, `lib/faber/loop/server.ex`, `lib/faber/loop/supervisor.ex`,
`lib/faber/schedule.ex`, `lib/faber/subprocess.ex`, `lib/faber/sidecar/system.ex`,
`lib/faber/llm/claude_cli.ex`, `lib/faber/loop.ex`, `lib/faber/loop/journal.ex`,
`lib/faber/loop/git.ex`, `lib/faber_web/live/dashboard_live.ex`.

## Findings

### WARNING — `lib/faber/cli.ex:170-185`: one-shot CLI dispatch only rescues raises, not exits/throws, defeating "ALWAYS halt"

`dispatch/1` spawns a bare, unsupervised, unlinked process to run a one-shot command and
guarantees `System.halt/1` is always called ("ALWAYS halt — if run/2 raises, halt with 1 rather
than leaving the release VM hung with no exit path"):

```elixir
spawn(fn ->
  status =
    try do
      run(command, opts)
    rescue
      e -> halt_on_raise(e, __STACKTRACE__)
    end
  System.halt(status)
end)
```

`rescue` only catches `raise`d exceptions. It does **not** catch `exit/1` or `throw/1`. There is a
real path that produces a bare exit rather than a raise: `Faber.Subprocess.run_with_timeout/4`
(`lib/faber/subprocess.ex:39-45`) has an `{:exit, reason} -> exit(reason)` clause for a task that
terminates abnormally without being our own brutal-kill (verified empirically — see the clean note
below, the *documented* timeout path itself is fine, but this abnormal-task-exit passthrough is
separate and real). If that fires anywhere in the pipeline invoked by a one-shot CLI command (scan
→ propose → eval → install, all reachable from `dispatch/1`), the `exit(reason)` propagates out of
`run(command, opts)`, is **not** caught by `rescue`, and the spawned process dies silently.
`System.halt/1` never runs. Since a one-shot command doesn't start the web endpoint, nothing else
is keeping the VM up in a *visible* way — the BEAM process just sits there instead of exiting with
a clear failure code, which is worse for CI/automation than a crash: a hung `faber scan` in a
script times out its caller instead of failing fast.

**Fix**: catch exits/throws too, e.g.

```elixir
status =
  try do
    run(command, opts)
  rescue
    e -> halt_on_raise(e, __STACKTRACE__)
  catch
    kind, reason -> halt_on_raise(%RuntimeError{message: "#{kind}: #{inspect(reason)}"}, [])
  end
```

or simplest, wrap the whole spawned body so any non-normal termination always halts:
`try do ... catch :exit, reason -> System.halt(1) end`.

### SUGGESTION — `lib/faber/subprocess.ex`: documented orphan-process caveat is real, not just theoretical

The moduledoc already documents that a brutally-killed task closes the port (giving a well-behaved
child EOF/EPIPE) but "a truly detached child is orphaned." `Faber.LLM.ClaudeCLI.run/5` mitigates
this for its own case by `exec`-ing the target binary inside `sh -c` (so there's no extra shell
layer to leave behind) — a good, deliberate detail. But `claude -p` (and the Python sidecar) can
themselves spawn detached grandchildren (hooks, tool subprocesses) that a `System.cmd` timeout
kill cannot reach, since BEAM's `Port`-based kill only targets the immediate OS process, not its
process group. No action needed unless zombie accumulation is observed in practice; if it becomes
a real problem, the fix is a process-group wrapper (`setsid` + negative-PID kill, or Erlang's
`:exec` alternatives) rather than anything in this module.

## Verified correct (not findings)

- **`lib/faber/subprocess.ex` timeout path is correct as documented** — I suspected `Task.yield`
  timing out followed by `Task.shutdown(task, :brutal_kill)` might return `{:exit, :killed}`
  (hitting the `exit(reason)` clause) rather than the documented `{:error, :timeout}`, which would
  make the advertised timeout contract dead code. Reproduced directly in `elixir`: a task that
  genuinely outlives its yield window and gets brutal-killed returns `nil` from
  `Task.yield(...) || Task.shutdown(...)`, correctly hitting the `nil -> {:error, :timeout}`
  clause. The module's contract holds.
- **`lib/faber/schedule.ex` wedge guard (`max_run_ms` / `:run_deadline`) is correct and
  empirically proven**, not just plausible-by-inspection: `test/faber/schedule_test.exs:187-217`
  drives a genuinely-hung job (`Process.sleep(:infinity)`), confirms it's killed at the deadline,
  recorded as `:run_timeout`, and that the scheduler is not wedged (`runs` increments, a follow-up
  `run_now` succeeds). The stale-deadline-message clause (`handle_info({:run_deadline,
  _stale_ref}, state)`) and the shutdown-races-completion clause are both reachable and correct by
  the same reasoning; `Task.Supervisor` crash cascades into a `{:DOWN, ...}` on the scheduler's
  monitored task ref rather than corrupting scheduler state, since `TaskSupervisor` termination
  kills its children too.
- **`Faber.Schedule` never blocks in a callback.** All subprocess/LLM/git work happens inside
  `Task.Supervisor.async_nolink(__MODULE__.TaskSupervisor, ...)` (`schedule.ex:199`); the GenServer
  itself only manages timers and state. `async_nolink` correctly isolates job crashes as `:DOWN`
  messages instead of taking the scheduler down (tested: `schedule_test.exs:224+`).
- **`Faber.Loop.Server` correctly stays responsive** by running `Loop.run/1` in a `Task.async`
  from `handle_continue/2`, replying to `:status` immediately and queuing `:await` callers as
  `waiters` until the task's `{ref, result}` message arrives. The bare (linked) `Task.async` here
  is the *right* choice, not a missed opportunity for `Task.Supervisor`: the intent is that a
  crashing loop takes the server down (documented), and `restart: :temporary` under
  `Faber.Loop.Supervisor` (a `DynamicSupervisor`, `strategy: :one_for_one`) then correctly leaves
  it down rather than restarting a crashed run.
- **Supervision tree ordering in `lib/faber/application.ex`** is correct: `PubSub` →
  `Faber.Loop.Supervisor` → `Faber.Schedule.TaskSupervisor` → `Faber.Schedule` → web children.
  `Faber.Schedule.TaskSupervisor` is guaranteed up before `Faber.Schedule`'s `init/1` can ever
  reference it, even with a near-zero `initial_delay_ms`.
- **`Faber.Scan.run/1`** (`lib/faber/scan.ex:102-107`) uses `Task.async_stream` with an explicit,
  configurable `max_concurrency`, a per-item `timeout`, and `on_timeout: :kill_task` — bounded
  fan-out, no unbounded process spawning, no hung session can wedge the scan.
- **`Faber.Sidecar.System`** fails closed and cleanly: interpreter/dir are configurable, the
  temp request file uses an unguessable name + `O_EXCL` + `0600` perms (TOCTOU/info-leak
  awareness), it's always removed via `after`, and every non-zero exit / bad-JSON / missing-binary
  case is turned into a tagged `{:error, _}` rather than a raise. The sidecar boundary is real
  subprocess code (not mocked away) — it's simply not exercised by the hermetic `mix test` (default
  `:eval_engine` is `:native`), which is a known, documented, and correctly `:sidecar`-tagged gap in
  `mix test.full`, not a hidden one.
- **`Faber.LLM.ClaudeCLI`** passes all dynamic values (prompt, system, model) through environment
  variables into `sh -c "exec ..."` rather than interpolating into the command string — no shell
  injection surface — and redirects stdin from `/dev/null` deliberately to avoid a 3s hang. The
  `exec` avoids leaving an extra shell-process layer behind on kill.
- **`Faber.Loop.Git`** validates every path through `Path.safe_relative/2` and rejects
  leading-dash arguments before it ever reaches `git`, so a malicious/malformed skill/adapter path
  can't escape `dir` or be read as a git flag; every git invocation goes through
  `Faber.Subprocess.run/3` with a 1-minute timeout.
- **`FaberWeb.DashboardLive`** does no unconditional work in `mount/3` (scan only runs when
  `connected?/1`), uses `start_async` (Phoenix-supervised) for both the scan and the propose
  action so the LiveView process is never blocked, debounces re-entrant `"rescan"`/`"propose"`
  events, and re-checks the `web_allow_propose` gate server-side (not just hiding the button) —
  defense against a client driving the raw event. `Integer.parse/1` on the client-supplied index
  is defensive against a crash from a malformed value.
- No unsupervised/bare long-lived process construction was found anywhere in `lib/faber/` (`Task.start`,
  raw `spawn_link`, `Agent.start` are absent). The only bare `spawn` is the one-shot CLI dispatch
  flagged above, which is short-lived by design (tied to `System.halt/1`) — the issue is its
  incomplete error handling, not the use of `spawn` itself.
- No GenServer here is solving a problem a plain module/Agent/Task would solve more simply —
  `Faber.Loop.Server` and `Faber.Schedule` both need to hold state across async work plus serve
  concurrent callers, which is exactly the GenServer sweet spot.
