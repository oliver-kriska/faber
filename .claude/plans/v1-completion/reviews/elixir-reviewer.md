# Code Review: Faber v1 Completion (F3–F7)

## Summary
- **Status**: ⚠️ Changes Requested
- **Issues Found**: 7 (1 BLOCKER, 3 WARNING, 3 SUGGESTION)

---

## BLOCKER

### 1. `dashboard_live.ex:49` — `String.to_integer/1` on untrusted user input without rescue

```elixir
# Current
case Enum.at(socket.assigns.results, String.to_integer(i) - 1) do

# Suggested
case Integer.parse(i) do
  {idx, ""} -> case Enum.at(socket.assigns.results, idx - 1) do ...
  _ -> {:noreply, socket}
end
```

`String.to_integer/1` raises `ArgumentError` on any non-integer string (e.g., `""`
or crafted phx-value). A LiveView `handle_event` crash kills the socket process. The
`phx-value-i={i}` is rendered by the server but every phx-value is a user-controlled
string at the wire level — never assume format. Use `Integer.parse/1` and pattern-match
the `{int, ""}` tuple.

---

## WARNINGS

### 2. `schedule.ex:161–166` — `Task.async` + bare `rescue` inside a `GenServer`

```elixir
# Current
task = Task.async(fn ->
  try do
    run_once(job_opts)
  rescue
    e -> %{scanned: 0, proposals: [], error: Exception.message(e)}
  end
end)
```

`Task.async` links the task to the caller (the GenServer). If `run_once` raises BEFORE
the rescue (e.g., a `throw` or `:exit`), the GenServer dies too. The comment says "The
job Task is trapped to never crash the scheduler", but the GenServer does not call
`Process.flag(:trap_exit, true)`. Fix: use `Task.Supervisor.async_nolink` under a
`Task.Supervisor` child (add one to the supervision tree), or call
`Process.flag(:trap_exit, true)` in `init/1`. With `async_nolink` the task result
message shape changes — use `Task.yield/2` or match the `{ref, result}` msg correctly.
The current rescue only catches exceptions; exits/throws bypass it and will crash the
scheduler GenServer.

### 3. `eval.ex:139–151` — `String.to_existing_atom/1` inside rescue silently drops unknown param keys

```elixir
defp safe_atom(k) when is_binary(k) do
  String.to_existing_atom(k)
rescue
  ArgumentError -> k
end
```

The fallback returns the string `k`, meaning the matcher receives a string-keyed param
when an atom was expected. Depending on the matcher's internal `Map.get(params, :key)`,
this silently produces `nil` instead of the configured value — the check passes vacuously.
Not a crash, but a silent misconfiguration. Add a log warning on the rescue branch so
unknown keys are observable:

```elixir
rescue
  ArgumentError ->
    Logger.warning("eval: unknown param key #{inspect(k)} in adapter YAML — ignored")
    k
end
```

### 4. `loop.ex:98–105` — `cond` over struct fields is fine, but the termination `finish/2` reverses history unconditionally even when already reversed

```elixir
defp finish(state, status), do: %{state | status: status, history: Enum.reverse(state.history)}
```

`finish/2` is only called from `loop/1`, which is only entered once per termination, so
this is safe. However, if `run/1` is ever called with a pre-populated `:history` in opts
(the init path), those entries will also be reversed. Low risk but a hidden assumption.
Document or guard: `history` must always be `[]` on entry to `run/1`.

---

## SUGGESTIONS

### 5. `template.ex:32–39` — section renderer doesn't recurse into nested sections before rendering vars

The `render/2` pipeline runs `render_sections` then `render_vars` on the whole template.
For a list section, the inner block is rendered recursively via `render(inner, scope)`,
which is correct. But `render_sections` is called top-down, meaning an outer section's
inner content gets its vars rendered by the outer `render_vars` pass AFTER sections
complete. This is actually correct because the recursive `render` call handles both
sections and vars for inner content. No bug, but worth a comment explaining why the
two-pass order (`render_sections` then `render_vars` globally) is safe.

### 6. `propose.ex:139–143` — `render_skill_md/2` falls back to `render_skill_md/1` silently when no `"skill"` template

```elixir
def render_skill_md(%Proposal{} = p, %Adapter{templates: templates}) do
  case Map.get(templates, "skill") do
    tmpl when is_binary(tmpl) -> Template.render(tmpl, template_context(p))
    _ -> render_skill_md(p)
  end
end
```

The fallback is intentional and documented. However the `_` branch matches both `nil`
(no template) and a non-binary value (e.g. a mis-parsed template manifest). A corrupted
template manifest would silently produce the built-in rendering rather than an error.
Consider matching only `nil` explicitly:

```elixir
nil -> render_skill_md(p)
other -> raise "adapter template 'skill' has unexpected type: #{inspect(other)}"
```

### 7. `install.ex:25` — `render_skill_md/1` called without adapter even when proposal carries one

```elixir
def install(%Proposal{} = p, opts) do
  install({p.name, Propose.render_skill_md(p)}, opts)
end
```

`%Proposal{}` has no `:adapter` struct field (it carries `:adapter` as a string name,
not the loaded `%Adapter{}`), so the adapter templates can't be used here without
passing it via opts. The caller (`Schedule.maybe_install`) doesn't pass the adapter
either. This means installed skills always use the built-in renderer, ignoring the
adapter's `templates/` scaffold. For consistency with `Eval.score` (which accepts
`:adapter` in opts), consider accepting `:adapter` in `Install.install/2` opts and
forwarding it to `render_skill_md/2`.
