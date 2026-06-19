# single-binary review — verdict: PASS (review fixes applied)

Three specialists reviewed the diff (elixir-reviewer, security-analyzer, iron-law-judge). The
converged BLOCKER and the security WARNING are fixed; remaining items deferred with rationale.
Re-verified: `compile --warnings-as-errors`, `mix test` (132), `mix test.full` (133).

## Fixed
- **One-shot exit inside `start/2`** (elixir-reviewer + iron-law-judge, BLOCKER ×2) — `dispatch/1`
  now runs one-shot commands in their own process, so `Faber.Application.start/2` returns cleanly
  instead of halting in the boot path; the command prints synchronously, then `System.halt/1`
  (which flushes stdio, so the last line — e.g. the scan table — is never dropped).
- **World-readable secret** (security-analyzer, WARNING) — `runtime.exs` now persists
  `secret_key_base` `0600` and `~/.faber` `0700`; a blank/truncated secret file is treated as
  absent and regenerated (no empty-secret footgun).
- **Swallowed browser-open error** (elixir-reviewer, SUGGESTION) — `open_browser/1` now reports to
  stderr ("open <url> manually") instead of `rescue _ -> :ok`.

## Confirmed clean (reviewers)
- `open_browser/1` uses argv-list `System.cmd` (no shell) with an integer-derived port → no
  injection. `--install` goes through `Faber.Install` whose `@name_re` blocks path traversal.
- Loopback-only bind (`{127,0,0,1}`) makes the no-auth dashboard non-network-exposed; `check_origin:
  false` is acceptable given loopback. `Application.put_env` before the Endpoint child is the correct
  ordering. No `String.to_atom` on argv. Conditional Endpoint omission breaks no supervision
  assumptions. `copy_adapters` is build-time only.

## Deferred (non-blocking, documented)
- **`command/0` discriminator** (`RELEASE_NAME` + `function_exported?`) — robust for a Burrito-only
  distribution (we never ship a plain release); a dedicated config key would be marginally cleaner.
- **`run(:propose)` MatchError edge** — `Scan.run/1` is contracted to return `[%Result{}]` | `[]`,
  so `Enum.at` yields `%Result{}` or `nil` (handled). No real path to a MatchError.
- **OptionParser silently drops unknown flags** — minor UX; a `--help`-on-bad-flag pass can come
  later.
- **`check_origin: false` DNS-rebinding** — residual, loopback-only; a localhost allowlist is a
  future hardening.

## Environment blocker (separate from review)
Local `mix release` can't build on this macOS 26.5 host (Zig 0.15.2 lacks libSystem stubs for the
new SDK). Not a code issue — CI on `macos-14` + `ubuntu` is the supported build path. See
`.claude/research/2026-06-19-single-binary-distribution.md`.
