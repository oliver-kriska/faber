# Code Review: deferred-features (06248b5^..HEAD)

## Summary
- **Status**: ⚠️ Changes Requested
- **Issues Found**: 4 (0 BLOCKER, 3 WARNING, 1 SUGGESTION)

---

## Warnings

### 1. `File.read!` in `Install.skill_summary/1` — uncaught crash in `list_installed/1`
**`lib/faber/install.ex:193`**

`File.read!(path)` inside `skill_summary/1` is called from `list_installed/1`, which is in turn called
from the MCP tool handlers on every request. If a `SKILL.md` is deleted between `Path.wildcard/1`
discovering it and the `Enum.map/2` reading it (TOCTOU), the bang raises and brings down the MCP
tool's request process — not catastrophic (Anubis likely catches it), but it surfaces as an opaque 500
rather than a clean `{:error, reason}`. Same issue in `check_pointer/2` and `install_pointer/3` at
lines 153 and 173, though those are more forgiving (operating on user-owned files, not discovered ones).

```elixir
# Current (lib/faber/install.ex:193-199)
defp skill_summary(path) do
  content = File.read!(path)
  ...
end

# Suggested — soft-degrade missing files
defp skill_summary(path) do
  case File.read(path) do
    {:ok, content} ->
      %{
        name: frontmatter(content, "name") || Path.basename(Path.dirname(path)),
        description: frontmatter(content, "description") || "",
        path: path
      }
    {:error, _} ->
      nil
  end
end
# then in list_installed/1: |> Enum.reject(&is_nil/1)
```

---

### 2. `@version Mix.Project.config()[:version]` baked into `Faber.MCP.Server` at compile time
**`lib/faber/mcp/server.ex:23`**

`Mix.Project.config()` is available at compile time in `mix` context but is **not** available inside
a compiled release (`Mix` is not included). The module attribute is evaluated at compile time, so this
is safe for the attribute assignment itself — the value is baked in during `mix compile`. However,
the pattern is fragile: it silently returns `nil` if the module is recompiled outside a Mix project
context (unlikely in practice, but violates the "verify before claiming" principle). The safer
canonical approach is `Application.spec(:faber, :vsn)` at runtime (as already done in `Faber.CLI.version/0`).

```elixir
# Current
@version Mix.Project.config()[:version]

# Suggested — consistent with CLI.version/0, works in releases without mix
@version Application.spec(:faber, :vsn) |> List.to_string()
# Or if the macro requires a compile-time string, use Mix.Project.config() but add a fallback:
@version (Mix.Project.config()[:version] || "0.0.0")
```

Note: This is not a crash in practice (baked in at compile time by Mix), but creates a maintenance
inconsistency vs the CLI path.

---

### 3. `spawn/1` in `Faber.CLI.dispatch/1` — unsupervised, crashes are silent
**`lib/faber/cli.ex:115`**

```elixir
def dispatch({command, opts}) do
  spawn(fn -> System.halt(run(command, opts)) end)
  :ok
end
```

The spawned process is unsupervised and has no link to the caller. If `run/2` raises (which is
possible — e.g. `Scan.run/1` or `Propose.propose/2` could crash on unexpected data), the exception
is logged to stderr by the runtime but `System.halt/1` is never called, leaving the release VM
running indefinitely with no way to exit. The intent is for `run/2` to handle its own errors (it
returns `0`/`1`), but a crash bypasses that.

```elixir
# Suggested — wrap in try/rescue or link with a monitor
def dispatch({command, opts}) do
  spawn(fn ->
    exit_code =
      try do
        run(command, opts)
      rescue
        e ->
          IO.puts(:stderr, "faber: unexpected crash: #{Exception.message(e)}")
          1
      end

    System.halt(exit_code)
  end)

  :ok
end
```

---

## Suggestions

### 4. `GetSkill.execute/2` — `File.read!` after `list_installed/1` lookup (minor TOCTOU)
**`lib/faber/mcp/tools/get_skill.ex:24-25`**

The skill is verified to exist via `list_installed/1`, then read with `File.read!/1`. If the file
disappears in the narrow window between the two calls, the bang raises and the MCP request crashes.
Given this is a localhost single-user tool the race is theoretical, but using `File.read/1` with a
pattern match would make the error surface cleanly as an MCP error response instead.

```elixir
# Current
{:reply, Response.text(Response.tool(), File.read!(path)), frame}

# Suggested
case File.read(path) do
  {:ok, content} ->
    {:reply, Response.text(Response.tool(), content), frame}
  {:error, reason} ->
    {:reply, Response.error(Response.tool(), "Could not read skill: #{reason}"), frame}
end
```

---

## Notes (pre-existing, not re-analyzed)

- `Faber.Install.install/2`: The nested `with` inside the outer `with` (lines 44-55) works but a
  flat `with` would be marginally cleaner. Pre-existing style, not a new issue.
- `claude_cli.ex` stdin fix (`sh -c … < /dev/null` via env-var quoting) is correct: all dynamic
  content goes through env vars, no word-splitting risk.
- `ManagedBlock` is fully pure (no I/O) — well-structured and unit-testable as designed.
- Privacy boundary in `SearchFriction.summarize/1` (explicit allowlist map, no raw text) is correctly
  implemented.
- Router: `/mcp` forwarded outside the `:browser` pipeline — correct (no CSRF/HTML needed for JSON-RPC).
- `web_children/1` conditional start (MCP + endpoint only for `nil` and `{:serve, _}`) is correct OTP
  usage; the comment is accurate.
