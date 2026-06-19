# v1-completion review — verdict: PASS (blockers fixed)

Four specialist agents reviewed the session diff (`HEAD~5..HEAD`, F3–F7): elixir-reviewer,
iron-law-judge, testing-reviewer, security-analyzer. All BLOCKERs and the meaningful WARNINGs
were fixed in commit "fix(review): close 3 blockers + hardening". Re-verified: `mix compile
--warnings-as-errors` clean, `mix test` 122 pass, `mix test.full` 123 pass, Python 16 pass.

## Blockers (all FIXED)

1. **Path traversal via LLM skill name** (security) — `Faber.Install` joined an unvalidated,
   LLM-derived `name` into a filesystem path; `"../../etc/foo"` or an absolute path would escape
   the skills dir. Faber mines *untrusted* transcripts, and `Schedule install: true` runs it
   unattended. **Fixed:** allowlist `/\A[a-z0-9][a-z0-9-]{0,63}\z/`, reject otherwise + test.

2. **LiveView crash on bad param** (elixir-reviewer) — `String.to_integer/1` on `phx-value-i`
   crashed the dashboard process on non-integer input. **Fixed:** `Integer.parse` + ignore.

3. **Scheduler crash propagation** (iron-law-judge + elixir-reviewer) — `Faber.Schedule` (a
   *permanent* server) ran its job via linked `Task.async`; a throw/exit bypassed the `rescue`
   and killed the scheduler. **Fixed:** `Task.Supervisor.async_nolink` under a new
   `Schedule.TaskSupervisor`, DOWN handling, `catch` clause. (Contrast: `Loop.Server` is
   `:temporary` and *intends* to crash — linked `Task.async` is correct there. Confirmed clean.)

## Warnings (FIXED)

- **Frontmatter injection** — LLM `description` entered YAML frontmatter with only quote-swap;
  a newline/`---` could forge frontmatter. **Fixed:** collapse whitespace/newlines in `escape/1`.
- **Silent unknown matcher param** — `safe_atom/1` returned the string on unknown adapter-eval
  keys with no signal. **Fixed:** `Logger.warning`.
- **Install/Eval render drift** (flagged by 3 agents) — Install rendered via the built-in renderer
  while Eval gated the adapter-template render. **Fixed:** `Install.install(p, adapter: …)` +
  Schedule passes the adapter, so the gated artifact == the written one.
- **Flaky scheduler test** — `Process.sleep`-poll `eventually/2`. **Fixed:** deterministic
  `:notify` hook + `assert_receive`.

## Confirmed clean (by reviewers)
Atom-exhaustion (string-keyed transcript decode, `to_existing_atom` only); `Format.resolve`
module loading (config-trust only, can't load off-disk code); scheduler safe-by-default (inert
timer, `enabled: false`, install double-gated); timer lifecycle (no double-arm); demonitor/flush
in both GenServers; mix task uses `app.config` not `app.start`.

## Deferred (non-blocking SUGGESTIONs)
Extra `Faber.Template` edge-case tests (nested same-key sections); `render_skill_md/2` matching
`nil` vs `_` to surface corrupt manifests loudly; dashboard debounce-guard tests;
`Install.default_dir/0` home-fallback test. Low value vs. churn — left for a future pass.
