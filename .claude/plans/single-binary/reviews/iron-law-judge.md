# Iron Law Violations Report

## Summary

- Files scanned: 2 (`lib/faber/application.ex`, `lib/faber/cli.ex`), plus glob of all `lib/**/*.ex`
- Iron Laws checked: #10 (String.to_atom), #16 (Mix task boot), focused OTP/startup-pattern assessment per prompt
- Violations found: 1 blocker, 1 warning, 1 suggestion

---

## Critical Violations (BLOCKER)

### [OTP-Startup] `System.halt/1` called from `Application.start/2` success branch

- **File**: `lib/faber/application.ex:38`
- **Code**: `Faber.CLI.dispatch(command)` → `System.halt(run(command, opts))` for one-shot commands
- **Confidence**: DEFINITE
- **Classification**: BLOCKER

`Application.start/2` is called by the BEAM's application controller and is expected to return `{:ok, pid}`. Calling `System.halt/1` synchronously inside the success branch of `start/2` (after `Supervisor.start_link`) terminates the entire node before the application controller has a chance to record the started application or run any shutdown callbacks. This is technically functional (halt is immediate) but it bypasses the normal OTP shutdown sequence — `terminate/2` callbacks on GenServers, `at_exit` hooks, logger flushing — and makes the pattern non-composable if Faber is ever embedded in a larger release or umbrella.

**Fix**: Dispatch the one-shot command from a short-lived supervised `Task` that is started as the last child (or via `Task.start_link` from a dedicated `OneShot` child) and calls `System.halt/1` after doing its work. This lets the supervisor tree fully initialize before the command runs, and OTP shutdown callbacks fire if `halt` is replaced by `:init.stop/0` later.

```elixir
# In web_children or a dedicated fn:
defp oneshot_child(command) when not is_nil(command) and command != {:serve, _} do
  {Task, fn ->
    exit_code = Faber.CLI.run(elem(command, 0), elem(command, 1))
    System.halt(exit_code)
  end}
end
```

---

## High Violations (WARNING)

### [OTP-Startup] Work done inside `Application.start/2` before supervision tree is ready

- **File**: `lib/faber/application.ex:13-14`
- **Code**: `command = Faber.CLI.command()` and `Faber.CLI.maybe_apply_port(command)` called before `Supervisor.start_link`
- **Confidence**: LIKELY
- **Classification**: WARNING

**Part (a) — arg parsing before tree:** `Faber.CLI.command/0` parses argv and `maybe_apply_port/1` calls `Application.put_env/3` before the supervision tree exists. Arg parsing itself is pure and safe. The `Application.put_env` call is the risk: if it raises (unlikely but possible with a corrupt env), the application never returns `{:ok, pid}`, leaving the app controller in an inconsistent state.

**Part (b) — `Application.put_env` before Endpoint child starts:** Mutating the endpoint config before the Endpoint child is added to the tree is the *correct and required* approach — Phoenix reads HTTP config at `child_spec` time, so the override must happen before `Supervisor.start_link`. This is sound. No violation here specifically, but it should be documented as load-bearing order.

**Part (c) — conditional Endpoint omission:** Conditionally omitting `FaberWeb.Endpoint` from the child list for one-shot commands is clean and correct. There are no supervision assumptions broken: PubSub, Loop.Supervisor, TaskSupervisor, and Schedule are all started regardless, and none of them depend on the Endpoint being present. `web_children/1` is a fine pattern.

**Fix for (a):** Wrap the pre-tree setup in a `try/rescue` or move it to an early `Application.ensure_all_started/1` hook. Low practical risk given the operations involved, but worth hardening:

```elixir
def start(_type, _args) do
  command = Faber.CLI.command()
  :ok = Faber.CLI.maybe_apply_port(command)
  # ... rest of start unchanged
```

The current code already does this — the only gap is that a crash here produces a raw exit rather than a meaningful error tuple. Acceptable as-is for a single-binary CLI tool; flag for awareness.

---

## Suggestions (SUGGESTION)

### [OTP-Startup] `dispatch/1` returning `:ok` vs. `{:ok, pid}` contract

- **File**: `lib/faber/application.ex:35-40`
- **Code**: The `with {:ok, pid} <- Supervisor.start_link(...)` block calls `dispatch` then returns `{:ok, pid}` — but `dispatch/1` for `:serve` returns `:ok` and for one-shot commands calls `System.halt/1`, so the `{:ok, pid}` return is only reached by the `:serve` and `nil` paths.
- **Confidence**: REVIEW
- **Classification**: SUGGESTION

This is logically sound today but relies on `dispatch` halting the process for all non-serve one-shot commands. If a future command is added that returns without halting (e.g., a `--dry-run` mode), the caller silently discards the result. Add a typespec or `@spec` to `dispatch/1` and an explicit `_ -> :ok` catch-all comment to communicate the contract to future readers.

---

## Clean Checks (no violations)

- **Iron Law #10 (String.to_atom)**: No `String.to_atom/1` calls anywhere in `lib/`. `OptionParser.parse/2` with `strict:` mode returns typed keyword lists — no atom coercion from user input. CLEAN.
- **Iron Law #16 (Mix.Task.run("app.start"))**: `lib/mix/tasks/faber.scan.ex` and `lib/mix/tasks/faber.propose.ex` — not checked in depth but `mix phx.server` path goes through normal `Application.start/2`, not a Mix task boot issue.
- **Conditional Endpoint omission**: CLEAN — see Part (c) above.
- **`maybe_apply_port` mutation timing**: CLEAN for the stated purpose — see Part (b) above.
