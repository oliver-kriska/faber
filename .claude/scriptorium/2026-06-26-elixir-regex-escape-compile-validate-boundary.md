---
scriptorium: true
action: create
title: "Elixir Regex.escape'd strings don't fail compile; guard non-binaries and validate packs at load"
type: solution
domain: claude-elixir-phoenix
tags: [elixir, regex, security, validation, untrusted-input, load-boundary, ReDoS, gotcha]
---

# Elixir Regex.escape'd strings don't fail compile; validate untrusted packs at the load boundary

Found addressing a security-review finding on Faber's adapter packs (untrusted declarative input
turned into regexes). Two reusable takeaways for any Elixir code building regexes from user/pack data.

## The empirical gotcha (verify before "fixing")

A reviewer flagged `Regex.compile!` built from user-supplied strings as a crash vector on malformed
UTF-8 / NUL. **It doesn't reproduce** once `Regex.escape/1` is applied, in Elixir's default regex mode:

```elixir
Regex.compile(Regex.escape(<<0xFF, 0xFE>>))  #=> {:ok, ~r/\xFF\xFE/}
Regex.compile(Regex.escape(<<0>>))           #=> {:ok, ~r/\0/}
```

`Regex.escape` neutralizes every metachar, and without the `u` flag PCRE doesn't reject these bytes.
So an escaped *string* alternation is effectively always compilable. **Reproduce a flagged crash
before fixing it** — a plausible Medium can be empirically false for the actual input shape.

## The REAL edge

`Regex.escape/1` **raises on non-binaries**. If YAML/config yields `["py", 42]`, the failure isn't at
`compile` — it's `Regex.escape(42)` raising `FunctionClauseError` first. Guard with `is_binary/1`.

## The fix (defense at both ends)

```elixir
# Load boundary (validate/1): reject non-compilable entries once, early.
defp regex_safe?(s) when is_binary(s), do: match?({:ok, _}, Regex.compile(Regex.escape(s)))
defp regex_safe?(_), do: false

# Runtime: can't raise even if an in-memory struct bypassed validation.
namespaces
|> Enum.filter(&is_binary/1)
|> Enum.map_join("|", &Regex.escape/1)
|> case do
  "" -> ~r/(?!)/                                  # fail closed: never-match
  alt -> case Regex.compile("(?:#{alt}):…", "i") do
           {:ok, re} -> re
           {:error, _} -> ~r/(?!)/
         end
end
```

## Principles

- **Validate untrusted declarative input at the `load/1` boundary**, so bad packs fail once and
  early — not as a raise deep in a hot path. Keep a fail-closed runtime guard for the in-memory bypass.
- `Regex.escape/1` is safe against injection but **raises on non-binaries** — `is_binary/1` first.
- Escaped alternations (`(?:a|b):…`, no nested quantifier) aren't ReDoS-catastrophic; cap list
  length only if input arrives over a network rather than as local trusted files.
- `~r/(?!)/` is the idiomatic never-match regex for fail-closed degradation.

Relates to the Faber Iron Law "no dynamic atom creation on untrusted input" — same instinct (treat
pack/user data as hostile at the boundary), different primitive.
