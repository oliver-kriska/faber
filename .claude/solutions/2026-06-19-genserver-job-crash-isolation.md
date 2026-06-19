# Running jobs inside a long-lived GenServer: link vs nolink

**Problem:** `Faber.Schedule` (a *permanent* GenServer in the supervision tree) ran its
pipeline job with `Task.async(fn -> ... end)` inside the server. A `try/rescue` in the job
body looked like enough protection — but `rescue` only catches exceptions, not `throw` or
`:exit`, and `Task.async` **links** the task to the server. So an uncaught throw/exit from
anywhere in the job (or any process it spawns) propagates and **kills the scheduler**.

**Why it matters here vs. `Faber.Loop.Server`:** the distinction is *server lifetime*.
- `Loop.Server` is `restart: :temporary` and a crash is *meant* to take it down (clean
  crash-isolation for a one-shot run) — linked `Task.async` is correct there.
- `Schedule` is permanent and must survive a bad job — it needs crash isolation.

**Fix (the reusable pattern for permanent servers that run jobs):**
1. Add a `Task.Supervisor` to the app tree *before* the server:
   `{Task.Supervisor, name: Faber.Schedule.TaskSupervisor}`.
2. Start the job with `Task.Supervisor.async_nolink(Sup, fn -> ... end)`.
3. Keep `handle_info({ref, result}, %{task: %Task{ref: ref}} = s)` for success
   (`Process.demonitor(ref, [:flush])`).
4. Add `handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = s)` —
   with `async_nolink`, a crash arrives as a DOWN here instead of killing the server. Record
   it as a failed run and carry on.
5. Belt-and-suspenders: `try/rescue/catch` in the job body still converts the *common*
   failure into a clean result so a single bad item isn't even counted as a crash.

**Testing async jobs deterministically:** don't `Process.sleep`-poll. Add an optional
`:notify` pid to the server; `send(notify, {:tag, :done, summary})` when a run finishes and
`assert_receive {:tag, :done, summary}, 2_000` in the test.

See `lib/faber/schedule.ex`, `lib/faber/application.ex`, `test/faber/schedule_test.exs`.
