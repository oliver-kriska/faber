# Security Audit: Faber — MCP server + managed-block writer + claude CLI + GEPA seam

Scope: `06248b5^..HEAD`. Six targeted risks. **Verdict: SHIP. No blockers.**
The privacy boundary, traversal guards, loopback bind, and shell-env passing
are all genuinely mitigated and test-covered. Findings below are WARNINGs /
notes, none gating.

## Risk-by-risk

### 1. PRIVACY / DATA-EXFIL — `summarize/1` — MITIGATED (WARNING on path fields)
`lib/faber/mcp/tools/search_friction.ex:48-66`. The projection is an explicit
constructed allowlist (a literal map literal, not `Map.take` over the struct),
so new struct fields default to *not* exposed — fail-closed. Verified each field:
- `friction/raw/rate/opportunity/*_count/max_ctx_pct/fingerprint_confidence` —
  numeric aggregates, no content.
- `dominant_signal` — enum atom (`detect.ex`). `missed` — fixed vocabulary
  (`"investigate"|"plan"|"verify"|"pr-review"|"review"`, `detect.ex:275-288`),
  no free text. `skills_used` — installed skill names. `fingerprint` — `fp.type`
  category. `session_id` — opaque id. **None carry transcript text.**
- The internal `:path` (transcript location) is deliberately NOT projected —
  asserted at `tools_test.exs:79`.

Tests are real, not theater: `tools_test.exs:45-52` greps a known fixture
phrase (`"please add a feature to the parser"`) and asserts it is in the source
file but NOT in any tool output; `:54-80` pins the allowlist to an exact set
(`MapSet.equal?`), so adding a leaky field breaks the build.

**WARNING (Low, by-design):** `cwd` (`scan.ex:155`) and `file_paths`
(`scan.ex:179-191`) are real filesystem paths. They are metadata the user owns,
and the moduledoc/HANDOFF explicitly classify them as in-scope aggregates — but
absolute paths can themselves encode sensitive strings (client names, ticket
ids, `/Users/<real-name>/...`). This is the *same* exposure as the LLM path, so
it is consistent with the stated boundary, and the surface is localhost-only
single-user. No fix required for v1; if MCP ever becomes multi-user or remote,
revisit (redact home prefix / basename-only). Not a blocker.

### 2. PATH TRAVERSAL — `get_skill.ex` + `install.ex` — MITIGATED
- **get_skill** (`get_skill.ex:21-25`): name is never used to build a path. It
  is matched (`==`) against the discovered listing from `Path.wildcard`, then
  the *listed* `:path` is read. A caller-supplied path-y name simply fails the
  `Enum.find` → structured "not found". Covered: `tools_test.exs:134`
  (`"../../../../etc/passwd"` → isError).
- **install** (`install.ex:43-59`): `@name_re = \A[a-z0-9][a-z0-9-]{0,63}\z`
  (`install.ex:18`) is checked *before* `Path.join`. Anchored both ends, no `.`,
  no `/`, no absolute, no `..`, length-capped — a tight allowlist. The comment
  correctly notes `Path.join` would honor an absolute segment, which the regex
  blocks. Covered: `install_test.exs:26-32` (`../../etc/evil`, `/etc/evil`,
  spaces, uppercase all rejected).
- **list_installed / pointers** (`install.ex:100-106`): globs
  `<dir>/*/SKILL.md` — wildcard segments can't traverse; names are derived from
  on-disk dirs, never attacker-chosen at this layer. Safe.

### 3. NETWORK SURFACE — router / application / config — MITIGATED
- Bind is loopback in every env: `dev.exs:4`, `test.exs:12`, and critically
  `runtime.exs:39` `http: [ip: {127,0,0,1}, port: port]` with an explicit
  comment "Do not bind 0.0.0.0" (`runtime.exs:37`). The single-binary `serve`
  path uses runtime.exs, so the production-ish path is loopback too.
- `/mcp` (`router.ex:23`) is forwarded raw to the Anubis StreamableHTTP plug,
  no browser pipeline (correct — JSON-RPC, no CSRF/HTML), and the MCP server is
  only supervised under `nil`/`{:serve,_}` boot, never one-shot CLI
  (`application.ex:48-50`). A `faber scan` binds no port.
- No-auth is acceptable **given the loopback bind**: the trust boundary is the
  loopback interface + single-user machine, exactly as scoped.

