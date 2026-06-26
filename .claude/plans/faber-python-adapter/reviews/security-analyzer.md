# Security Audit: faber-python adapter (diff 183fb3a^..HEAD)

## Executive Summary

Threat model is correct: adapter packs are untrusted declarative input that the
engine partly turns into executable behavior (regexes, atom dispatch). The changed
code in `lib/faber/adapter.ex` and `lib/faber/detect.ex` is **largely well-defended**.
No atom-exhaustion, no SQL, no XSS, no unsafe deserialization, no privacy regression.

One **real Medium** issue (untrusted regex compile via `Regex.compile!` can crash the
caller) and one **Low** (ReDoS on adversarial regex content). Both stem from
adapter-controlled strings reaching `Regex.compile!` and being run over transcript
text. Neither is exploitable by a remote attacker in the normal local-first flow —
the "attacker" must author/install a malicious adapter pack — so impact is bounded to
DoS of the scan process, not data exfiltration or code execution.

## Audit Points

### 1. `atomize_when/1` (adapter.ex:245-249) — SAFE ✅

Closed literal-match clauses; the catch-all `atomize_when(other), do: other` returns
the **string unchanged** (no `String.to_atom`). Unknown values stay strings and are
then rejected by `opportunity_problems/1` (adapter.ex:291-306) because `w in
@opportunity_whens` fails. No dynamic atom creation. Iron Law #3 upheld. This is the
correct pattern.

### 2. `skill_namespace_regex/1` (detect.ex:579-582) — see findings below

- **`Regex.escape/1` IS applied** (detect.ex:580) — confirmed. No metacharacter
  injection from namespace content; a namespace like `.*` is matched literally.
- The fixed scaffold `"(?:#{alt}):([a-z][a-z0-9_-]*)"` is the only interpolated part
  and `alt` is fully escaped, so the *structure* is attacker-controlled only in the
  count of alternatives. See ReDoS (Low) and crash (Medium) below.

### 3. YAML parsing (adapter.ex:338-383) — SAFE ✅

`YamlElixir.read_from_file/1`. YamlElixir produces **plain maps/lists/strings**, never
atoms or structs from arbitrary keys (it does not honor YAML `!!` tags into Elixir
structs, and keys stay binaries — confirmed by the code only ever indexing with
string literals like `manifest["name"]`, `m["id"]`). No `binary_to_term`, no
`Code.eval`, no struct coercion. `read_yaml/1` rejects non-map roots
(adapter.ex:341). Optional readers swallow errors to `nil`/`[]` (adapter.ex:346-353),
which is safe (fails closed to engine defaults).

### 4. Command-text scanning (detect.ex) — SAFE ✅ (bounded)

`count_cmds/2`, `any_cmd?/2`, `bash_commands/1` use `String.contains?/2` over
transcript Bash text — **no interpolation, no eval, no shell execution**. The
transcript text is only ever *read/compared*, never executed. Work is linear in
(#commands × #needles); needle lists come from the adapter (bounded by pack size),
command text from the transcript (bounded by session size). No unbounded blow-up here.
`to_string(tu.input["command"] || "")` (detect.ex:593) guards non-binary input.

### 5. Privacy — NO REGRESSION ✅

No new code path emits raw transcript text or transcript file paths. `detect.ex` has
zero `IO.inspect`/`Logger`/`IO.puts` calls (grep-confirmed). All public functions
return **aggregates** (counts, scores, skill-name lists, percentages). `used_skills/2`
returns only short skill *names*, not surrounding text. `files_edited/1` is used only
for a `length(files) > N` count, never surfaced. Moat (aggregates-only) intact.

## Findings

### Untrusted regex reaches `Regex.compile!` — crash / DoS
- **Severity**: Medium
- **Location**: `lib/faber/detect.ex:581` (`skill_namespace_regex/1`); same class at
  `lib/faber/adapter.ex:158` (`glob_regex/1` via `Regex.compile!`).
- **Issue**: `skill_namespaces` comes from the adapter pack and is validated only as
  "a list of strings" (adapter.ex:116-119) — there is **no validity check that the
  compiled regex will succeed, and no rescue**. While `Regex.escape/1` neutralizes
  metacharacters in *content*, an empty `skill_namespaces` would never reach here (the
  `namespaces == []` guard at detect.ex:526 short-circuits), but a list containing an
  **empty string** yields `alt = ""` producing pattern `"(?::([a-z]...))"` which still
  compiles — however a namespace containing a NUL byte or invalid UTF-8 (YAML can
  carry these) makes `Regex.compile!/2` **raise**, crashing the scan of an otherwise
  valid session. `glob_regex/1` (adapter.ex:152-159) has the same exposure on
  `file_globs` (e.g. a glob `{` with no close is split oddly; `Regex.escape` covers
  most, but `compile!` still bangs on malformed UTF-8). The `!` variant turns a data
  problem into a process crash rather than a validation error.
- **Fix**: compile defensively and fail to engine-default behavior, OR validate at
  load time. Prefer load-time validation so a bad pack is rejected with a message
  rather than crashing mid-scan:
  ```elixir
  # detect.ex
  defp skill_namespace_regex(namespaces) do
    alt = Enum.map_join(namespaces, "|", &Regex.escape/1)
    case Regex.compile("(?:#{alt}):([a-z][a-z0-9_-]*)", "i") do
      {:ok, re} -> re
      {:error, _} -> ~r/(?!x)x/  # never-match: skip text extraction, fail closed
    end
  end
  ```
  And in `Adapter.validate/1`, attempt the compile for `skill_namespaces` and each
  `file_globs` entry, appending a human-readable problem on `{:error, _}` so malformed
  packs are rejected at `load/1`.
- **OWASP**: A05:2021 (Security Misconfiguration / improper input handling) — DoS.

### Adapter-controlled regex alternation — ReDoS
- **Severity**: Low
- **Location**: `lib/faber/detect.ex:581`, run at `Regex.scan(re, e.text, ...)`
  (detect.ex:533) over transcript text.
- **Issue**: Although each namespace is `Regex.escape`-d, a pack with a very large
  number of namespace alternatives, combined with adversarial transcript text, raises
  the matcher's work. The pattern shape `(?:a|b|...):([a-z]...)` is not classically
  catastrophic (no nested quantifier over the alternation), so true exponential ReDoS
  is **unlikely**; risk is linear-ish slowdown bounded by pack size. Real exposure is
  low because the pack author is the trust boundary and packs are local. Note for
  completeness; no fix required beyond a sane cap on `skill_namespaces` length if you
  ever accept third-party packs over a network.
- **OWASP**: A05 / CWE-1333.

## Security Posture

Checked authz, atom exhaustion, SQL injection, XSS, unsafe deserialization, command
injection, and privacy/aggregate-leakage across the diff: all clean except the two
regex-compile findings above. `atomize_when/1` and the YAML readers are exemplary
fail-closed designs.

## Tools to Recommend (run manually — this agent has no Bash)
- `mix sobelow --exit medium`
- `mix deps.audit`
- `mix hex.audit`
