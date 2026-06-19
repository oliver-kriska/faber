# Security Audit: Faber single-binary distribution (Burrito + CLI)

## Executive Summary

Scope: the NEW surfaces in HEAD — `config/runtime.exs` (prod), `lib/faber/cli.ex`,
the `--install` path, and `mix.exs` `copy_adapters`. Overall posture for a
**local-first binary** is sound: loopback-only bind, argv-list `System.cmd`,
validated install names. **One real issue**: the persisted `secret_key_base` is
written with the process default umask (world-readable `0644`), exposing it to
other local users on a shared machine.

Verdict on the two key questions:
1. **Persisted secret permissions: NOT safe** — written world-readable. WARNING.
2. **Loopback-only no-auth + `check_origin: false`: acceptable** for a local
   binary, with one caveat (DNS rebinding / `Host` spoofing — see W2). SUGGESTION.

## Findings

### W1 (WARNING) — Persisted secret_key_base is world-readable

- **Severity**: Medium (High on multi-user/shared hosts)
- **Location**: `config/runtime.exs:16-18`
- **Issue**: The secret is created and persisted with
  `File.write!(secret_path, secret)` (line 17). `File.write!/2` honors the
  process umask, which on most systems yields **mode `0644`** — readable by every
  local user. `secret_key_base` signs/encrypts Phoenix session cookies and LiveView
  payloads; any local user reading `~/.faber/secret_key_base` can forge them. The
  containing dir is created with `File.mkdir_p!` (line 9), default `0755` — also
  traversable. For a "local-first" app the implicit trust boundary is the OS user,
  so the secret must be `0600` and the dir `0700`.
- **Fix**:
  ```elixir
  # dir: owner-only
  File.mkdir_p!(config_dir)
  File.chmod(config_dir, 0o700)

  # secret: write then tighten (write-then-chmod avoids a TOCTOU-free races
  # since the file does not exist before; still prefer chmod immediately).
  secret = Base.url_encode64(:crypto.strong_rand_bytes(48), padding: false)
  File.write!(secret_path, secret)
  File.chmod!(secret_path, 0o600)
  secret
  ```
  Note: `File.write/3` has no mode option, so an explicit `File.chmod!/2`
  immediately after the write is the idiomatic fix. There is a brief window
  between `write!` and `chmod!` where the file is `0644`; acceptable here because
  the file is freshly created and short-lived, but if hardening fully, write to a
  `0600` temp file (e.g. via `:file.open` with `[:exclusive]` then set mode) and
  rename.
- **OWASP**: A02:2021 Cryptographic Failures / A04 Insecure Design.

### W2 (SUGGESTION) — `check_origin: false` + no auth relies solely on loopback

- **Severity**: Low
- **Location**: `config/runtime.exs:26,28` (`ip: {127,0,0,1}`, `check_origin: false`)
- **Assessment**: Binding `{127,0,0,1}` is the **right call** — it is not reachable
  from the LAN, so the no-auth dashboard is not network-exposed. Given loopback,
  `check_origin: false` is *largely* safe because only local processes can connect
  the WebSocket. The residual risk is **DNS rebinding**: a malicious web page the
  user visits can, after a rebind, point a hostname at `127.0.0.1` and—because
  origin checking is disabled and there is no auth/CSRF on the socket—drive the
  dashboard from the browser. The loopback bind blocks remote attackers but not a
  browser running on the same machine.
- **Suggested hardening** (optional for v1, document the trust model either way):
  set `check_origin: ["http://localhost:#{port}", "http://127.0.0.1:#{port}"]`
  instead of `false`. This keeps local use working while rejecting cross-origin
  WebSocket upgrades. Pairs well with leaving the bind on loopback.
- **OWASP**: A05 Security Misconfiguration.

### S1 (SUGGESTION) — Env-var precedence is correct; note read-failure mode

