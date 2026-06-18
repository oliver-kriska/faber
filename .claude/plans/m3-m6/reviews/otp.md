# OTP Review: Loop + Sidecar (M5 diff e1db06c..HEAD)

Reviewed files: `lib/faber/loop/server.ex`, `lib/faber/loop/supervisor.ex`,
`lib/faber/loop.ex`, `lib/faber/sidecar/system.ex`, `lib/faber/application.ex`.

---

## BLOCKER

### B1 — `await/2` deadlocks when called while the loop is still running
**File:** `lib/faber/loop/server.ex:29,44`

`handle_continue` runs the full `Loop.run/1` synchronously inside the GenServer process.
While that is happening, the mailbox is frozen — no messages are processed. If any caller
issues `GenServer.call(server, :await, timeout)` before `handle_continue` returns, the
call blocks until timeout and raises `{:exit, :timeout}`. The same applies to `status/1`
when called with `:infinity` from another process that doesn't know when the loop will
finish.

This is fine only if every caller knows to wait for the process to exit (i.e. they use
`Process.monitor` rather than `call`). But the public API exposes `await/2` with a
default 60 s timeout and says "block until the loop finishes" — against an overnight
50-iteration run that can easily take hours, that will always time out.

**Fix:** Run the loop in a Task linked to the server, keep `:running`/`:complete` state,
and service `status` and `await` calls normally. The await path can use a blocking
`receive` in a spawned Task or can reply lazily once the loop Task sends `{:loop_done,
result}` via `handle_info`. Example skeleton:

```elixir
def init(loop_opts) do
  {:ok, %{loop_opts: loop_opts, result: nil, waiters: []}, {:continue, :run}}
end

def handle_continue(:run, state) do
  task = Task.async(fn -> Loop.run(state.loop_opts) end)
  {:noreply, Map.put(state, :task, task)}
end

def handle_info({ref, result}, %{task: %{ref: ref}} = state) do
  Process.demonitor(ref, [:flush])
  {waiters, state} = Map.pop(state, :waiters, [])
  Enum.each(waiters, &GenServer.reply(&1, {:ok, result}))
  {:noreply, %{state | result: result, task: nil}}
end

def handle_call(:await, from, %{result: nil} = state) do
  {:noreply, update_in(state.waiters, &[from | &1])}
end
def handle_call(:await, _from, %{result: r} = state) do
  {:reply, {:ok, r}, state}
end
```

The Task is supervised indirectly through the GenServer's link. If the Task crashes, the
GenServer crashes too, the DynamicSupervisor sees the `:temporary` child exit and does not
restart — correct crash-isolation semantics are preserved.

---

## WARNING

### W1 — `System.cmd` exit code ignored in `Faber.Sidecar.System`
**File:** `lib/faber/sidecar/system.ex:36`

```elixir
{out, _code} = System.cmd(python, ...)
```

The exit code is discarded. If Python exits non-zero (import error, runtime exception),
`out` will be whatever was written to stdout before the crash, `Jason.decode` will fail,
and the caller gets `{:error, {:sidecar_bad_output, ...}}` — which is not wrong, but it
makes triage harder than it needs to be.

**Fix:** Pattern-match on `{out, code}` and return a more specific error when `code != 0`:

```elixir
case System.cmd(python, ...) do
  {out, 0} ->
    case Jason.decode(out) do
      {:ok, map} -> {:ok, map}
      {:error, _} -> {:error, {:sidecar_bad_output, out}}
    end
  {out, code} ->
    {:error, {:sidecar_nonzero, code, out}}
end
```

### W2 — `write_candidate` and `restore` use `File.write!` — crashes bubble into the loop iteration, not the GenServer
**File:** `lib/faber/loop.ex:193,199`

`File.write!` raises on I/O errors. Those raises propagate out of `Loop.run/1`, which is
currently running in the GenServer process (B1 above) or in a Task (after B1 is fixed).
In the Task path this is acceptable — the Task crashes, the GenServer sees `{:DOWN, ...}`
and can handle it. But it means a transient filesystem blip kills the entire loop run.

The severity here is mitigated by the Task fix in B1; flag it as a WARNING so a future
reader is aware.

**Fix (optional for now):** Replace with `File.write/2` and propagate `{:error, reason}`
back through `handle_candidate` → `discard`.

### W3 — No `handle_info/2` catch-all or `{:DOWN, ...}` handler in `Loop.Server` (after B1 fix)
**File:** `lib/faber/loop/server.ex` (future state)

Once the Task is added, the GenServer must handle `{:DOWN, ref, :process, _pid, reason}`
for Task failures (and the `{ref, result}` success message). Without these clauses, an
unexpected message or Task crash produces an unhandled message warning or a crash with no
context.

**Fix:** Add `handle_info({ref, result}, ...)` and `handle_info({:DOWN, ref, :process, _pid, reason}, ...)` as shown in B1 example. Also add a catch-all:

```elixir
def handle_info(_msg, state), do: {:noreply, state}
```

---

## SUGGESTION

### S1 — `status/1` uses `:infinity` timeout; normal callers should use a bounded timeout
**File:** `lib/faber/loop/server.ex:25`

After B1 is fixed, `status/1` returns immediately, so `:infinity` is harmless but
unconventional — a caller that accidentally passes a dead PID will hang forever. Use a
reasonable default (e.g. `5_000`).

### S2 — `Loop.Supervisor` ordering relative to `PubSub` / `Endpoint` in the supervision tree
**File:** `lib/faber/application.ex:13-16`

`Faber.Loop.Supervisor` is started before `Phoenix.PubSub`. If a future loop run ever
broadcasts on PubSub at startup (unlikely given "never at boot", but possible if
`start_loop/1` is called from an `after_start` hook), the broadcast will fail because
PubSub isn't up yet. Safe practice: put `PubSub` before anything that might use it. Swap
the order: PubSub → Loop.Supervisor → Endpoint.

### S3 — Temp file path uses `System.unique_integer` which is not UUID-safe in concurrent scenarios
**File:** `lib/faber/sidecar/system.ex:51`

`System.unique_integer([:positive])` is globally monotonic — no collisions in practice —
but it exposes a predictable counter in the filename. Non-issue for security (it's in
`/tmp`, used ephemerally), but consider `:crypto.strong_rand_bytes(8) |> Base.encode16()` for a
less guessable name if the sidecar ever handles sensitive proposal text.

---

## Summary table

| ID | Severity | File | Short description |
|----|----------|------|-------------------|
| B1 | BLOCKER | loop/server.ex:37-38 | Synchronous loop in handle_continue deadlocks await callers |
| W1 | WARNING | sidecar/system.ex:36 | exit code discarded; poor error signal on Python crash |
| W2 | WARNING | loop.ex:193,199 | File.write! raises; blip kills whole loop run |
| W3 | WARNING | loop/server.ex (future) | Missing handle_info for Task result/DOWN after B1 fix |
| S1 | SUGGESTION | loop/server.ex:25 | status/1 uses :infinity; prefer bounded default |
| S2 | SUGGESTION | application.ex:13-16 | PubSub should start before Loop.Supervisor |
| S3 | SUGGESTION | sidecar/system.ex:51 | unique_integer predictable; minor hardening opportunity |
