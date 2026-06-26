# Code Review: 874ee99 HEAD (propose/install/mcp)

## Summary
- **Status**: ✅ Approved (with suggestions)
- **Issues Found**: 4 (0 blockers, 1 warning, 3 suggestions)

---

## Warnings

### 1. `lib/faber/install.ex:264` — Interpolated atom in Regex pattern (frontmatter/2)

```elixir
# Current — field is always an internal atom-derived string ("name"/"description"),
# but the pattern is built via string interpolation, which Regex compiles at runtime
# (no compile-time caching). Minor, but if a caller passes user-supplied field names
# this would be a ReDoS surface.
~r/^#{field}:\s*"?(.+?)"?\s*$/m
```

Field is controlled (always `"name"` or `"description"` in practice), so not a security issue today, but the dynamic compile discards the ~r sigil's compile-time optimisation. SUGGESTION at this call frequency, WARNING if `frontmatter/2` becomes public.

**Fix:** Define two module-level `@name_re`/`@desc_re`, or accept a pre-compiled regex parameter.

---

## Suggestions

### 2. `lib/faber/propose.ex:159-163` — Dual-arity `render_skill_md` dispatch is subtle

The two-arity and one-arity `render_skill_md` have the same doc-visible name. The two-arity calls `render_skill_md(p)` (the one-arity) internally, but from the call site in `install.ex` the fallback path is invisible. This is fine Elixir — two separate `@spec` + `@doc` entries — but the one-arity overload is public (`@spec` + `@doc`) while it is purely an internal rendering detail.

**Fix (optional):** Make the built-in renderer `defp render_builtin/1` and have the two-arity call it. Removes the public two-arity ambiguity and makes the decision tree explicit.

### 3. `lib/faber/install.ex:67-76` — Nested `with` inside an `if`

```elixir
if File.exists?(path) and not Keyword.get(opts, :force, false) do
  {:error, {:exists, path}}
else
  with :ok <- File.mkdir_p(skill_dir),
       :ok <- File.write(path, skill_md),
       :ok <- write_marker(skill_dir, name, opts) do
    {:ok, path}
  end
end
```

The outer `with :ok <- validate_name(name)` already establishes a `with` chain. Flattening would reduce nesting and make the full happy-path more readable:

```elixir
with :ok <- validate_name(name),
     :ok <- guard_exists(path, opts),
     :ok <- File.mkdir_p(skill_dir),
     :ok <- File.write(path, skill_md),
     :ok <- write_marker(skill_dir, name, opts) do
  {:ok, path}
end

defp guard_exists(path, opts) do
  if File.exists?(path) and not Keyword.get(opts, :force, false),
    do: {:error, {:exists, path}},
    else: :ok
end
```

### 4. `lib/faber/propose.ex:260-267` — `present/1` returns the raw (untrimmed) value after checking trim

```elixir
defp present(s) when is_binary(s) do
  case String.trim(s) do
    "" -> nil
    _ -> s      # returns the original s, not the trimmed version
  end
end
```

This is intentional (preserving original whitespace for the example block), but could silently pass a string that is all-whitespace if the caller does not trim. The usage in `usage_block/1` concatenates it directly into a fenced code block, so leading/trailing whitespace on `usage` or `example` would appear inside the fence. Low risk but slightly surprising. If trimming the result is acceptable, `_ -> String.trim(s)` is cleaner.

---

## Pre-existing (unchanged files, one-liners only)

- No pre-existing issues observed in the unchanged surfaces touched by the diff.
