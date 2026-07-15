---
module: "Faber.Eval.ExecInPlace / Faber.Subprocess"
date: "2026-07-15"
problem_type: robustness
component: subprocess_guard
symptoms:
  - "a module documented 'failure is never silent → the caller falls back' could instead crash its caller"
  - "the guard was `rescue e in [ErlangError, File.Error]` around a subprocess call that re-raises abnormal task exits via exit/1"
  - "every failure mode reachable in a test (missing binary, bad cwd) surfaced as a rescuable ErlangError, so the gap was invisible to the suite"
root_cause: "an `exit/1` is not an exception — no `rescue` clause catches it, only `catch :exit`. Subprocess.run_with_timeout/4 turns Task.yield's {:exit, reason} into exit(reason), so an abnormally-dying port unwound straight through the rescue and killed the eval pipeline instead of falling back to native scoring."
severity: high
tags: [elixir, otp, rescue, catch, exit, task, subprocess, error-handling, fallback-contract, code-review]
---

# `rescue` cannot catch `exit/1` — pair the guard, and look one frame up first

## The bug

`ExecInPlace.run/4` wrapped its scorer subprocess in:

```elixir
rescue
  e in [ErlangError, File.Error] -> {:error, {:exec_in_place_unavailable, e}}
end
```

`Faber.Subprocess.run_with_timeout/4` deliberately re-raises an abnormal task exit:

```elixir
case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
  {:ok, {:ok, result}} -> result
  {:ok, {:raise, e, stacktrace}} -> reraise e, stacktrace
  {:exit, reason} -> exit(reason)      # <-- no rescue clause will ever see this
  nil -> {:error, :timeout}
end
```

In Elixir, **`raise` and `exit` are different control-flow classes**. `rescue` handles the
exception class only. An `exit/1` is caught exclusively by `catch :exit, reason` (or
`catch kind, reason`). So the guard that existed specifically to convert failure into a fallback
let the one failure mode it most needed to convert pass straight through — inverting the module's
own documented contract from "caller falls back" to "caller dies".

## The fix

```elixir
rescue
  e in [ErlangError, File.Error] -> {:error, {:exec_in_place_unavailable, e}}
catch
  :exit, reason -> {:error, {:exec_in_place_unavailable, reason}}
end
```

## Proof (do this, don't reason about it)

Mirror the guard shape against both control-flow classes:

| guard | `exit(:killed)` | `:erlang.error(:badarg)` |
|---|---|---|
| `rescue` only | `{:ESCAPED_UNCAUGHT, :killed}` | `{:error, {:unavailable, ArgumentError}}` |
| `rescue` + `catch` | `{:error, {:exec_in_place_unavailable, :killed}}` | `{:error, {:unavailable, ArgumentError}}` |

The rescue-only row is the bug, reproduced. The second column proves the fix didn't regress the
path that already worked.

## Why the test suite never caught it

The `{:exit, _}` branch only fires when the **Erlang task process** dies. Every ordinary failure
returns a rescuable `ErlangError` instead — probed five modes looking for a deterministic trigger:

| failure mode | result |
|---|---|
| missing binary | `{:rescued, ErlangError}` |
| `cd:` to nonexistent dir | ran (port-level error) |
| bin is a directory | ran |
| child SIGKILLs itself | ran, nonzero exit code |
| task process killed externally | **exit path** — but kills the caller (Task.async links) |

Only the last reaches it, and the task pid isn't reachable through the public `score/3`. **A racy
test is worse than none** — the guard was proven structurally and the gap documented instead.
Generalizes: when the dangerous branch is unreachable from the public API, prove the guard shape
and say so; don't manufacture a flaky test to fill a coverage box.

## The transferable lessons

1. **Any `rescue` around a call that can `exit` is a latent caller-crash.** In Elixir this means
   anything touching `Task.yield`/`Task.await`, `GenServer.call` (exits on timeout/noproc!),
   `System.cmd` via a task, or ports. Reach for `catch :exit` or `catch kind, reason`.
2. **Grep your own codebase for the pattern before inventing one.** `Faber.CLI.guarded/1` already
   paired `rescue` + `catch kind, reason`, *one frame up the same call stack*, for precisely this
   reason. The correct fix was in-repo the whole time. When a module wraps a call another module
   already wraps, copy the established guard rather than writing a fresh, narrower one.
3. **A documented contract is a testable claim.** "Failure is never silent → the caller falls back"
   was in the moduledoc while the code did the opposite. Docstrings asserting error behavior deserve
   the same adversarial check as the happy path — see [[eval-proxies-are-renderer-guarantees]] for
   the same "the doc says it, so nobody verified it" failure in a different guise.
4. **Review provenance worth remembering:** this was found by two independent reviewers
   (iron-law-judge + elixir-reviewer, consensus), and the exact fact that explains it
   (`subprocess.ex` re-raises via `exit/1`) had been quoted *in the prompt given to those agents by
   the author who wrote the bug*. Knowing a fact and applying it are different; consensus across
   independent reviewers is the cheapest way to close that gap.
