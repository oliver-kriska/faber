---
name: elixir-no-egress-test
description: "Prove an Elixir/BEAM code path makes ZERO outbound network connections, via Erlang call-tracing of the socket-connect chokepoints. Use when a path is claimed local-first / hermetic / keyless / air-gapped and you need a test that *bites* if any future change (a new HTTP client, telemetry beacon, or dep that phones home) introduces egress. Client-agnostic: traces gen_tcp/ssl/socket, not Req/Finch/Mint/:httpc/:gun individually."
effort: medium
argument-hint: ""
allowed-tools:
---

# Elixir No-Egress Test (BEAM trace)

Asserting "this never touches the network" by trust is worthless. Every outbound TCP/TLS
connection on the BEAM funnels through a few public `connect` entry points — every HTTP
client (Req/Finch/Mint, `:httpc`, `:gun`) bottoms out there. **Trace the chokepoint, not
each client**, so the guard stays client-agnostic: swap the HTTP stack and the test still
bites. Set a `:call` trace pattern on those MFAs across **all** processes, run the path,
then assert zero were called.

This is the moat-test pattern behind Faber's `test/faber/no_egress_test.exs`.

## Iron Laws - Never Violate These

1. **SPAWN a SEPARATE tracer process** and pass it as `{:tracer, pid}`. The BEAM never
   traces its own tracer — if the test process is both tracer and runner, every in-process
   call is invisible, the trace comes back empty, and the test silently "passes" having
   observed nothing.

2. **ADD a positive control** — also trace one MFA the path *provably* calls, and assert it
   WAS captured. Without it, an empty egress set is ambiguous: "nothing connected" vs
   "tracing silently no-op'd". A clean result is meaningless unless the control fired.

3. **`Code.ensure_loaded!/1` your own modules before `trace_pattern`.** A pattern only
   matches functions in *loaded* modules and the BEAM loads code lazily. OTP modules
   (`:gen_tcp` etc.) are always loaded; your own control module may not be — unloaded ⇒
   matches 0 functions ⇒ control never fires (the exact false-negative law 2 guards).

4. **`async: false` is MANDATORY.** Tracing `:all` would capture a *concurrent* async
   test's legitimate connect as a false positive. Serial isolation keeps the trace window
   clean.

5. **FLUSH with `:erlang.trace_delivered/1` before dumping.** A connect in a just-finished
   Task worker can still be in flight; without the flush you can miss a late-but-real call.

## Usage

```
# Fires when a path is asserted hermetic/keyless/local-first and you want a regression
# guard against future egress. Run as a normal (async: false) ExUnit test.
mix test test/faber/no_egress_test.exs
```

## Workflow

1. Pick the egress chokepoints and a positive control MFA the path provably calls.
2. Spawn a separate collector, `ensure_loaded!` the control module, set patterns, trace `:all`.
3. Run the path inside `try`, flush delivery, then untrace in `after`.
4. Dump the collector; assert the control fired AND egress is empty.

```elixir
defmodule MyApp.NoEgressTest do
  use ExUnit.Case, async: false   # Law 4

  # Law: trace the chokepoint, not each client. `:socket` is the newer nif stack —
  # absent on older OTP, where trace_pattern simply matches 0 functions (no error).
  @egress_mfas [{:gen_tcp, :connect, :_}, {:ssl, :connect, :_}, {:socket, :connect, :_}]
  @egress_keys [{:gen_tcp, :connect}, {:ssl, :connect}, {:socket, :connect}]
  @control_mfa {MyApp.Core, :run, :_}   # Law 2 — provably called by the path
  @control_key {MyApp.Core, :run}

  test "the path opens zero outbound sockets" do
    collector = spawn_link(fn -> collect([]) end)   # Law 1 — separate tracer
    Code.ensure_loaded!(MyApp.Core)                  # Law 3

    patterns = [@control_mfa | @egress_mfas]
    for mfa <- patterns, do: :erlang.trace_pattern(mfa, true, [:local])
    :erlang.trace(:all, true, [:call, {:tracer, collector}])

    try do
      MyApp.Core.run(input)
      flush_trace_delivery()                         # Law 5
    after
      :erlang.trace(:all, false, [:call])
      for mfa <- patterns, do: :erlang.trace_pattern(mfa, false, [:local])
    end

    calls   = dump(collector)
    egress  = Enum.filter(calls, &(&1 in @egress_keys))
    control = Enum.filter(calls, &(&1 == @control_key))

    assert control != [], "tracer was not live — a clean egress result is meaningless"
    assert egress  == [], "path made outbound connections: #{inspect(egress)}"
  end

  defp flush_trace_delivery do
    ref = :erlang.trace_delivered(:all)
    receive do
      {:trace_delivered, :all, ^ref} -> :ok
    after 5_000 -> flunk("trace_delivered timed out") end
  end

  defp dump(collector) do
    ref = make_ref()
    send(collector, {:dump, ref, self()})
    receive do
      {:calls, ^ref, calls} -> calls
    after 5_000 -> flunk("trace collector did not respond") end
  end

  defp collect(acc) do
    receive do
      {:trace, _pid, :call, {m, f, _a}} -> collect([{m, f} | acc])
      {:dump, ref, to} -> send(to, {:calls, ref, drain(acc)})
    end
  end

  # Drain still-enqueued traces before replying (belt-and-suspenders atop the flush).
  defp drain(acc) do
    receive do
      {:trace, _pid, :call, {m, f, _a}} -> drain([{m, f} | acc])
    after 0 -> acc end
  end
end
```

## Patterns

- **Know your supervision tree.** An idle Phoenix Endpoint / PubSub / inert scheduler make
  no outbound connections at rest, so they don't pollute the trace. A started Finch pool is
  idle until a request — fine.
- **Prove the egress arm itself bites.** In a scratch script, connect to a closed local port
  (`:gen_tcp.connect(~c"127.0.0.1", 1, [], 100)`): the *call* fires the trace even though it
  refuses, confirming detection works.
- **`trace_pattern/3` returns the count of matched functions** — check it while debugging a
  control that won't fire (0 means the module wasn't loaded).

## References

- Faber: `test/faber/no_egress_test.exs` (the native scan→propose→eval→install pipeline is hermetic).
- Pattern note: `.claude/scriptorium/2026-06-24-beam-no-egress-tracing-test.md`.
