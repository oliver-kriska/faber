# Code Review: M3–M6 Fix Pass Re-Review

## Summary
- **Status**: ✅ Approved
- **Issues Found**: 2 minor (1 WARNING, 1 SUGGESTION) — no regressions, no new BLOCKERs

All five original BLOCKERs and nine WARNINGs are correctly implemented. The control-flow wiring
is sound. No regressions introduced by the fixes.

---

## Fix-by-Fix Verdict

### BL1 — Loop.Server Task wiring (`lib/faber/loop/server.ex`)

Correct and idiomatic.

- `Task.async/1` in `handle_continue(:run, …)` — Task is linked to the GenServer, so a loop
  crash propagates and the `:temporary` restart strategy leaves the server down. Intended.
- `handle_info({ref, result}, %{task: %Task{ref: ref}} = state)` — pattern-matches the ref
  correctly; `Process.demonitor(ref, [:flush])` drains the `:DOWN` before it can hit the
  catch-all. Correct.
- `handle_call(:await, from, %{result: nil})` parks without replying (`{:noreply, …}`); replied
  from `handle_info`. Correct — the GenServer is never itself blocked.
- `handle_call(:await, _from, %{result: r})` when result is already present returns immediately.
  Correct.
- Catch-all `handle_info(_msg, state)` prevents spurious unhandled-message logs. Correct.
- `@spec await/2` says `{:ok, Loop.State.t()}` but `handle_call(:await)` wraps with `{:ok, result}`
  where `result` is whatever `Loop.run/1` returns — a `%State{}`. Matches.

One subtlety to note (not a bug): `Task.async/1` sends `{ref, result}` only on normal exit; an
abnormal Task exit (exception inside the loop) sends `{:DOWN, ref, :process, pid, reason}` and
then kills the server via the link. The `_msg` catch-all never fires for crashes — waiters are
never replied to in that path. This is the stated design ("crash-isolation"), so it's correct, but
callers using `await/2` will receive a `{:noreply, …}` park and then their own process will exit
when the server dies (GenServer.call raises on server death). Acceptable for the use-case.

### BL2 — DashboardLive async scan (`lib/faber_web/live/dashboard_live.ex`)

Correct.

- `start_async(:scan, fn -> Scan.run(opts) end)` in connected mount and rescan. `handle_async/3`
  wired for `{:ok, results}` and `{:exit, _}`. Idiomatic LiveView 1.0 pattern.
- `:scanning` debounce: `handle_event("rescan", …, %{assigns: %{scanning: true}})` guard
  short-circuits correctly. Button also `disabled={@scanning}`.
- `scan_opts/0` extracted outside the socket closure — no closure-capture issue.
- `@shown` is pre-computed in `handle_async` (not `length(@results)` in the render template).

### BL3 — `refine/3` error propagation (`lib/faber/loop.ex`)

Correct.

- Initial `Propose.propose/3` call is now `case`d; `{:error, _}` returned directly.
- Extracted `run_refinement/4` is clean. The `propose_fn` inside `run_refinement` also wraps
  its `Propose.propose/3` in a `case`, so mid-loop proposal failures surface as `{:error, _}`
  tuples through `step/1` → `reject/5`. Fully wired.
- `@spec refine/3` updated to `State.t() | {:error, term()}`. Correct.

The `revert/5` + `discard/5` merge into `reject/5` (S3) is clean: a single private function
with a `desc`/`reason` pair, called from all rejection sites. The old semantic distinction
(revert = had a candidate, discard = never had one) is preserved through the `reason` string
passed to the journal entry. Behaviorally identical to the old split.

### W1 — Sidecar exit-code match (`lib/faber/sidecar/system.ex`)

Correct. `{out, 0}` / `{out, code}` pattern added. Comment explains the rationale.

### W2 — Git safe paths (`lib/faber/loop/git.ex`)

Correct, with one note.

`Path.safe_relative/2` was introduced in Elixir 1.15. `mix.exs` requires `~> 1.20`, so the
function is available. Behavior: returns `{:ok, rel}` for relative paths that stay within the
given base, `:error` for absolute paths, `..` escapes, and paths outside the base. For the
normal case `["SKILL.md"]` with any `dir`, `Path.safe_relative("SKILL.md", dir)` returns
`{:ok, "SKILL.md"}` — correct.

