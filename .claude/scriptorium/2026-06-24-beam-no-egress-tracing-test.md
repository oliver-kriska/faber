---
scriptorium: true
action: create
title: "Proving a code path makes no network connections (BEAM trace test)"
type: pattern
domain: general
tags: [elixir, beam, testing, tracing, security, determinism, erlang-trace]
---

# Proving a code path makes no network connections (BEAM trace test)

**Problem.** You claim a code path is local-first / hermetic / keyless ("it never touches
the network"). Asserting that by trust is worthless; you want a test that *bites* if any
future change introduces egress (a new HTTP client, a telemetry beacon, a dep that phones
home).

**Technique.** Every outbound TCP/TLS connection on the BEAM funnels through a few public
`connect` entry points, regardless of which HTTP client sits on top (Req/Finch/Mint,
`:httpc`, `:gun` all bottom out here). Trace the *chokepoint*, not each client, so the test
stays client-agnostic. Set a `:call` trace pattern on those MFAs across **all** processes,
run the path, then assert zero were called.

```elixir
@egress_mfas [
  {:gen_tcp, :connect, :_},
  {:ssl, :connect, :_},
  {:socket, :connect, :_}   # newer nif stack; absent on old OTP → matches 0 (no error)
]

# separate tracer process — see pitfall 1
collector = spawn_link(fn -> collect([]) end)
for mfa <- @egress_mfas, do: :erlang.trace_pattern(mfa, true, [:local])
:erlang.trace(:all, true, [:call, {:tracer, collector}])

run_the_path()

# flush: guarantees every trace message generated so far has reached the tracer
ref = :erlang.trace_delivered(:all)
receive do {:trace_delivered, :all, ^ref} -> :ok after 5_000 -> flunk("...") end

:erlang.trace(:all, false, [:call])
# ... dump collector, assert egress == []
```

`collect/1` is a tiny loop that accumulates `{:trace, _pid, :call, {m, f, _a}}` into a list
and replies on a `{:dump, ref, to}` message.

## Two non-obvious pitfalls (both cause a SILENT false-pass)

1. **The BEAM never traces its own tracer process.** If the test process is both the tracer
   *and* the one running the path, every in-process call is invisible — the trace comes back
   empty and the test "passes" having observed nothing. Fix: spawn a **separate** collector
   process and pass it as `{:tracer, pid}`.

2. **`trace_pattern` only matches functions in *loaded* modules.** The BEAM loads code
   lazily, so a module you haven't called yet matches **0 functions** and is never traced.
   OTP modules (`:gen_tcp` etc.) are always loaded; your *own* modules may not be. Fix:
   `Code.ensure_loaded!(MyModule)` before `trace_pattern`. Symptom: `:erlang.trace_pattern/3`
   returns `0` (it returns the count of matched functions — check it while debugging).

## The guard against the guard: a positive control

A no-egress assertion is meaningless if tracing silently no-op'd (either pitfall above, a
typo'd MFA, OTP version drift). Add a **positive control**: also trace one function the path
*provably* calls, and assert it WAS captured. Now an empty egress set means "nothing
connected", not "tracing was broken".

```elixir
@control_mfa {MyApp.Core, :run, :_}
# ... after dump:
assert control != [], "tracer was not live — a clean egress result is meaningless"
assert egress  == [], "path made outbound connections: #{inspect(egress)}"
```

## Test hygiene

- **`async: false` is mandatory.** Tracing `:all` would capture a *concurrent* async test's
  legitimate connect as a false positive. `async: false` runs serially, isolated.
- Know your app's supervision tree: an idle Phoenix Endpoint / PubSub / inert scheduler make
  no outbound connections at rest, so they don't pollute the trace. A started Finch pool is
  idle until a request — fine.
- To prove the egress arm itself bites, connect to a closed local port
  (`:gen_tcp.connect(~c"127.0.0.1", 1, [], 100)`) in a scratch script: the *call* fires the
  trace even though it refuses, confirming detection works.

Implemented in Faber as `test/faber/no_egress_test.exs` (commit 189f60c) to prove the
native scan → propose(stub) → eval(native) → install pipeline is fully offline. Related:
the determinism-hardening batch also added exact per-assertion native↔Python sidecar parity
and a regression-injection gate test (Lore / requirements-as-code lessons).