- **Location**: `config/runtime.exs:12-19`
- **Assessment**: The `SECRET_KEY_BASE env || (exists? && read) || generate`
  precedence is correct and safe: explicit env wins, then the persisted value,
  then a fresh CSPRNG secret (`:crypto.strong_rand_bytes(48)`, line 16) — good
  entropy, base64url-encoded. `String.trim` on the read (line 14) is correct.
  Minor: if `secret_path` exists but is empty/whitespace, `String.trim` returns
  `""` which is truthy, so a **blank secret** would be used (Phoenix may then fail
  validation, or worse accept a weak key). Guard with a length check:
  `(File.exists?(secret_path) && trim_nonempty(File.read!(secret_path)))`.

### CLI — clean (no command/arg injection)

- **`open_browser/1`** (`lib/faber/cli.ex:165-173`): uses
  `System.cmd("open", [url])` / `System.cmd("xdg-open", [url])` — the
  **argv-list form**, so no shell is invoked and no word-splitting/injection is
  possible. `url` is `"http://localhost:#{serve_port()}"` (line 148) where
  `serve_port` comes from integer-parsed config (`port: :integer`,
  cli.ex:57; `String.to_integer` in runtime.exs:21) — not user-controlled
  strings. **No injection risk.** Even if `url` were attacker-controlled, the
  argv form passes it as a single argument; the only residual class would be
  arg-injection if it began with `-`, but a `http://` literal prefix precludes
  that. Clean.

### `--install` — path traversal correctly blocked

- **Location**: `lib/faber/cli.ex:129,213-217` → `Faber.Install.install/2`
  (`lib/faber/install.ex:42-58`).
- **Assessment**: Confirmed the `--install` flow routes through
  `Install.install/2`, which validates the proposal name against
  `@name_re ~r/\A[a-z0-9][a-z0-9-]{0,63}\z/` (install.ex:17,57-58) **before**
  building the path with `Path.join` (line 44). This rejects `../`, absolute
  paths, and flag-like names. The moduledoc explicitly documents this as the
  security boundary because the name originates from LLM output over untrusted
  transcripts. Correct and unchanged. Clean.

### `mix.exs` copy_adapters — build-time only, low risk

- **Location**: `mix.exs:40-41` (`File.cp_r!("adapters", Path.join(release.path, "adapters"))`).
- **Assessment**: Runs only during `mix release` on the developer/CI machine with
  a hardcoded source dir (`"adapters"`) and the build's own `release.path` — no
  runtime or user input. The copied adapter files become part of the binary's
  trusted payload, which matches the design (adapters are trusted packs). No
  finding beyond noting that adapter contents ship as-is; supply-chain trust of
  the `adapters/` dir is assumed by design.

## Security Posture (summary)

Checked: secret generation/persistence, network bind, WebSocket origin, CSRF model,
command injection, path traversal, atom exhaustion, build step.
- **Secrets**: not in code (generated/env) — good; **persisted file perms is the
  one gap (W1)**.
- **Network**: loopback bind correct; `check_origin: false` acceptable but
  hardenable (W2).
- **CLI injection**: clean (argv-list `System.cmd`).
- **Path traversal**: clean (`Install` name regex).
- **Atom exhaustion / XSS / SQLi**: not introduced by this commit (no
  `String.to_atom`, `raw/1`, or interpolated queries in the new code).

## Recommendations (priority order)

1. **W1** — `File.chmod!(secret_path, 0o600)` and `File.chmod(config_dir, 0o700)`
   in `runtime.exs`. Smallest, highest-value fix.
2. **W2** — replace `check_origin: false` with an explicit localhost allowlist.
3. **S1** — treat empty/whitespace persisted secret as absent (regenerate).

## Tools to run manually (no Bash access here)

- `mix sobelow --exit medium` (will likely flag `File.write!` config write + the
  `check_origin: false`)
- `mix deps.audit`
- `mix hex.audit`
