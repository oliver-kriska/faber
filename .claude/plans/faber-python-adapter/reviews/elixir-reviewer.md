# Code Review: faber-python adapter — Elixir engine modules

## Summary
- **Status**: ✅ Approved (with one WARNING to address)
- **Issues Found**: 1 warning, 3 suggestions

---

## Warnings

### 1. `opportunity_match?` guard uses `Map.get` on a struct — opaque field access inconsistency (`detect.ex:354`)

```elixir
# Current
guard_ok = not (Map.get(rule, :unless_used, true) and used?(used, skill))
```

`rule` here is a plain `%{}` map (built by `opportunity_rule/1` in `adapter.ex`), so `Map.get` is correct. However, the accessor functions at lines 568–574 also use `Map.get/3` on an `%Adapter{}` struct:

```elixir
defp fingerprint_rules(adapter), do: Map.get(adapter, :fingerprint_rules) || []
defp opportunity_rules(adapter), do: Map.get(adapter, :opportunity_rules) || []
defp skill_namespaces(adapter), do: Map.get(adapter, :skill_namespaces) || []
```

These work but are inconsistent with Elixir struct idiom — struct field access via `Map.get/3` obscures the fact that these are known, typed fields. More critically: if `adapter.fingerprint_rules` were legitimately `[]` (an adapter that declares "no rules"), the `|| []` fallback silently hides it (returns `[]` either way). This is benign here since `[]` and `|| []` collapse to the same value, but the pattern is subtly wrong for the nil-vs-empty distinction the rest of the code carefully maintains. The `nil` clause is handled by the separate pattern-matched function head (`fingerprint_rules(nil)`) so the `|| []` fallback is only reached for a non-nil adapter.

**Suggested fix** — use direct struct field access and drop the fallback:

```elixir
defp fingerprint_rules(%Faber.Adapter{fingerprint_rules: rules}), do: rules
defp opportunity_rules(%Faber.Adapter{opportunity_rules: rules}), do: rules
defp skill_namespaces(%Faber.Adapter{skill_namespaces: ns}), do: ns
```

This makes the compiler's set-theoretic checker (1.20+) aware of the pattern and removes the silent `|| []` that masks a type-level distinction the struct already enforces. The nil-head clause stays unchanged.

---

## Suggestions

### 1. `skill_namespace_regex/1` built per-call — consider a note (not a bug) (`detect.ex:579–582`)

The regex is compiled on every `used_skills/2` call. For the `nil`-adapter path the three-namespace list is constant, so this compiles the same regex repeatedly. The compile cost for a 3-element alternation is negligible in practice. However, for the hot path (scan over many sessions), a module attribute (`@default_skill_namespace_regex`) for the default case would avoid the repeated compile. Not a correctness issue — SUGGESTION only.

### 2. Tie-break on novel fingerprint types is sorted lexicographically — document the semantic (`detect.ex:286–292`)

```elixir
extra = (Map.keys(scores) -- @fingerprint_order) |> Enum.sort()
```

Novel adapter types sort lexicographically. This is deterministic and clearly correct, but the rule is slightly different from the built-in type tie-break (which preserves `@fingerprint_order` insertion order for Python parity). A one-line comment clarifying "novel types: first alphabetically; built-in types: canonical order" would save the next reader from having to rediscover the two different tie-break semantics.

### 3. `investigate_opportunity?/1` uses `Enum.reduce_while` returning `true | integer` then `case` to normalise — slightly indirect (`detect.ex:504–518`)

```elixir
|> case do
  true -> true
  _ -> false
end
```

This works correctly. A mild simplification:

```elixir
|> then(&(&1 == true))
```

or just restructure `reduce_while` to return `{:halt, true}` / `{:cont, false}` and `|> then(& &1)`. Neither changes behaviour; purely readability at the tail.

---

## Analysis of Specific Design Points

### `Map.update` vs `Map.update!` for novel fingerprint types (`detect.ex:302`)

**Correct choice.** `Map.update/4` is used precisely because an adapter-supplied fingerprint type (e.g. `"data-migration"`) won't be in `@fingerprint_keywords` and thus won't have a pre-initialized key in `scores`. `Map.update!` would crash on a novel key. `Map.update/4` creates the key with `amount` as the initial value, which is equivalent to the Python `dict.get(k, 0) + amount` pattern. The comment in the source correctly documents this.

Contrast with `bonus/4` at line 559 which uses `Map.update!` — safe there because `bonus/4` is only called with hardcoded built-in types that are always in `scores`.

### Deterministic tie-break for novel types (`detect.ex:286–292`)

Correct. `@fingerprint_order ++ extra` means built-in types (in canonical order) always outrank novel types on identical scores, and novel types among themselves break ties alphabetically. `Enum.max_by` with a single scalar comparator is stable under Elixir's `>=` (returns the LAST max on ties), but since the input is a full ordered list and only one winner is taken, the ordering provides full determinism. No issue.

### `unless_used` guard semantics (`detect.ex:353–355`)

```elixir
guard_ok = not (Map.get(rule, :unless_used, true) and used?(used, skill))
```

Semantics: when `unless_used: true` (default), the rule is **blocked** if the skill is already used. When `unless_used: false`, the rule always fires regardless of usage. This matches the documented intent. The `Map.get` default of `true` is consistent with `opportunity_rule/1` in `adapter.ex` which also defaults `unless_used` to `true`. Correct.

One mild concern: for the `investigate` rule in `@default_opportunity_rules`, `unless_used: false` means it fires **even when `investigate` has been used**. That is the explicit design intent ("investigate: suggests even when already used"). Correct and documented.

### Nil-adapter parity path

Both `fingerprint/2` and `opportunity/2` have `\\ nil` defaults and route nil to the engine defaults via pattern-matched function heads. The parity test at `detect_test.exs:288–317` covers all five rule types across nine probe sessions. The nil path is not reachable through `fingerprint_rules(adapter)` / etc. when adapter is non-nil — the `|| []` fallback applies only there. No regression risk in the nil path.

### `read_detect/1` in `adapter.ex` — `list_under` for `skill_namespaces` (`adapter.ex:367–376`)

`skill_namespaces` is listed under a YAML key, so it goes through `list_under/2` which returns `[]` on missing/non-list. That matches the struct default. No issue — correctly handles absent `detect/signatures.yaml`.

### `atomize_when/1` passthrough for unknown values (`adapter.ex:249`)

```elixir
defp atomize_when(other), do: other
```

Unknown `when:` values become strings. `opportunity_problems/1` then catches them via `w in @opportunity_whens` (which checks the atom set), reporting a validation error. The validation fires at load time, so invalid adapters are rejected before reaching `rule_triggered?/2`. The catchall `defp rule_triggered?(_rule, _ctx), do: false` at line 370 provides a runtime safety net. Correct layering.
