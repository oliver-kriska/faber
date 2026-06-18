# Security Review — Faber M3–M6 (diff base e1db06c..HEAD)

## Executive Summary

Scope is a **local-first developer tool**: no auth, no DB, a localhost-only web
dashboard, and three subprocess boundaries (python sidecar, `claude` CLI, git).
The high-leverage risk here is **subprocess argument handling**, not classic web
vulns. All three `System.cmd` call sites correctly use the **args-list form**
(no shell), which neutralizes the usual command-injection vector. Remaining
issues are temp-file hygiene, git path-scope escape, and a couple of dev/prod
config items. Privacy posture is good: the proposer sends only friction
**summaries**, never raw transcript content.

No BLOCKERS for the local-first threat model. Findings below are WARNING/SUGGESTION.

---

## Findings

### 1. Temp file written world-readable in shared tmp dir — WARNING
- **Location**: `lib/faber/sidecar/system.ex:45-52`
- **Exposure**: `File.write/2` creates the JSON request in `System.tmp_dir!()`
  (a world-traversable directory on multi-user hosts) with default umask perms
  (often 0644). The request body is the friction-finding JSON. On a shared
  machine another local user could read it during the sidecar run, or
  pre-create/symlink the predictable-ish name. `System.unique_integer` is
  monotonic and guessable, so this is a mild TOCTOU/info-leak on shared hosts.
  Low impact for a single-user laptop (the stated deployment), real on CI/shared.
- **Fix**: create with restrictive perms and O_EXCL semantics, e.g.
  `File.open(path, [:write, :exclusive])` then `IO.binwrite`, or
  `File.chmod(path, 0o600)` immediately after write. Prefer a per-run subdir
  created with `File.mkdir_p` + `File.chmod(dir, 0o700)`.

### 2. git path-scope escape via `--`-prefixed / absolute paths — WARNING
- **Location**: `lib/faber/loop/git.ex:14-23` (`commit/3`, `revert/2`)
- **Exposure**: The moduledoc claims operations are "scoped to the given paths …
  so the loop can never touch unrelated files." That invariant is **not
  enforced**. `paths` is spliced straight into the argv:
  - `["add" | paths]` — a path of `"-A"` / `"--all"` would be parsed as a flag
    and stage the entire tree; an absolute path or `../../x` reaches outside `dir`.
  - `["checkout", "--" | paths]` — the `--` here guards the *commit-ish* slot but
    `git checkout -- ../../other/file` still reverts files outside the working
    subtree (revert is destructive: it discards working-tree changes).
  If `paths` ever originates from an adapter pack or LLM-suggested skill path
  (not just hardcoded skill dirs), this is a working-tree-wide clobber.
- **Fix**: validate each path before use —
  `Path.safe_relative(p, dir)` (reject `:error`), reject any element starting
  with `-`, and reject absolute paths. Add `"--"` before the add paths too
  (`["add", "--" | safe_paths]`) so a leading-dash filename can't be read as a
  flag. Then the moduledoc invariant is real.

### 3. `claude` / sidecar exit code ignored on sidecar; stderr discarded — SUGGESTION
- **Location**: `lib/faber/sidecar/system.ex:31` (`{out, _code}` — exit code
  discarded), and both call sites use `stderr_to_stdout: false`.
- **Exposure**: A non-zero python exit with empty stdout is reported as
  `{:sidecar_bad_output, ""}` with no stderr — hard to diagnose, and a partial
  stdout that happens to be valid JSON would be trusted despite a crash. Not a
  security hole per se, but error-path opacity can mask a failed/poisoned run.
- **Fix**: match the exit code (as `claude_cli.ex` and `git.ex` already do) and
  capture stderr for the error tuple. Treat non-zero exit as failure even if
  stdout parses.

### 4. Untrusted model output parsing is reasonable — SUGGESTION (note)
- **Location**: `lib/faber/llm/claude_cli.ex:82-130`
- **Assessment**: `extract_json/1` → `strip_fences` → `Jason.decode` →
  `slice_object` is a sane, defensive funnel. Two minor notes:
  - `slice_object` takes first `{` to last `}` — for output containing multiple
    JSON blobs this can splice an invalid span; failure is handled
    (`{:error, :no_json_object}`), so worst case is a clean error. Fine.
  - The parsed object flows to `Faber.Propose.build_proposal` which uses
    `Map.get` / `Atom.to_string` (no `String.to_atom` on model keys), so **no
    atom-exhaustion vector** from model output. Good — confirmed.
