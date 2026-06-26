---
module: "Faber.Adapter / Faber.Detect"
date: "2026-06-26"
problem_type: robustness
component: untrusted_pack_validation
symptoms:
  - "a security review flagged Regex.compile! built from adapter-supplied skill_namespaces/file_globs as a mid-scan crash vector on malformed input"
  - "validation only checked 'list of strings', not that the strings actually compile"
  - "the crash vector did not reproduce for escaped string input"
root_cause: "two separable issues: (a) Regex.escape'd STRING input does not actually fail Regex.compile in Elixir's default mode, so the feared crash was theoretical; (b) the REAL edge — a non-binary entry making Regex.escape/1 raise — was unguarded, and untrusted packs were validated downstream instead of at the load boundary"
severity: medium
tags: [elixir, regex, security, validation, untrusted-input, adapter, load-boundary, ReDoS]
---

# Validate untrusted declarative packs at the load boundary — and the Regex.escape/compile reality

## Symptoms

A security pass on adapter packs (the untrusted boundary) flagged `Regex.compile!("(?:#{alt}):…")`,
where `alt` is built from adapter-supplied `skill_namespaces` (and the analogous `glob_regex/1` for
`file_globs`), as a mid-scan crash / DoS: a malformed pack (invalid UTF-8 / NUL byte) would make
`compile!` **raise during a scan** instead of being rejected at load. Validation only asserted
"list of strings".

## Investigation

1. **Reproduce the claimed crash before fixing it.** Empirically, in Elixir's default regex mode:

   ```elixir
   Regex.compile(Regex.escape(<<0xFF, 0xFE>>))  #=> {:ok, ~r/\xFF\xFE/}
   Regex.compile(Regex.escape(<<0>>))           #=> {:ok, ~r/\0/}
   ```

   **`Regex.escape`'d string input does NOT fail `Regex.compile`** on malformed UTF-8 or NUL (PCRE
   isn't in unicode mode without the `u` flag, and escape neutralizes every metachar). So the
   crash vector was **theoretical for string namespaces** — escape already makes the joined pattern
   always-compilable.
2. **The real edge is a *non-binary* entry.** If YAML yields `["py", 42]`, the crash isn't at
   `compile` — it's `Regex.escape(42)` raising a `FunctionClauseError` before compile.
3. **Where to enforce.** Untrusted packs should fail at the `load/1` boundary, not deep in a scan.

## Root cause

Two separable things conflated under one "Medium": (a) the escaped-string crash doesn't exist;
(b) the non-binary edge was unguarded and validation happened downstream, not at load.

## Solution

Defense at both ends, matching the empirical reality:

```elixir
# Load boundary (Faber.Adapter.validate/1): reject packs that can't compile, at load.
defp regex_safe?(ns) when is_binary(ns), do: match?({:ok, _}, Regex.compile(Regex.escape(ns)))
defp regex_safe?(_), do: false                       # non-binary → rejected here

defp glob_compiles?(g) when is_binary(g) do
  glob_regex(g); true
rescue
  _ -> false
end
defp glob_compiles?(_), do: false

# Runtime (Faber.Detect.skill_namespace_regex/1): can't raise even on an in-memory adapter
# that bypassed validate/1 — filter non-binaries, fail closed to a never-match regex.
defp skill_namespace_regex(namespaces) do
  case namespaces |> Enum.filter(&is_binary/1) |> Enum.map_join("|", &Regex.escape/1) do
    "" -> ~r/(?!)/
    alt ->
      case Regex.compile("(?:#{alt}):([a-z][a-z0-9_-]*)", "i") do
        {:ok, re} -> re
        {:error, _} -> ~r/(?!)/
      end
  end
end
```

## Prevention

- **Reproduce a flagged crash vector before "fixing" it.** A plausible Medium ("compile! on
  malformed input raises") can be empirically false for the actual input shape. Fix the *real*
  edge (here, non-binary → `Regex.escape` raises), and say so in the commit rather than over-claiming.
- **Validate untrusted declarative input at the load boundary** (`load/1`), so bad packs fail once,
  early — not as a raise deep in a hot path. Keep a fail-closed runtime guard for the in-memory
  bypass.
- `Regex.escape/1` neutralizes metachars but **raises on non-binaries** — guard with `is_binary/1`
  before escaping adapter/user data.
- Escaped alternations (`(?:a|b):…`, no nested quantifier) aren't ReDoS-catastrophic; only cap
  list length if the packs ever arrive over a network rather than as local trusted files.

## Result

`Adapter.validate/1` rejects non-compilable `skill_namespaces`/`file_globs` at load;
`skill_namespace_regex/1` degrades gracefully at runtime. Tests cover both (load-time rejection of
`[123]`/`[456]`; runtime graceful handling of `["py", 42]`).
