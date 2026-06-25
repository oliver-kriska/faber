# Review — dogfood-driven proposer + install-provenance changes

**Scope:** `git diff 874ee99 HEAD` — 9 files, +341/−37.
Commits: `dfd9cd5` (Workflow/Patterns), `4e12f33` (≥2-line worked example), `5d1032d` (provenance marker).
**Reviewers:** elixir-reviewer, security-analyzer, testing-reviewer (3 parallel specialists).

## Verdict: **PASS WITH WARNINGS**

Code is correct, secure, and fully tested (`mix test` 251 / `mix test.full` 256 green; `compile --warnings-as-errors` clean). **0 real blockers.** The findings are all test-strengthening or micro-idiom — none block.

> Severity note: testing-reviewer labelled 3 items "BLOCKER". After verifying each against the code (the review's anti-noise filter), none break code or tests — they are coverage/naming gaps. Re-graded to WARNING/SUGGESTION below with the evidence.

---

## WARNINGS (worth fixing)

### W1 — `@schema` workflow/patterns keys are unguarded (testing #1, re-graded)
`test/faber/propose_test.exs:88-89`. The `build_prompt` test asserts the *prose* ("workflow:"/"patterns:") in the system prompt — correct for that function (build_prompt doesn't touch the schema). BUT **no test asserts `Propose.schema()` contains `:workflow`/`:patterns`**, and `Faber.LLM.Stub` returns `stub_response` verbatim (ignores `_schema`, stub.ex:14) — so the mapping test passes regardless of the schema. Dropping the schema fields would ship silently.
- **Fix:** one assertion — `assert Keyword.has_key?(Propose.schema(), :workflow)` (+ `:patterns`).

### W2 — `has_examples` tests fully delegate to the matcher (testing WARNING)
`propose_test.exs` (the three `has_examples` assertions). They assert via `Faber.Eval.Matchers.has_examples/2`, so a matcher regex change would silently "validate" them without the renderer independently guaranteeing ≥2 fence lines.
- **Fix:** add one structural assertion that counts non-empty lines inside the rendered fence directly (decouples the renderer guarantee from the matcher).

### W3 — `drop_nils` empty-source path untested (testing WARNING)
The privacy/provenance marker test only covers a *populated* `source`. No test installs a `%Proposal{}` with `source: %{}` to prove `drop_nils/1` omits the nil `adapter`/`source_session`/`fingerprint` keys.
- **Fix:** add a case asserting the marker has only `installed_by` + `name` when source is empty.

### W4 — "eval-passing" test name overpromises (testing WARNING)
`propose_test.exs:217` "…produces a complete, eval-passing skill" only asserts structural markers; it never calls the scorer.
- **Fix (better):** actually score it — `Faber.Eval.Native.score(md, …)` and assert composite ≥ threshold. That turns the name into a real guarantee and gives an end-to-end eval test. (Or rename.)

### W5 — misleading "atom keys" test title (testing #3, re-graded; **pre-existing**)
`propose_test.exs:105` titled "(atom keys)" but the map uses string keys throughout, so the atom branch of `get/2` is never exercised. Pre-existing (I only added the workflow/patterns assertions here).
- **Fix:** rename to "(string keys)" or add an atom-keyed variant to cover the fallback.

### W6 — `frontmatter/2` compiles a regex per call (elixir WARNING; **pre-existing**)
`install.ex` `frontmatter/2` builds `~r/^#{field}:…/m` at runtime. `field` is always an internal literal ("name"/"description"), so it's benign, but it loses compile-time caching and runs per `skill_summary`.
- **Fix:** two module-level compiled regexes.

---

## SUGGESTIONS (optional)

- **S1 (testing #2, re-graded):** `install_test.exs:97` hardcodes `== ["faber-one", "users-own"]` — deterministic (list sorts by name) and correct, just brittle in form. Could assert membership instead.
- **S2 (security 4b):** `usage_block` interpolates LLM `example`/`usage` raw inside a ```` ```bash ```` fence; a ```` ``` ```` in the value closes it early. Local skill file, not a web sink → worst case cosmetic content-spoofing, no RCE/leak. Optional: neutralize fence sequences.
- **S3 (security 4c):** multi-line `workflow`/`patterns` entries can inject markdown structure (cosmetic). Optional: collapse newlines per item.
- **S4 (elixir):** make public `render_skill_md/1` a private `render_builtin/1` (it's an impl detail of the 2-arity dispatch). *Note:* it's currently called directly by tests and `Faber.Install`/`Faber.Optimize`, so this is an API change, not free.
- **S5 (elixir):** flatten the `if/else`-with-`with` in `install({name, md}, …)` via a `guard_exists/2` helper.
- **S6 (elixir):** `present/1` returns the untrimmed original after a `String.trim` check — a leading-whitespace `example` embeds as-is. Intentional (preserves formatting); note only.

---

## Security & privacy — explicitly cleared
- **Marker path traversal:** PASS. `validate_name/1` (anchored `\A…\z`) runs before any path is computed; `SKILL.md`, `mkdir_p`, and the marker all target the one validated `skill_dir`.
- **Privacy boundary (moat):** PASS, genuinely tested. Provenance is exactly `{adapter, source_session, fingerprint}`; `p.source[:path]` is never read; `install_test.exs:59-79` plants a secret path and asserts it appears in neither the marker nor the body.
- **MCP `get_skill`:** PASS. Resolves by equality against the discovered listing; a path-y name → not-found, never a `File.read`.

## Not run (and why)
- **verification-runner:** work phase already green (format, compile --warnings-as-errors, test 251, test.full 256).
- **iron-law-judge:** no OTP/process code in the diff (pure functions + file IO); the PostToolUse format hook ran on every edit.
- **requirements-verifier:** no Linear/GitHub/plan requirements source for this work.
