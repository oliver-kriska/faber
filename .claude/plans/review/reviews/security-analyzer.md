# Security Audit: Faber — diff 874ee99..HEAD

## Executive Summary

Reviewed the four security-relevant surfaces in the diff (install marker write,
privacy boundary for transcript paths, MCP get_skill traversal, propose.ex body
rendering). **No BLOCKERs.** The diff is defensively written: the `@name_re`
boundary gates both paths, the privacy boundary holds (and is tested), and
get_skill remains traversal-proof. Two low-severity notes on body-content
injection that are realistic-but-bounded for a local skill file.

---

## 1. Install marker path — name validation gates BOTH paths — CLEAN

`install/2` (install.ex:62-77) runs `validate_name(name)` **before** computing
any path. `skill_dir = Path.join(opts[:dir] || default_dir(), name)` is derived
once from the validated `name`; `path` (SKILL.md), `mkdir_p(skill_dir)`, and
`write_marker(skill_dir, name, opts)` (install.ex:86-89) all target that same
validated dir. The marker is `Path.join(skill_dir, @marker)` — it cannot be
written outside the skills dir via a crafted name.

`@name_re ~r/\A[a-z0-9][a-z0-9-]{0,63}\z/` rejects `/`, `.`, leading `-`,
absolute paths, and `..`. Anchored with `\A..\z` (not `^..$`), so newline
smuggling (`a\n../../etc`) is also rejected — correct choice. Covered by
install_test.exs:26.

**Status: PASS.** No action.

## 2. Privacy boundary — transcript path NOT in marker — CLEAN

The `%Proposal{}` install path builds provenance from only three keys
(install.ex:52-57): `adapter`, `source_session` (`p.source[:session_id]`),
`fingerprint`. `p.source[:path]` (the raw transcript location, set in
propose.ex:296) is **never** read into the marker. `write_marker/3` merges only
`installed_by`/`name` + that provenance map — no transcript text, no path.

The rendered SKILL.md (propose.ex:199-233 / template path) draws only from
proposal fields (name, description, rationale, iron_laws, usage, example,
workflow, patterns) — none of which is the transcript path or raw transcript
content. `source` is not rendered.

**Test coverage is genuine:** install_test.exs:59-79 sets
`source: %{... path: "/Users/x/secret.jsonl"}`, then asserts
`refute Map.has_key?(data, "path")` AND
`refute File.read!(path) =~ "secret.jsonl"` — covering both the marker and the
SKILL.md body. This is the right assertion shape.

**Status: PASS.** Moat invariant upheld and tested.

### SUGGESTION (defense-in-depth, not a finding in this diff)
`drop_nils` keeps only the three explicit keys, so adding future provenance keys
that accidentally include a path is the only regression risk. Consider keeping
the provenance map construction as an explicit allowlist (it already is) and add
a one-line comment-test that any new provenance key is non-path. Low priority.

## 3. MCP get_skill — traversal-proof — CLEAN

`get_skill.ex:24` resolves the caller-supplied `name` via
`Enum.find(Install.list_faber_installed(), &(&1.name == name))` — an equality
match against discovered, already-installed listings, never a path built from
input. A path-y name (`../../etc/passwd`, `foo/bar`) simply won't equal any
discovered `.name` (basenames of validated dirs), so it falls to the `nil`
branch → tool error, never a `File.read`. The only `File.read` (line 27) uses
`path` from the **listing**, not from input.

`list_faber_installed` itself globs `<expanded dir>/*/SKILL.md` and filters on
the marker — `*` does not cross `/`, so listing entries are confined to the
skills dir.

**Status: PASS.**

## 4. propose.ex body rendering — escape vs unsanitized workflow/patterns/example

`escape/1` (propose.ex:332-337) is applied to `description` (the YAML
frontmatter scalar) — collapses `"`→`'`, `\s+`→single space, trims. This
correctly prevents frontmatter forgery via the description: a newline or a
`---` line cannot break out of the quoted scalar. Good.

**Unsanitized fields rendered into the BODY:** `rationale`, `usage`, `example`,
`workflow[]`, `patterns[]` are interpolated raw into the markdown body
(propose.ex:214-231, 240, 247, 254-257). Assessing each realistically:

### 4a. Frontmatter forgery via body fields — NOT exploitable
The frontmatter block is emitted first and closed by its own `---` at
propose.ex:210 before any body field is interpolated. A body field containing
`---\nname: evil` lands *after* the closing fence, so it's body text, not
frontmatter. YAML parsers read only the leading block. **No forgery.**

### 4b. Closing-fence injection via `example`/`usage` — SUGGESTION (low)
**Location:** propose.ex:225-227 (built-in) and `usage_block` at 254-257.
**Issue:** `usage_block` interpolates `example`/`usage` raw inside a
```` ```bash ```` fence. An LLM `example` value containing a line ```` ``` ````
would close the fence early; subsequent lines render as markdown prose, and a
later ```` ``` ```` could open a new fence. Because the source is LLM output
mined from an untrusted transcript, an attacker who controls transcript content
*could* shape the example to break the fence.
**Impact:** Realistically low. This is a **local skill file** read by a coding
agent, not a web XSS sink. Worst case is a malformed/misleading SKILL.md body
(content spoofing — making injected prose look like skill instructions). No code
execution, no path escape, no secret leak. The eval gate (`Faber.Eval`) also
inspects structure before install.
**Fix (cheap):** strip/neutralize backtick-fence sequences in `usage_block`
inputs, e.g.
```elixir
defp fence_safe(s), do: String.replace(s, ~r/```+/, "ʼʼʼ")
# apply to present(usage) and present(example) before interpolation
```
Or render the example with a longer fence guard. Optional.

### 4c. workflow/patterns markdown break-out — SUGGESTION (very low)
**Location:** propose.ex:240 (`#{i}. #{s}`), 247 (`- #{...}`), 273.
**Issue:** A multi-line `workflow`/`patterns` string injects raw newlines into a
numbered/bulleted list, so an entry can introduce its own `## Heading`,
`---` (renders as `<hr>`, not frontmatter — see 4a), or a fenced block. This is
markdown structure spoofing within the body.
**Impact:** Cosmetic/content-spoofing only, same reasoning as 4b — local file,
no sink. `format_pattern` splitting on the first `:` is safe (no regex/path use).
**Fix (optional):** collapse newlines per list item:
`String.replace(s, ~r/\s*\n\s*/, " ")` in `workflow_section`/`patterns_section`
before rendering. Keeps each step on one line and removes the break-out vector.

---

## Other checks (one line)
Checked: SQL injection (no Ecto/Repo in diff — N/A), `String.to_atom`
(none on user input), `raw/1` (none — not a web app), `binary_to_term` (none),
secrets in code (none), CSRF/headers (no web surface in diff). All clean.

`Jason.encode!` on the provenance map (install.ex:88) properly JSON-escapes the
LLM-sourced `name`/`adapter`/`fingerprint` values — no JSON injection into the
marker.

## Tools to recommend (no Bash access here — run manually)
- `mix sobelow --exit medium`
- `mix deps.audit` / `mix hex.audit`

## Verdict
**No BLOCKERs / WARNINGs.** Two SUGGESTIONs (4b fence guard, 4c newline
collapse) harden the LLM→markdown body against content-spoofing; both optional
given the local-file (non-web-sink) threat model. Surfaces 1–3 and the privacy
boundary (2) are correctly implemented and the privacy test genuinely covers the
invariant.
