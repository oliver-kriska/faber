# Security Audit: Faber (NEW code, `git diff HEAD~5 HEAD`)

## Executive Summary

One **BLOCKER**: an LLM-proposed skill `name` flows unsanitized into a
filesystem path in `install.ex`, allowing directory traversal / arbitrary
file write outside the skills dir. The scheduler is correctly inert-by-default
and `claude.ex`/`format.ex` correctly avoid atom exhaustion and arbitrary
module loading. Template rendering is safe from code injection but is a
content-injection vector that compounds the install BLOCKER.

---

## Critical Vulnerabilities

### 1. Path traversal via LLM-controlled skill name (BLOCKER)

- **Severity**: Critical / BLOCKER
- **Location**: `lib/faber/install.ex:29` (and `:34` `mkdir_p`, `:35` `write`)
- **Issue**: `name` originates entirely from LLM output
  (`Propose.build_proposal/3` → `get(object, :name)`, `propose.ex:211`) and is
  never validated — `Proposal` has no constraints, `Eval`/`gate` do not
  sanitize it. It is used directly:

  ```elixir
  path = Path.join([opts[:dir] || default_dir(), name, "SKILL.md"])
  ...
  File.mkdir_p(Path.dirname(path))
  File.write(path, skill_md)
  ```

  `Path.join(["/skills", "../../../etc/foo", "SKILL.md"])` resolves to
  `/etc/foo/SKILL.md`. An absolute `name` (`"/etc/cron.d/x"`) is even worse:
  `Path.join` discards the prefix when a later segment is absolute, so the
  skills dir is dropped entirely. The transcript Faber mines is untrusted
  input; a poisoned transcript can steer the LLM to emit a malicious `name`,
  turning a "skill writer" into an arbitrary-file-write primitive. With
  `schedule.ex install: true`, this fires **unattended overnight** with no
  human in the loop.
- **Fix**: validate `name` against a strict allowlist before any path use, and
  defense-in-depth with `Path.safe_relative/2` (the codebase already uses this
  in `loop/git.ex:52`):

  ```elixir
  def install({name, skill_md}, opts) when is_binary(name) and is_binary(skill_md) do
    with :ok <- validate_name(name) do
      dir = opts[:dir] || default_dir()
      path = Path.join([dir, name, "SKILL.md"])
      # belt-and-braces: ensure the resolved path stays under dir
      ...
    end
  end

  @name_re ~r/\A[a-z0-9][a-z0-9-]{0,63}\z/
  defp validate_name(name) do
    if Regex.match?(@name_re, name), do: :ok, else: {:error, {:invalid_name, name}}
  end
  ```

  Reject any name containing `/`, `.`, `\`, or null bytes; cap length.
- **OWASP**: A01:2021 Broken Access Control / A03 Injection (Path Traversal,
  CWE-22), CWE-73 External Control of File Name or Path.

### 2. No overwrite protection bypass via traversal (WARNING, subsumed by #1)

- **Location**: `lib/faber/install.ex:31`
- **Issue**: `File.exists?` overwrite guard operates on the already-tainted
  `path`. Traversal could clobber an existing file outside the skills dir on
  the `force: true` path (used by `schedule` when configured). Fixing #1
  removes this.

---

## Other Findings

### 3. Template content injection into SKILL.md / frontmatter (WARNING)

- **Location**: `lib/faber/template.ex` (whole module);
  `lib/faber/propose.ex:175-203` (`render_skill_md/1` heredoc)
- **Issue**: LLM fields (`description`, `rationale`, `iron_laws`, `usage`,
  `example`) are interpolated into YAML frontmatter and Markdown with only
  `escape/1` (double→single quote, `propose.ex:255`). No newline/`---`/YAML
  escaping. A `description` containing `\n---\nname: evil` or a closing
  frontmatter fence can forge frontmatter or inject extra directives that a
  downstream skill loader trusts. `Template.render` itself does not eval
  anything (no code injection — string-keyed context, no `to_atom`), so this
  is *content* injection, not RCE. Severity is bounded by who consumes
  SKILL.md, but combined with #1 (attacker controls file location too) it is
  worth hardening: strip control chars / `---` lines from frontmatter fields,
  or emit frontmatter via a real YAML encoder.

### 4. `Install.install/1` arity mismatch with `render_skill_md` (SUGGESTION)

- **Location**: `lib/faber/install.ex:25`
- **Issue**: calls `Propose.render_skill_md(p)` (arity 1, no adapter), so the
  installed file uses the built-in renderer, not the adapter template — while
  `Eval` (`eval.ex:63`) and `dashboard_live.ex:101` render with the adapter
  template. The *evaluated* artifact differs from the *installed* artifact, so
  the eval gate does not vet exactly what lands on disk. Not a classic vuln but
  a gate-bypass smell: the install should render the same content that passed
  eval.

---

## Security Posture (NEW code only)

### Atom exhaustion / untrusted parsing — clean
- `claude.ex:52` decodes with `Jason.decode(line, keys: :strings)`; all map
  access is string-keyed; no `String.to_atom` on transcript data. Malformed
  lines become `{:error, _}` rather than crashing. Correct.

### Arbitrary module loading in `Format.resolve` — acceptable
- `format.ex:54` uses `Code.ensure_loaded?/1` + `function_exported?/2` on a
  value from `opts[:format]` / `config :faber, :ingest_format`. The input is
  **operator config, not untrusted transcript/LLM data**, and it only loads an
  already-compiled module that exports `stream_file!/1` (cannot load arbitrary
  code off disk). Low risk; note it as config-trust-boundary. No change
  required for v1.

### Scheduler safe-by-default — confirmed
- `schedule.ex:107` `enabled: false` default; `schedule_next/2` is inert when
  disabled (`:173`); `install` gated behind both `opts[:install]` AND
  `eval.passed == true` (`maybe_install/3`, `:94-98`). Task is rescued so a
  crash can't escalate. Design is correct — the residual risk is entirely that
  *when* an operator enables `install: true`, BLOCKER #1 makes it dangerous.

---

## Recommendations (priority order)

1. **Fix #1** — add `validate_name/1` + `Path.safe_relative/2` guard in
   `install.ex` before merging. Add a unit test with `name: "../../etc/x"` and
   `name: "/abs"` asserting `{:error, {:invalid_name, _}}`.
2. Harden frontmatter rendering (#3) — strip `\n`/`---` from YAML fields.
3. Align install rendering with eval rendering (#4) so the gated artifact is
   the installed artifact.

## Tools to Recommend (no Bash access here)
- `mix sobelow --exit medium` (will flag the `File.write`/path-build in install.ex)
- `mix deps.audit` / `mix hex.audit`
