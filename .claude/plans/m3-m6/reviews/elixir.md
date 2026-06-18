# Code Review: M3–M6 Elixir modules

## Summary
- **Status**: ⚠️ Changes Requested
- **Issues Found**: 9 (1 BLOCKER, 5 WARNING, 3 SUGGESTION)

---

## BLOCKER

### 1. `lib/faber/loop.ex:249` — `refine/3` crashes on propose failure (unchecked `{:ok, seed}`)

```elixir
# Current — raises MatchError when LLM call fails
{:ok, seed} = Propose.propose(result, adapter, opts)

# Suggested
case Propose.propose(result, adapter, opts) do
  {:ok, seed} ->
    content = Propose.render_skill_md(seed)
    run(Keyword.merge(opts, skill: seed.name, content: content, ...))
  {:error, _} = err ->
    err
end
```

`refine/3` is the public API for the loop. A network hiccup, missing key, or
ClaudeCLI exit code ≠ 0 returns `{:error, _}` from `Propose.propose/3`, which
hits the bare destructure and raises `MatchError`. The crash propagates to the
`Loop.Server` GenServer (crashes the process), but the outer call site (e.g.
`mix faber.propose`) has no guard either. Both the server path and any direct
`refine/3` call site need the tagged-tuple respected.

---

## WARNINGS

### 2. `lib/faber/sidecar/system.ex:33–34` — non-zero exit code from Python silently ignored

```elixir
# Current — _code discards exit status; garbage output treated as decode error
{out, _code} = System.cmd(python, [...])
case Jason.decode(out) do
  ...
  {:error, _} -> {:error, {:sidecar_bad_output, out}}
end
```

If `python3` exits non-zero (syntax error, import failure, missing module),
`out` may be an empty string or a traceback; `Jason.decode` fails and the error
reason is `{:sidecar_bad_output, <traceback>}` — losing the exit code and
making diagnostics hard. Pattern-match the exit code:

```elixir
case System.cmd(python, [...]) do
  {out, 0} -> Jason.decode(out) |> then(&...)
  {out, code} -> {:error, {:sidecar_exit, code, out}}
end
```

### 3. `lib/faber/loop/journal.ex:51–52` — `Jason.decode!/1` in `read/1` crashes on corrupt JSONL

```elixir
# Current — one bad line raises and bubbles out of read/1
|> Enum.map(&Jason.decode!/1)
```

The journal is append-only and written incrementally; a partial write or
truncated line during a crash will cause `read/1` to raise on the next run.
Use the safe variant:

```elixir
|> Enum.flat_map(fn line ->
  case Jason.decode(line) do
    {:ok, entry} -> [entry]
    {:error, _} -> []   # skip corrupt lines; optionally log
  end
end)
```

### 4. `lib/faber/loop.ex:95–100` — `loop/1` is a plain recursive call; tail-call but no process boundary

`loop/1` calls itself synchronously from inside `handle_continue`. This means
the GenServer process is blocked for the entire run (which could be 50
iterations of LLM calls — potentially hours). During that time:

- Any `GenServer.call(:status)` blocks until the loop finishes because the
  process mailbox is unprocessed.
- `await/2` with a short timeout will always time out.

The `await/2` spec (`timeout \\ 60_000`) is already mismatched: 50 iterations
of LLM calls will far exceed 60 s. Consider running the loop in a `Task` so
the GenServer remains responsive, or document clearly that `:status` returns
`:running` only if called before `handle_continue` completes (which is
impossible since `handle_continue` runs before the process can receive other
messages).

### 5. `lib/faber/loop/git.ex:13–14` — `git add` path list is unsafe for unusual filenames

```elixir
git(dir, ["add" | paths])
```

`System.cmd/3` with a list avoids shell injection (good), but if `paths` is
empty the command becomes `git add` with no arguments, which stages everything
in the repo — not just the skill path. Add a guard:

```elixir
def commit(_dir, [], _message), do: :ok  # nothing to stage
def commit(dir, paths, message) do
  with {:ok, _} <- git(dir, ["add" | paths]),
       ...
```

### 6. `lib/faber/propose.ex:111` — `_adapter` param discards the adapter in `user_prompt/2`

```elixir
defp user_prompt(%Scan.Result{} = r, %Adapter{}) do
```

The `Adapter` is silently discarded. The moduledoc says the adapter's
conventions are woven into the prompt, but the user prompt currently contains
no adapter-specific context (stack name, version, playbook references). If this
is intentional (stack context lives only in the system prompt), rename the
param to `_adapter` explicitly and add a comment; otherwise wire in
`adapter.name` and relevant context so the user prompt is also adapter-aware.

---

## SUGGESTIONS

### 7. `lib/faber/eval.ex:53–57` — `engine/1` uses `cond` for a two-branch choice

```elixir
# Current
cond do
  opts[:sidecar] -> :sidecar
  true -> opts[:engine] || Application.get_env(:faber, :eval_engine, :native)
end
```

A `cond` with one real branch and a catch-all reads as an `if`. Prefer:

```elixir
if opts[:sidecar] do
  :sidecar
else
  opts[:engine] || Application.get_env(:faber, :eval_engine, :native)
end
```

### 8. `lib/faber/loop.ex:175–186` — `revert/5` and `discard/5` are identical

Both functions update `consecutive_discards` the same way, produce the same
entry, and call `restore/1`. The only semantic difference is the caller's
intent (a "no improvement" reject vs. a "checks/eval failed" abandon). Consider
merging into a single `reject/5` and passing a `:revert | :discard` reason
atom, or at least add a comment justifying the intentional duplication.

### 9. `lib/mix/tasks/faber.propose.ex:43` — `Application.ensure_all_started(:req_llm)` without `app.config`

```elixir
# Current
Application.ensure_all_started(:req_llm)
```

The mix task does not call `Mix.Task.run("app.config")` first, so `:faber`
application config may not be loaded when `Faber.LLM.impl/0` reads
`Application.get_env(:faber, :llm, ...)`. In practice `mix` loads config
before tasks, so this usually works — but the Iron Law says to be explicit:
call `Mix.Task.run("app.config")` before `ensure_all_started` so the task is
safe in all mix environments (including `MIX_ENV=prod` one-off scripts).
