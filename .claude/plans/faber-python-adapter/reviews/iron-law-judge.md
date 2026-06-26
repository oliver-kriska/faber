# Iron Law Violations Report

## Summary

- Files scanned: 4 (`lib/faber/adapter.ex`, `lib/faber/detect.ex`, `lib/faber/propose.ex`, `lib/faber/scan.ex`)
- Iron Laws checked: 13 of 26 (laws applicable to pure-functional Elixir modules; LiveView/Ecto/Oban/OTP supervision laws are not exercised by this diff — no LiveView, no Ecto schema/migration, no Oban worker, no GenServer/Agent in the changed files)
- Violations found: 0 (0 critical, 0 high, 0 medium)

## Laws Checked and Why They Apply

| Law | Checked | Verdict |
|-----|---------|---------|
| #10 No `String.to_atom` on user input | Yes | CLEAN — `atomize_when/1` uses a closed set of literal function clauses (lines 245–249, adapter.ex); the fallthrough returns the raw string, never calls `String.to_atom/1`. Only occurrences in the codebase are in comments documenting the law itself. |
| `Regex.compile!` DoS on adapter input | Yes | CLEAN — both compile sites (`glob_regex/1` in adapter.ex:158, `skill_namespace_regex/1` in detect.ex:581) pass adapter strings through `Regex.escape/1` before interpolation, so a malformed namespace or glob becomes a literal match, not a ReDoS vector. The only unescaped segments are engine-owned constants (`(^|/)`, `$`, `(?:...)`, `([a-z][a-z0-9_-]*)`) that cannot be influenced by adapter authors. |
| #5 Pin values in queries | Yes | N/A — no Ecto queries in diff |
| #4 No `:float` for money | Yes | N/A — no schema/migration in diff |
| #13 No process without runtime reason | Yes | `Task.async_stream` in `Faber.Scan.run/1` is correct: bounded fan-out with concurrency cap, per-task timeout, and `:kill_task` on timeout — a valid OTP concurrency pattern, not a gratuitous spawn |
| #15 `@external_resource` for compile-time files | Yes | N/A — all file reads in diff are runtime (`File.read`, `YamlElixir.read_from_file`), not module-level compile-time reads |
| #19 Comments aren't commit messages | Yes | CLEAN — comments in the diff are durable intrinsic facts (algorithm invariants, parity notes, contract references), not change-narration or ticket tags |
| #1 Unconditional DB in mount | Yes | N/A — no LiveView |
| #2 Streams for large lists | Yes | N/A — no LiveView |
| #3 PubSub without `connected?` | Yes | N/A — no LiveView |
| #7–9 Oban idempotency/args/structs | Yes | N/A — no Oban workers |
| #11 Authorize every `handle_event` | Yes | N/A — no LiveView |
| #12 No `raw/1` with untrusted content | Yes | N/A — no HEEx/LiveView |

## Notes

- **`atomize_when/1` is safe by design.** The function body (adapter.ex:245–249) maps four known strings to atoms via literal pattern clauses; anything else stays a string. No `String.to_atom/1` or `String.to_existing_atom/1` call is present. The validation in `opportunity_problems/1` (line 291–305) then rejects any unrecognized `when` value with a human-readable error, so an adapter author supplying an unknown `when:` gets a clear failure at load time rather than a silent atom allocation.

- **`Regex.compile!` cannot panic on malformed adapter input.** The `glob_token/1` clauses in adapter.ex pass all literal segments through `Regex.escape/1`, and `skill_namespace_regex/1` in detect.ex line 580 does the same for namespace strings. The only risk would be `Regex.compile!/2` raising on a structurally impossible pattern; that cannot happen here because the surrounding boilerplate (alternation syntax, anchors) is engine-owned and correct.

Checked 13 of 26 Iron Laws. **0 violations found.**
