# OTP Re-Review: Loop.Server Fix (f9ded78..HEAD)

## Focus: BL1 — Loop.Server Task-async fix

---

## 1. Task.async + handle_info Pattern Correctness

**SOUND.**

`Task.async/1` spawns a linked, monitored process. It returns a `%Task{ref: ref, pid: pid}` where `ref` is the monitor reference. When the task exits normally, the calling process (the GenServer) receives `{ref, result}` followed by a `{:DOWN, ref, :process, pid, :normal}` message.

The `handle_info({ref, result}, %{task: %Task{ref: ref}} = state)` clause matches the result message correctly — the pattern pins `ref` from the stored `%Task{}` struct, so only the message from *this* task matches (no stray message confusion). `Process.demonitor(ref, [:flush])` then discards the trailing `:DOWN` message from the mailbox before it arrives or immediately after. This is exactly the canonical "manual Task.async + handle_info" pattern from OTP docs and is correct.

The `_msg` catch-all is appropriate and the comment accurately explains why it exists (linked crash propagates before `:DOWN` can arrive for crashes; normal `:DOWN` is flushed; catch-all handles any remaining stray messages).

---

## 2. Crash Isolation and Hanging Waiters

**DESIGN SOUND — with one tradeoff worth understanding.**

### Crash path

`Task.async` **links** the task to the GenServer. If `Loop.run/1` raises, the task exits abnormally, the link fires, and the GenServer receives an exit signal. Because the GenServer does **not** `Process.flag(:trap_exit, true)`, it propagates the crash and dies. The `:temporary` restart strategy on `DynamicSupervisor` leaves it down. This is the documented and intended behavior (per the moduledoc and plan P1-T1).

### Waiter hang on crash

**Yes — an `await/2` caller parked in `waiters` with timeout `:infinity` will hang forever if the server crashes before replying.**

When the GenServer dies, all parked `GenServer.call` callers (the `from` tuples stored in `waiters`) are sent an exit signal by the runtime (OTP replies `{:EXIT, server, :noproc}` or the caller itself crashes if not trapping exits). In practice, the calling process will receive a `** (exit) :noproc` (or the original crash reason propagated through the link from the GenServer), which terminates it unless it traps exits.

**Is this acceptable here?** Yes, for this use case. The callers are either:
- Mix tasks / IEx sessions that tolerate a crash,
- Future dashboard LiveView sockets that will have their own supervision.

The moduledoc correctly documents this tradeoff. For a production API where callers must get a clean error rather than an exit, you'd add `trap_exit: true` and a `handle_info({:EXIT, ...})` or use `Task.Supervisor.async_nolink` + an explicit `:DOWN` monitor. But that complexity is not warranted for Faber's local-first, on-demand loop model.

The catch-all `handle_info(_msg, state)` does **not** accidentally swallow anything important. The only message paths are: (a) `{ref, result}` — matched above; (b) `{:DOWN, ref, ...}` — flushed by demonitor in the success path, never reaches catch-all for normal exits, and the crash path kills the server before catch-all fires; (c) stray messages — catch-all is correct to drop silently.

---

## 3. application.ex Supervision Ordering

**CORRECT.**

PubSub starts before Loop.Supervisor before Endpoint. Since Loop.Server children may broadcast on PubSub when they complete (and Endpoint consumers need both), this ordering is correct. The prior ordering (PubSub started after Endpoint) was a latent bug for any on-start broadcast; the fix closes it.

---

## 4. Message Ordering, Races, and Leaks

**No new races introduced.**

- The task ref is stored in state before any `handle_info` can arrive (Erlang's message ordering guarantees the `{ref, result}` message is enqueued only after the task lambda returns, which is after `handle_continue` returns the updated state).
- The `waiters` list is cleared atomically with storing `result`, so a concurrent `:await` call arriving after `handle_info` fires hits the `when not is_nil(r)` clause and replies immediately — no race between "just stored result" and "waiter added after result".
- No process leak: `Task.async` creates one linked+monitored process; the monitor is explicitly cleaned up. No supervision tree entry is needed since `Task.async` links ensure lifecycle coupling.

---

## 5. loop.ex Changes

**SOUND.**

- `File.write/2` (returning `{:ok | :error, ...}`) replacing `File.write!/2` (raises) is correct; W5 fix. Error is propagated through `handle_candidate` → `reject/5` — the run continues rather than crashing.
- `restore/1` now ignores its return value with `_ = File.write(...)` — correct best-effort semantics.
- `revert/5` and `discard/5` merged into single `reject/5` — pure cleanup, no behavioral change.
- `refine/3` now wraps `Propose.propose` in a `case` and returns `{:error, reason}` on first-proposal failure — fixes BL3 MatchError crash.

---

## Summary

| # | Item | Verdict |
|---|------|---------|
| 1 | Task.async + handle_info pattern | SOUND |
| 2 | Crash propagates to server (no trap_exit) | CORRECT — intentional |
| 3 | Awaiter hang on crash (:infinity) | ACCEPTABLE — documented tradeoff for local-first use |
| 4 | Catch-all swallows important messages | NO — correctly scoped |
| 5 | application.ex ordering | CORRECT |
| 6 | Race between result store and new waiter | NO RACE |
| 7 | File.write/2 + reject/5 + refine/3 error path | SOUND |

**No BLOCKERs. No WARNINGs. One tradeoff noted (await hang on crash) — acceptable and documented.**
