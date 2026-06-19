---
scriptorium: true
action: create
title: "Crash-isolating jobs inside a long-lived GenServer (link vs async_nolink)"
type: pattern
domain: claude-elixir-phoenix
tags: [elixir, otp, genserver, task, supervision, crash-isolation]
---

# Crash-isolating jobs inside a long-lived GenServer

When a **permanent** GenServer runs background work, the choice between `Task.async` and
`Task.Supervisor.async_nolink` is a correctness decision, not a style one.

## The trap

`Task.async(fn -> work() end)` inside a GenServer **links** the task to the server. A
`try/rescue` around `work()` is *not* enough protection:
- `rescue` catches exceptions only — not `throw` and not `:exit`.
- The link means any uncaught throw/exit (in the job or a process it spawns) propagates and
  **kills the GenServer**.

For a `restart: :temporary` one-shot server this is fine (a crash is *meant* to end it). For a
**permanent** server that must survive a bad job, it's a footgun.

## The pattern (permanent server runs jobs)

1. App tree, before the server: `{Task.Supervisor, name: MyServer.TaskSupervisor}`.
2. Launch with `Task.Supervisor.async_nolink(MyServer.TaskSupervisor, fn -> work() end)`.
3. Success: `handle_info({ref, result}, %{task: %Task{ref: ref}} = s)` →
   `Process.demonitor(ref, [:flush])`, record result.
4. Failure: `handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = s)` —
   with `async_nolink` a crash arrives here as a DOWN instead of killing the server.
5. Optional belt-and-suspenders: `try/rescue/catch` in the job body to turn the *common*
   failure into a clean result.

## Deciding factor

**Server lifetime.** `:temporary` + crash-should-propagate → linked `Task.async`. Permanent +
must-survive-bad-job → `Task.Supervisor.async_nolink`.

## Testing async jobs deterministically

Don't `Process.sleep`-poll for completion. Give the server an optional `:notify` pid; on
completion `send(notify, {:tag, :done, summary})` and `assert_receive {:tag, :done, _}, 2_000`.

Real example: Faber's `Faber.Schedule` (scheduler) vs `Faber.Loop.Server` (one-shot) — same
Task-in-GenServer shape, opposite correct choice, precisely because of restart strategy.
