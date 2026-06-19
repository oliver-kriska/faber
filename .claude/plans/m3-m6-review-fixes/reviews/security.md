# Security Re-Review: Faber M3–M6 Review Fixes

**Diff base**: f9ded78..HEAD  
**Scope**: Three targeted fixes — W2 (git.ex safe_paths), W1+W7 (sidecar system.ex), W6 (propose.ex adapter context)  
**Date**: 2026-06-18

---

## Verdict: All three prior findings are closed. No new blockers or warnings.

---

## Fix 1 — W2: `safe_paths/2` in `lib/faber/loop/git.ex`

**Status: CLOSED. Prior WARNING fully addressed.**

The path-scope invariant claimed in the moduledoc is now actually enforced. Verification:

- `not is_binary(p)` — rejects non-binary elements (atoms, integers). Correct.
- `String.starts_with?(p, "-")` — rejects `-A`, `--all`, `--no-ff`, any flag-shaped input. Correct.
- `Path.safe_relative(p, dir)` — `Path.safe_relative/2` was added in Elixir 1.14 and returns `:error` for absolute paths, paths containing `..` that would escape the base, and empty strings. Calling it with the full `dir` as the second argument is correct: the function enforces that `p` stays within `dir`. An absolute path like `/etc/passwd` returns `:error`; `../../x` returns `:error`; a normal relative path like `adapters/faber-elixir/SKILL.md` returns `{:ok, rel}`.
- The empty-list short-circuit (`commit(_dir, [], _message) -> :ok`) prevents `git add` from being called with no paths, which would otherwise stage the entire working tree (not an issue with `--` but belt-and-suspenders).
- `["add", "--" | safe]` — the `--` separator means git cannot misinterpret the validated relative paths as flags even if validation had a gap.
- `["checkout", "--" | safe]` — already had `--`; safe list now also validated.

**One note (SUGGESTION, non-blocking)**: `Path.safe_relative/2` accepts paths with `.` components (e.g., `./foo`) and returns them. These are harmless (git handles them), but if a caller expects canonical relative paths, the output of `safe_relative` may contain a leading `./`. This does not create a security gap.

**Bypass analysis**: No bypass found. The three-layer check (non-binary → leading-dash → safe_relative) covers the four attack classes from the original finding: flag injection (`-A`), absolute path (`/x`), parent traversal (`../../x`), and non-string input.

---

## Fix 2 — W1+W7: Temp file and exit code in `lib/faber/sidecar/system.ex`

**Status: CLOSED. Both prior WARNINGs fully addressed.**

### Exit code (W1)
`{out, 0}` → decode JSON; `{out, code}` → `{:error, {:sidecar_exit, code, out}}`. Matches the pattern already used in `git.ex` and `claude_cli.ex`. Partial stdout that parses as valid JSON can no longer be silently trusted after a non-zero exit. Clean.

### Temp file hygiene (W7)
- `rand_token/0` uses `:crypto.strong_rand_bytes(12)` → 96 bits of entropy → Base64url (16 chars). The filename is `faber-<16chars>.json`. This is computationally unguessable; the original `System.unique_integer` weakness is gone.
- `File.open(path, [:write, :exclusive, :binary])` maps to `O_WRONLY | O_CREAT | O_EXCL` at the OS level. If the path already exists (by collision or pre-created symlink), the open fails instead of truncating. The TOCTOU/symlink vector from the original finding is closed.
- `File.chmod(path, 0o600)` restricts the file to owner-only after writing. On Linux/macOS this is the correct mitigation for info-leak on shared hosts. The call result is discarded (`_ = File.chmod(...)`) which is intentional — a chmod failure is non-fatal and the `{:ok, path}` branch has already written the file.
- `File.rm(tmp)` is in the `after` block of the `try do … after … end` in `call/3`. This means cleanup runs whether `run/4` returns normally or raises.

**New failure mode check**: If `File.open` returns `{:error, reason}` (e.g., tmp dir full, or an `eexist` collision — astronomically unlikely), `write_temp/1` returns `{:error, {:tmp_write_failed, reason}}`. The `with` in `call/3` propagates this as `{:error, {:tmp_write_failed, reason}}` — no crash, no file left behind (nothing was created). The `after File.rm(tmp)` is inside the `try` block which is only entered after `{:ok, tmp} <- write_temp(json)` succeeds, so `File.rm` is not called on a path that was never created. **No resource leak on open failure.**

**One note (SUGGESTION, non-blocking)**: The `chmod` happens after `IO.binwrite` and `File.close`. On a multi-user system there is a brief window between `open` (O_EXCL succeeds, file exists with umask perms) and `chmod`. With a typical umask of 022 the file would be 644 during the write. If strict isolation is required (CI shared runners), creating the file inside a `0o700` subdir would eliminate this window. For the stated deployment (developer laptop) this window is negligible.

---

## Fix 3 — W6: `user_prompt/2` adapter context in `lib/faber/propose.ex`

**Status: CLOSED. Prior WARNING fully addressed.**

The `user_prompt/2` function now pattern-matches `%Adapter{name: name, version: version}` and includes both in the prompt header: "Friction finding from one #{name} (v#{version}) session". This makes the system prompt and user prompt consistent (both name the target stack).

**Privacy invariant still holds.** Verifying what reaches the LLM in `user_prompt/2`:
- `r.fingerprint` — a string identifier (session pattern label, not content)
- `r.fingerprint_confidence` — float
- `r.dominant_signal` — atom/string label
- `r.raw`, `r.message_count`, `r.tool_count`, `r.error_count` — numeric aggregates
- `r.signals` — `{key, value}` pairs of friction-signal labels and scores, not message text
- `r.missed` — list of skill/automation labels
- `r.skills_used` — list of skill names
- `name`, `version` — adapter metadata (new)

No transcript bodies, no code, no file contents, no session text reach the LLM. The `Scan.Result` struct contains only derived aggregates. The `path` and `session_id` fields exist on the struct but are NOT included in the prompt. The prior "privacy: clean" finding is reconfirmed.

---

## Regression checks

- All three `System.cmd` calls use argv-list form (no shell string interpolation). Confirmed: `git.ex:61`, `sidecar/system.ex:31`, `claude_cli.ex:32`.
- No `String.to_atom/1` on untrusted input. Confirmed: `ingest.ex` explicitly notes the Iron Law; `propose.ex` uses `Atom.to_string(key)` (safe direction only).
- No `raw/1` anywhere in `lib/`. Confirmed by grep (no matches in web or non-web code).
- No `binary_to_term` in `lib/`. Confirmed.

---

## Summary

The three original findings (W1, W2, W7) are all closed by the fixes as implemented. No new vulnerabilities were introduced. The one genuinely new detail — the brief chmod-window on shared hosts — is a SUGGESTION, not a WARNING, for this threat model (local-first developer tool). Sidecar failure paths are clean (no crash on open failure, no orphaned file). Git path invariant is now actually enforced. Adapter context reaches the LLM correctly without leaking transcript content.

## Recommended tooling (run manually)
- `mix sobelow --exit medium`
- `mix deps.audit`
- `mix hex.audit`
