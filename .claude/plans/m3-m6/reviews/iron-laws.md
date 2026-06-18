# Iron Law Violations Report

## Summary

- Files scanned: 31 (lib/**/*.ex, lib/mix/tasks/*.ex)
- Iron Laws checked: 19 of 26 (LiveView, OTP/supervision, security, Mix tasks, Elixir idioms; Ecto/Oban not applicable — no DB or job workers)
- Violations found: 3 (0 critical, 2 high, 1 medium)

---

## High Violations

### [Mix Task #16] faber.propose — starts only `:req_llm`, not the full Faber app

- **File**: `lib/mix/tasks/faber.propose.ex:43`
- **Code**: `Application.ensure_all_started(:req_llm)`
- **Confidence**: LIKELY
- **Issue**: The task calls `Faber.Scan.run/1` → `Faber.Ingest` → `File.stream!` and `Faber.Adapter.load/1` → `File.read!` — all fine. But it also calls `Faber.LLM.generate_object/3` → `Faber.LLM.ReqLLM` which uses `ReqLLM.generate_object/4` from the `req_llm` library. Starting only `:req_llm` leaves the `Faber` application itself unstarted, which means `Application.get_env(:faber, :llm, ...)` calls work (the env is loaded by `app.config`) but any runtime OTP registries faber might need are absent. More importantly — `Faber.Sidecar.System` calls `System.cmd("python3", ...)` which relies on nothing from the Faber supervision tree, so the sidecar path is fine. However, `Faber.LLM.ClaudeCLI` is also a pure `System.cmd` call. The real risk: `Application.get_env(:faber, :llm, ...)` inside `Faber.LLM.impl/0` returns the configured module, but `:faber` application env is only loaded if `mix app.config` (or `Application.ensure_all_started/1`) has run. The task never calls `Mix.Task.run("app.config")` or `Application.ensure_all_started(:faber)`, so config-driven env keys (`:llm`, `:claude_bin`, `:eval_threshold`, etc.) may not resolve correctly in all environments.
- **Fix**:
  ```elixir
  def run(argv) do
    {opts, _argv, _invalid} = OptionParser.parse(argv, strict: @switches)
    Mix.Task.run("app.config")
    Application.ensure_all_started(:req_llm)
    # rest unchanged
  end
  ```
  If the task needs HTTP (`:req_llm` starts Finch), keep `ensure_all_started(:req_llm)`. Do NOT use `Mix.Task.run("app.start")` — that would bind the Phoenix endpoint port and start the full tree unnecessarily.

---

### [Sidecar System.cmd #custom] Exit code ignored in `Faber.Sidecar.System.run/4`

- **File**: `lib/faber/sidecar/system.ex:31-35`
- **Code**: `{out, _code} = System.cmd(python, ["-m", "faber_eval", command, "--input", tmp], ...)`
- **Confidence**: DEFINITE
- **Issue**: The Python sidecar exit code is silently discarded (`_code`). If `python3` exits non-zero (import error, crash, bad command), `out` is empty or a traceback, and `Jason.decode(out)` returns `{:error, _}` which is surfaced as `{:sidecar_bad_output, out}`. That is _not_ silent — it does propagate. However, a non-zero exit with no JSON output that happens to be valid JSON (e.g., the sidecar prints partial JSON and then crashes mid-write) would be incorrectly accepted. More practically: a zero-exit with a warning on stdout plus the real JSON would also work. The defensive fix is to match on exit code first.
- **Fix**:
  ```elixir
  defp run(python, command, tmp, dir) do
    case System.cmd(python, ["-m", "faber_eval", command, "--input", tmp],
           cd: dir,
           stderr_to_stdout: false
         ) do
      {out, 0} ->
        case Jason.decode(out) do
          {:ok, map} -> {:ok, map}
          {:error, _} -> {:error, {:sidecar_bad_output, out}}
        end

      {out, code} ->
        {:error, {:sidecar_exit, code, out}}
    end
  rescue
    e in [ErlangError, File.Error] -> {:error, {:sidecar_unavailable, e}}
  end
  ```

---

## Medium Violations

### [LiveView #11] `handle_event("rescan", ...)` has no authorization check

- **File**: `lib/faber_web/live/dashboard_live.ex:23`
- **Code**: `def handle_event("rescan", _params, socket), do: {:noreply, load(socket)}`
- **Confidence**: REVIEW
- **Issue**: The `rescan` event triggers `Faber.Scan.run/1` which fans out `Task.async_stream` over potentially thousands of transcript files. There is no `current_user` or authentication guard — any connected WebSocket client can trigger unbounded filesystem work. This is a local-first tool, so the risk is low in practice, but if the endpoint is ever exposed (even on localhost with Tailscale), an unauthenticated client can cause repeated full scans.
- **Fix**: Add an admin check or at minimum a rate guard. Since this is a local tool, the minimal fix is a debounce or `connected?(socket)` confirmation (already done in mount) combined with a note that the endpoint should not be publicly exposed. If auth is added later, re-authorize here.

---

## Notes (Not Violations)

- **`GenServer.start_link` in `Faber.Loop.Server`** — CLEAN. The call is at line 20 inside `start_link/1` which is registered as a `DynamicSupervisor` child via `Faber.Loop.Supervisor`. `Faber.Loop.Supervisor` is in the application children list in `Faber.Application`. Supervision tree is correct.
- **`System.cmd` in `Faber.LLM.ClaudeCLI`** — CLEAN. Exit code is matched (`{out, 0}` vs `{out, code}`) and ErlangError is rescued. No user-controlled interpolation.
- **`System.cmd` in `Faber.Loop.Git`** — CLEAN. Same pattern: exit code matched, rescue on ErlangError.
- **`File.stream!` in `Faber.Ingest`** — CLEAN. Called inside a function body, not at module level, so `@external_resource` is not required (Iron Law #15 only applies to compile-time reads).
- **`String.to_atom` absent** — CLEAN. `Faber.Ingest` explicitly decodes JSON with `keys: :strings` and documents this as an Iron Law guard. No dynamic atom creation found anywhere.
- **`raw/1` absent** — CLEAN. Dashboard template uses HEEx interpolation (`{...}`) only.
- **`connected?` guard in `DashboardLive.mount`** — CLEAN. Disconnected branch returns empty assigns; scan only runs on connect.
- **No Oban workers** — N/A. No Oban dependency found; Oban iron laws do not apply.
- **No Ecto schemas** — N/A. No DB layer; money/float and query laws do not apply.
- **`faber.scan` Mix task** — CLEAN. Does not start the application at all (documented intent); reads only filesystem, no OTP services needed.
- **`faber.propose` Mix task `Application.ensure_all_started(:req_llm)`** — starts a dependency, not the full Faber app. Flagged above under High Violations for missing `app.config`.

Checked 19 of 26 Iron Laws: 3 violations found (0 critical BLOCKER, 2 high WARNING, 1 medium SUGGESTION).