- **Fix**: none required. Optionally cap `out`/`text` size before regex/decode to
  bound work on a pathological CLI response.

### 5. Hardcoded dev/test `secret_key_base` + `signing_salt` — ACCEPTABLE (dev/test only)
- **Location**: `lib/faber_web/endpoint.ex:7` (`signing_salt`),
  `config/dev.exs:5`, `config/test.exs:13`, `config/config.exs:24`.
- **Assessment**: Acceptable. Prod reads `SECRET_KEY_BASE` from env in
  `runtime.exs:6-8` and raises if missing. The hardcoded values are confined to
  `dev.exs`/`test.exs`/`config.exs`-dev-defaults and the dashboard binds
  `127.0.0.1` only (`dev.exs:4`). The `signing_salt` in `endpoint.ex` is a
  module attribute baked at compile time and is **not** overridden per-env — if a
  prod web surface is ever added, that salt would ship in the release. Today
  `prod.exs` is empty and no prod web is configured, so no live exposure.
- **Fix (forward-looking)**: when/if prod web ships, move `signing_salt` and the
  session `key`/salt into `runtime.exs` from env, same as `secret_key_base`.

### 6. `check_origin: false` in dev — ACCEPTABLE
- **Location**: `config/dev.exs:8`
- **Assessment**: Standard Phoenix dev default; combined with `ip: 127.0.0.1`
  there is no remote origin to spoof. Fine for local-first. Ensure prod (if
  added) does not inherit it — currently prod has no endpoint web block beyond
  runtime.exs, which does not set `check_origin`, so the secure default applies.

### 7. Web surface: CSRF / headers / static scope — CLEAN
- `router.ex:8-9`: `:protect_from_forgery` and `:put_secure_browser_headers`
  both present in the `:browser` pipeline. Good.
- `endpoint.ex:17-22`: `Plug.Static` scoped via `FaberWeb.static_paths()`
  (allowlist), `at: "/"`, no user-supplied path — no traversal. Good.
- `DashboardLive` is **read-only** (scans filesystem), and the single
  `handle_event("rescan", …)` performs no mutation and takes no user params —
  the missing per-event authz Iron Law does not apply (no privileged action, no
  ID from params, no IDOR surface). Render uses HEEx auto-escaping, no `raw/1`.

### 8. Privacy: no raw transcript leaves the machine — CLEAN (verified)
- **Location**: `lib/faber/propose.ex:111-130` (`user_prompt/2`),
  `system_prompt/2`.
- **Assessment**: The LLM prompt is assembled **only** from `Scan.Result`
  aggregates — fingerprint, dominant_signal, numeric friction/message/tool/error
  counts, signal key/values, missed-opportunity labels, skills-used names. No
  message bodies, code, or file contents are interpolated. This matches the
  "proposer sends only friction summaries" requirement. The default LLM backend
  is the local `claude` CLI (no network key); the network path (`ReqLLM`) is
  opt-in. Good.

---

## Other boundary checks (all clean)

- No `String.to_atom/1` on untrusted input across the new code.
- No Ecto / SQL (no DB), so no injection surface.
- No `raw/1`, no `binary_to_term`, no `File.read` of user-supplied filenames in
  web code.
- All three `System.cmd` calls use the **argv list** form (no shell string
  interpolation) — the primary command-injection class is structurally avoided.

## Recommended manual tooling (no Bash access here)
- `mix sobelow --exit medium`
- `mix deps.audit` / `mix hex.audit`

## Priority
1. Enforce git path-scope (Finding 2) — make the documented invariant real.
2. Restrict temp-file perms (Finding 1) — only matters on shared hosts.
3. Surface sidecar exit code + stderr (Finding 3).
4. Forward-looking: move `signing_salt` to runtime env before any prod web (5).
