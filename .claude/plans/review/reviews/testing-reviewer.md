# Test Review: test/faber/propose_test.exs + test/faber/install_test.exs

## Summary

Both files are structurally sound: `async: true`, no DB (no Sandbox needed), no Mox (FailingLLM is a proper behaviour-backed double, not a Mox mock so no verify_on_exit! applies), and `@tag :tmp_dir` used correctly throughout. The tests cover the stated claims but several assertions are weak enough to survive a regression, and a few meaningful edge cases are absent.

---

## Iron Law Violations

None.

---

## Issues Found

### BLOCKER

- **propose_test.exs:74–90 — `build_prompt` test asserts `"workflow:"` and `"patterns:"` but these strings appear in the *field names listed in the system-prompt body* ("workflow: 3–6 ordered, imperative steps…"), not from any Adapter data.** If the system-prompt prose is later reworded to drop the colon (e.g. "workflow (3–6 steps)") the test breaks for the wrong reason. More importantly, the claim is *"the proposer asks for workflow/patterns"* — but the real claim to lock in is that those fields appear in the **@schema** (the structured-output contract). The test as written would also pass if `@schema` dropped `:workflow` and the prompt still happened to contain the word "workflow:" — the actual object-mapping test is what locks the schema. Consider asserting against `Propose.schema()` directly, or at minimum anchoring the string to how the schema is threaded into the prompt, not the prose description bullet.

- **install_test.exs:83–98 — `list_faber_installed` ordering assumption.** `assert names == ["faber-one"]` is fine here (single element), but `list_installed` assertion on line 97 asserts `== ["faber-one", "users-own"]` relying on alphabetical ordering from `Enum.sort_by(& &1.name)`. With these two names the sort is stable, but the assertion is fragile by form — any future skill whose name sorts before "faber-one" breaks this. Use `assert Enum.member?(names, "faber-one")` / `refute Enum.member?(names, "users-own")` or `assert Enum.sort(names) == [...]`. Not a bug today but misleading to future readers.

- **propose_test.exs:105–119 — `stub_response` uses string keys but comment says "atom keys".** The docstring on the test says "maps a custom stub_response (atom keys)" yet the map literal uses string keys (`"name"`, `"description"`, etc.). `LLM.Stub` returns exactly what it's given; `build_proposal` calls `get/2` which tries atom key first then falls back to string key. The test never exercises the atom-key path it advertises. This is misleading: a reader assumes atom-key handling is covered when it isn't. Either rename the test or add a companion that passes `%{name: "tidy-migrations", …}` with atom keys to prove `get/2`'s fallback branch.

### WARNING

- **propose_test.exs:161–178 — `render_skill_md` Workflow/Patterns test does not assert absence of `## Workflow` / `## Patterns` when empty.** The empty-list case is tested in the *next* test, but the present-case test never checks that the workflow appears *only once* (no duplicate section). Low risk but the complementary check costs one `refute`.

- **propose_test.exs:190–203 — `has_examples` tests delegate entirely to `Faber.Eval.Matchers.has_examples/2`.** If the matcher's fence regex (```` ```[\w]*\n(.*?)``` ````/s) changes — e.g. to require a language tag — these tests silently pass because the matcher is the unit under test, not the renderer. The tests prove the current renderer produces output the current matcher accepts; they do not prove the renderer emits a fence with `>=2` non-empty lines independently. Add one assertion like `assert Regex.match?(~r/```\w*\n[^\n]+\n[^\n]+/, md)` so the structural guarantee survives a matcher refactor.

- **install_test.exs:59–80 — `%Proposal{}` marker test does not verify `source_session` is absent when `p.source` is `%{}` (empty map / nil session).** The plain `{name, md}` path (line 50–56) is tested for the minimal marker, but the Proposal path is only tested with a fully-populated source. If `drop_nils/1` or `build_proposal` changes and starts leaking `nil` keys, no test catches it. Add a test: install a `%Proposal{}` with `source: %{}` and assert the marker lacks `"source_session"` and `"fingerprint"` keys entirely.

- **install_test.exs:178–194 — `write_unmanaged_skill` helper is defined at module scope (line 211–216) but `install_skill/3` at line 205–208 calls `Install.install/2` without `force: true` except when it does.** The cross-agent pointer test's `setup` calls `install_skill(skills, "alpha", …)` without `force: true` and relies on the skills dir being fresh each time (tmp_dir guarantees this). However `install_skill` hard-codes `force: true` which silently masks any double-install bugs. Not blocking today, but it hides bugs if a future test intentionally tries to install the same skill twice.

- **propose_test.exs:233–241 — "real faber-elixir template produces a complete, eval-passing skill"** — asserts only three markers (`name`, `## Iron Laws`, `## References`). This does not actually verify eval passes (no `Faber.Eval.Native.score/2` call). The test name overpromises. Rename to "renders expected sections via the real adapter template" or call `Eval.Native.score/2` and assert overall pass.

### SUGGESTION

- **propose_test.exs — No test for multi-element `workflow`/`patterns` numbering continuity.** The present test uses a 2-step workflow; correct numbering for 3+ steps (to guard against an off-by-one in `Enum.with_index(1)`) is not tested.

- **propose_test.exs — No test for whitespace-only `usage`/`example` fields via `present/1`.** The nil fallback is covered (line 200), but `p.usage = "   "` (whitespace-only string) should produce the same fallback comment. The `present/1` private function handles this — it is exercised only through `render_skill_md` and is worth a targeted test case.

- **install_test.exs — No test for force-reinstall marker behavior.** When `force: true` overwrites a skill, the test (line 15–22) verifies the SKILL.md content is replaced but does not assert the `.faber.json` marker is also updated (or still present). If `write_marker` is not called on force-overwrite, the marker would still exist from the first install, but its content might be stale.

- **install_test.exs:101–107 — `setup` in `"cross-agent pointers"` describe uses `install_skill/3` but that helper in turn calls `Install.install/2` which writes a `.faber.json` marker.** This is correct for the pointer tests (which rely on `list_faber_installed`). Worth a comment clarifying the dependency so a future refactor of `install_skill` to use `write_unmanaged_skill` would not silently break the pointer filter tests.

- **General — No test for `render_skill_md/1` when `iron_laws` is empty.** The struct's default is `[]`, and `render_skill_md` would emit `## Iron Laws — Never Violate These\n\n` with no items. `has_iron_laws` would then return `{false, "no Iron Laws section"}` (items = 0 < min 1). This edge case is reachable if `get_list/2` returns `[]` (e.g. LLM returns a non-list), so a test asserting `render_skill_md(%Proposal{name: "x", …, iron_laws: []})` still emits valid (if empty) Markdown would clarify the intended contract.