**WARNING (Low):** the security of the whole `/mcp` surface rests entirely on
the bind address — there is no defense-in-depth (no Host-header check, no
`127.0.0.1`-only plug) if a future change or a reverse-proxy/`socat` ever
re-exposes it. Consider a one-line remote-IP guard plug on the `/mcp` forward
as belt-and-suspenders. Not gating; the bind is correct today and the
no-egress test (`no_egress_test.exs`) proves the app makes zero *outbound*
connections at rest (it traces `gen_tcp/ssl/socket :connect` with a positive
control — a genuine, non-theatrical guard). Note: no-egress covers outbound,
not inbound exposure — the inbound guarantee is purely the bind config.

### 4. COMMAND INJECTION — `claude_cli.ex` — MITIGATED
`claude_cli.ex:39-52`. Every dynamic value (`FB_BIN`, `FB_PROMPT`, `FB_SYS`,
`FB_MODEL`) is passed via the `env:` keyword of `System.cmd/3`, never
interpolated into the script string. Inside `sh -c` they are referenced as
`"$FB_PROMPT"` etc. — **double-quoted**, so no word-splitting and no glob/
command-substitution of the values (env values are not re-evaluated for
`$()`/backticks by the shell). `${FB_SYS:+--append-system-prompt "$FB_SYS"}`
and the `FB_MODEL` variant correctly drop the flag when empty, with the value
still quoted. The static script string contains no attacker data. A prompt of
`"; rm -rf ~ #` is inert — it lands in `$FB_PROMPT` and is passed as one argv
to `claude`. **No injection path.** `FB_BIN` comes from
`System.find_executable` of config, not user input.

### 5. FILE CLOBBERING — `managed_block.ex` — MITIGATED
`managed_block.ex`. Upsert is bounded by self-delimiting markers:
- `upsert/2` (`:62-72`): if a block exists, `Regex.replace(@block_re, …, fn _ ->
  block end)` replaces ONLY the marker-delimited region (`@block_re` is
  non-greedy `.*?` with `/s`), preserving all surrounding user text. Uses the
  function-replacement form specifically so body `\0`/`\1` aren't treated as
  backreferences (`:66-68`) — a real corruption footgun, correctly avoided.
- No block → `append/2` (`:98-99`) only adds after the existing content; never
  overwrites.
- Digest guard is sound: `tampered?/1` (`:91-95`) recomputes
  `digest(body)` over the *current* body and compares to the digest recorded in
  the marker; a hand-edit changes the body → digests diverge → install layer
  refuses without `:force` (`install.ex:179`). `in_sync?/2` (`:79-84`) compares
  by digest of actual body vs new body, so idempotent re-writes are byte-stable
  and a tampered block reads as out-of-sync (not silently overwritten).

**Note (Low):** digest is 12 hex chars (48 bits) over the trimmed body. This is
an integrity/change-detection guard, not adversarial — collision risk is
irrelevant here (the threat is accidental user edits, not a crafted preimage).
Fine. One residual: a user who pastes literal `<!-- FABER:END -->` inside their
own prose *above* the real block could confuse the non-greedy match — extreme
edge, cosmetic, not a security issue.

### 6. SECRETS — `optimize.py` — MITIGATED
`python/faber_eval/optimize.py`. `api_key_present` (`:44-47`) only checks
`env.get(var)` truthiness for `ANTHROPIC/OPENAI/GEMINI_API_KEY` — it never
returns or logs the value. `unavailable_reason` (`:50-69`) emits only the
variable *names*, never values. The result/error shapes (`shape_result`,
`_error`, `run`) carry no env/key data. `_run_gepa_live` hands the key to dspy
implicitly via env (standard) and returns only skill text + scores. **No key
leaks into JSON output or logs.** Exceptions are stringified as
`type(exc).__name__: exc` (`:152`) — a provider client *could* embed a key in an
exception message in theory, but that's the dspy/provider library's contract,
not Faber's, and this path is opt-in, unvalidated, `# pragma: no cover`.

## Iron Laws
- No `String.to_atom` on user input, no `raw/1`, no SQL/`fragment` interpolation,
  no `binary_to_term` in the diff. CSRF/headers on the browser pipeline
  (`router.ex:9-10`); `/mcp` correctly bypasses it (JSON-RPC).
- Validate-at-boundary upheld: install name regex + MCP allowlist projection.

## Recommendations (non-gating)
1. (Low) Add a loopback-only remote-IP guard plug on the `/mcp` forward as
   defense-in-depth, decoupling safety from the bind config alone.
2. (Low, future) If MCP goes multi-user/remote, redact `cwd`/`file_paths` to
   basenames or strip the home prefix.

## Tools to run manually (no Bash here)
- `mix sobelow --exit medium`
- `mix deps.audit` / `mix hex.audit`
- `uv run --extra dev ruff check python/` (Python lint)
