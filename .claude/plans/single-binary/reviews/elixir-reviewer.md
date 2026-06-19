# Code Review: single-binary CLI + Burrito distribution

## Summary
- **Status**: ⚠️ Changes Requested
- **Issues Found**: 6 (1 BLOCKER, 3 WARNING, 2 SUGGESTION)

---

## BLOCKER

### 1. `System.halt/1` from `Application.start/2` may drop buffered stdout — `cli.ex:84`, `application.ex:38`

`dispatch/1` calls `System.halt(run(command, opts))` synchronously inside the `with {:ok, pid} <- Supervisor.start_link(...)` success branch of `Application.start/2`. `System.halt/1` (the Erlang `:erlang.halt/1` behind it, **without a flush argument**) tears down the VM immediately, **before the IO subsystem flushes its buffer**. The last line(s) of `IO.puts` output (e.g. the render_table result or the error message) may be silently lost on fast hardware.

Fix: use `System.stop(status)` (graceful shutdown, flushes IO, returns to OS via `after_stop`) or spawn a linked process and let `halt` come from outside `start/2`:

```elixir
# In Application.start/2, after Supervisor.start_link:
with {:ok, pid} <- Supervisor.start_link(children, opts) do
  if command != nil and not match?({:serve, _}, command) do
    spawn(fn ->
      status = run_command(command)
      IO.puts("")          # force flush
      System.halt(status)
    end)
  else
    Faber.CLI.dispatch(command)
  end
  {:ok, pid}
end
```

Or simpler: `System.halt` already flushes in recent OTP if passed `:flush` — use `:erlang.halt(status, [:flush])` (OTP 17+). At minimum, add a `Process.sleep(50)` before halt as a stopgap while a proper fix is evaluated.

---

## WARNINGS

### 2. `command/0` discriminator is not robust for Mix releases without Burrito — `cli.ex:35`

```elixir
System.get_env("RELEASE_NAME") && function_exported?(Burrito.Util.Args, :argv, 0)
```

`RELEASE_NAME` is set by any `mix release`, not only a Burrito-wrapped binary. A plain release deployed to a server would satisfy `RELEASE_NAME` while `function_exported?` returns `false` (Burrito module present but not loaded, or absent). In that case `release_argv/0` returns `nil`, so `command/0` returns `nil`, and the endpoint starts — which is arguably correct. However the guard is slightly misleading: if somehow `Burrito.Util.Args` module is compiled into a non-Burrito release (it's a compile-time dep), `function_exported?` could return `true` and `argv()` would return `[]`, causing `parse([])` → `{:help, []}`, then `System.halt(0)` — silently preventing the app from serving.

Recommendation: add a dedicated compile-time module attribute or a dedicated Mix config key (`config :faber, :cli_mode, true`) instead of relying on two runtime signals that can independently vary. If keeping the current approach, document the exact invariants as a comment (e.g., "Burrito sets `RELEASE_NAME`; without Burrito in the dep tree `function_exported?` is always false").

### 3. `with/else` in `run(:propose, _)` swallows a `%Scan.Result{}` non-match — `cli.ex:124–139`

The `with` chain has:
```elixir
%Scan.Result{} = result <- Enum.at(Scan.run(scan_opts), rank - 1),
```

If `Enum.at` returns something other than `nil` and other than `%Scan.Result{}` (e.g. a bare map during a refactor, or a different struct), this clause will **raise a `MatchError`** rather than falling through to the `else` branch — `with` only catches non-matching *left-arrow* (`<-`) results, not pattern match failures on the right-hand side. The `nil` path is already in `else`; the non-nil non-Result crash is not.

Fix: use a tagged-tuple guard:
```elixir
{:result, result} <- {:result, Enum.at(Scan.run(scan_opts), rank - 1)},
# then check result in the body or add a guard clause
```
Or match on `nil` explicitly before the `with`:
```elixir
case Enum.at(Scan.run(scan_opts), rank - 1) do
  nil -> {:error, :no_session}
  %Scan.Result{} = r -> r
end
```

### 4. `parse/1` silently discards unknown/invalid OptionParser flags — `cli.ex:47–58`

All three `OptionParser.parse/2` calls use `_` for invalid flags and invalid args:
```elixir
{opts, _, _} = OptionParser.parse(rest, strict: [...])
```

With `strict:`, unrecognised flags go into the third element (invalid list). They are silently dropped. A user typo like `faber scan --lmiit 10` prints the table with the default, with no hint the flag was ignored. This is a UX bug.

Fix:
```elixir
{opts, _argv, invalid} = OptionParser.parse(rest, strict: [...])
unless invalid == [] do
  IO.puts(:stderr, "faber: unknown option(s): #{Enum.map_join(invalid, ", ", &elem(&1, 0))}")
end
```

---

## SUGGESTIONS

### 5. `open_browser/1` rescues all exceptions, hiding `System.cmd` errors — `cli.ex:166–173`

`rescue _ -> :ok` is an anti-pattern (Iron Law #5: rescue only for external code). Here it IS external code, so rescue is justified. But the bare `_` catches everything including `UndefinedFunctionError`, silently hiding missing `xdg-open` or permission errors. Consider logging to stderr at least in debug mode, or only rescuing `ErlangError`/`File.Error`.

### 6. `adapter_dir/0` in `faber.ex:33` uses a bare relative path fallback — `faber.ex:37`

```elixir
true -> Path.join("adapters", name)
```

This is relative to the OS cwd at runtime. In dev it works (cwd = project root); if a user cd's to another dir before running `mix phx.server` it silently resolves to the wrong path. Consider using `__DIR__` at compile time (but that hardcodes the build path) or documenting that dev requires running from the project root. For a non-release context a `File.cwd!()` based path or a clear error message would be more robust.

---

## Pre-existing code notes (one-liner)

- `Faber.Schedule` and `Faber.Loop.Supervisor` in `application.ex`: supervision tree structure looks correct; loop supervisor started empty and Schedule started inert matches documented behavior.
- `render_table/1` in `cli.ex`: column widths are hardcoded — long fingerprints/signals will cause misaligned output but not a crash.