Leading-dash check (`String.starts_with?(p, "-")`) correctly rejects git flags before the
`safe_relative` call. Empty-list short-circuit at `commit(_dir, [], _msg)` and
`revert(_dir, [])` prevents bare `git add` staging the whole repo.

`"--"` separator before paths in `["add", "--" | safe]` and `["checkout", "--" | safe]` is
correct argv form.

### W3 — `faber.propose` app.config (`lib/mix/tasks/faber.propose.ex`)

Correct. `Mix.Task.run("app.config")` added before `Application.ensure_all_started(:req_llm)`.
Comment explains why not `app.start`. Idiomatic per Iron Law #10.

### W4 — Journal.read corrupt-line tolerance (`lib/faber/loop/journal.ex`)

Correct. `Enum.flat_map` + `Jason.decode/1` (tagged-tuple, not bang); `{:error, _}` lines
produce `[]`, good lines produce `[entry]`. Missing file still returns `[]`.

### W5 — File.write/2 in loop (`lib/faber/loop.ex`)

Correct. `File.write/2` used throughout; `write_candidate/2` returns `{:ok, …} | {:error, …}`,
threaded through `handle_candidate/4` → `reject/5` on failure.

`restore/1` also uses `File.write/2` with a `_ = ` discard — intentional best-effort.
Idiomatic.

### W6 — Proposer user_prompt adapter context (`lib/faber/propose.ex`)

Correct. `user_prompt/2` now pattern-matches `%Adapter{name: name, version: version}` and leads
with the stack name/version. Test should assert this (per plan).

### W7 — Temp file perms (`lib/faber/sidecar/system.ex`)

Correct. `File.open(path, [:write, :exclusive, :binary])` (O_EXCL semantics) + immediate
`File.chmod(path, 0o600)`. Random name via `:crypto.strong_rand_bytes(12) |> Base.url_encode64`.
`IO.binwrite/2` + `File.close/1` then `File.rm/1` in `after`.

Minor: `File.close/1` result is discarded (no `_ =`). In practice this is not a problem since
`IO.binwrite` errors would surface as `:error` and the path would still be cleaned up in
`after`. Style-only.

### S2 — Application.ex PubSub ordering (`lib/faber/application.ex`)

Correct. `Phoenix.PubSub` is listed first in the children list, before `Loop.Supervisor`.

### S3 — Eval.engine/1 cond→if (`lib/faber/eval.ex`)

Correct. `cond` with two branches replaced by `if/else`. Idiomatic.

### mix.exs — test.full alias + cli/0

Correct. `"test.full": ["test --include sidecar"]` alias and `def cli do [preferred_envs:
["test.full": :test]] end` both present. Note: `cli/0` is a module-level `def`, not inside
`project/0` — this is the correct top-level placement for Mix project CLI config.

---

## Warnings

### W1 — `propose/2` in Mix task has no `with` guard for its `info/1` side effect

**Location:** `lib/mix/tasks/faber.propose.ex:73-80`

```elixir
defp propose(result, adapter) do
  Mix.shell().info("Proposing for … via …\n")   # side effect before call
  Propose.propose(result, adapter)              # may return {:error, _}
end
```

The `info/1` prints before the LLM call, then the `with` in `run/1` catches `{:error, _}`.
This is not a crash — the `with/else` handles it. But the shell output says "Proposing for…"
even on a no-op dry-run, which is misleading if the propose immediately fails. This was
pre-existing behavior carried through the fix, not introduced by it.

Flag: pre-existing style issue, not introduced by the fix. Recorded for completeness.

---

## Suggestions

### S1 — `handle_async(:scan, {:ok, results})` calls `length/1` twice

**Location:** `lib/faber_web/live/dashboard_live.ex:37-45`

```elixir
|> assign(:total, length(results))
# ...
|> assign(:shown, min(25, length(results)))
```

`length(results)` is called twice on the same list. Trivial fix: bind once with a variable.
No correctness impact; the list is at most 400 items (scan `:limit`).

```elixir
total = length(results)
shown = min(25, total)
socket
|> assign(:total, total)
|> assign(:tier2, Enum.count(results, & &1.tier2))
|> assign(:results, Enum.take(results, 25))
|> assign(:shown, shown)
```
