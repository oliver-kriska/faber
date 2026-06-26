# Test Review: faber-python adapter test suite

## Summary

The new and modified test files are well-structured and largely follow the iron laws. No Mox is used (no boundaries are mocked here — the Stub LLM is a genuine behaviour implementor). Async is used throughout. The most significant findings are around `setup_all` shared state safety, one implicit hardcoded-path assertion, and a subtle parity-test tautology risk.

## Iron Law Violations

None outright violated. All modules use `async: true`. No `Process.sleep`. No DB involved (no Ecto sandbox needed). No Mox usage at all. `build` vs `insert` is irrelevant (no ExMachina). All LLM test doubles implement `@behaviour Faber.LLM`.

## Issues Found

### Critical

None.

### Warnings

- **`faber_python_test.exs` — `setup_all` with filesystem reads across async tests (lines 19–24)**
  `setup_all` shares loaded adapter structs and parsed events across all tests in the module. The adapter load and fixture parse are pure/immutable, so there is no write-side race — this is acceptable. However, because the assert `{events, []} = Ingest.parse_file(@fixture)` is inside `setup_all` (not `setup`), a parse failure silently skips all 7 tests rather than failing each one with a clear message. Consider whether a `setup` block is more appropriate for surfacing failures.

- **`faber_python_test.exs` L47 — hardcoded fixture path assertion**
  ```elixir
  assert paths == ["/Users/x/Projects/pyapp/src/parser.py"]
  ```
  This asserts the *exact content* of the fixture (a single file path), coupling the test to fixture internals. If the fixture gains a second file reference (e.g., to expand coverage), this assertion breaks even though the meaningful gate (`.py` extension → Python adapter match) still holds. The assertion should instead be:
  ```elixir
  assert Enum.all?(paths, &String.ends_with?(&1, ".py"))
  assert Adapter.matches_session?(py, paths)
  refute Adapter.matches_session?(ex, paths)
  ```
  The `matches_session?` assertions below already prove the stack-gating behavior; the path equality check is testing the fixture, not the adapter.

- **`detect_test.exs` — parity test is not a genuine regression guard for the nil-adapter path (lines 288–317)**
  The parity test asserts `Detect.fingerprint(events, a) == Detect.fingerprint(events)` for 9 probes, where `a` is the faber-elixir adapter. This only guards one direction: that adding the faber-elixir adapter to the call doesn't change results. It does NOT guard against the nil-adapter path being changed to disagree with the adapter — both sides of `==` would change together if the engine defaults drift. A true regression guard would fix one side as a snapshot (e.g., assert the specific `%{type: "maintenance"}` result against the fixture, not just equality between two live calls). As written, it would pass even if both code paths were broken identically.
  **Severity**: Warning (it still catches divergence between the two paths, which is the primary contract; it just doesn't catch joint regressions).

- **`adapter_test.exs` L56 — `/tmp` path in test fixture helper**
  `write_adapter/2` uses `System.tmp_dir!()` (line 228), which is system temp rather than the project scratchpad. This is fine for correctness (it uses `System.unique_integer` for uniqueness and `on_exit` cleanup), but on macOS `System.tmp_dir!()` returns `/var/folders/...` which is pruned between reboots; a long-lived CI job could theoretically lose the dir mid-run. Not a practical risk here. No change required unless CI shows spurious failures.

- **`adapter_test.exs` — `verify.unless_used == true` default not asserted explicitly (line 121)**
  The inline assertion `verify.when == :commands and verify.commands == ["pytest"] and verify.threshold == 3` tests three fields inline but leaves `unless_used` to the later structural match on `review`. The YAML for the `verify` rule does NOT set `unless_used`, yet the struct defaults it to `true` (per the `review` match). This default is significant (it suppresses already-used skills) but is never directly asserted for the `verify` rule. Worth making explicit:
  ```elixir
  assert verify.unless_used == true
  ```

### Suggestions

- **`faber_python_test.exs` L37 — law/playbook count assertions are fragile implementation-detail checks**
  `assert length(py.laws) == 15` and `assert length(py.playbooks) == 7` are exact counts. These will break whenever a law or playbook is added to the adapter, even if the new content is correct. Consider asserting presence of a specific notable entry (e.g., a law with a known id) rather than total count, unless the count itself is a contract requirement.

- **`detect_test.exs` — novel fingerprint type with empty `skill_namespaces` is covered in the adapter vocab tests, but the `data-migration` type probe (line 203) only asserts the type is emitted, not that it doesn't appear in adapter-free fingerprinting**. The test comment implies the point is "novel types can be introduced by adapters", but there's no corresponding `refute` that the adapter-free path does not produce `"data-migration"`. Minor.

- **`propose_test.exs` L297 — relative path `"adapters/faber-elixir"` in test**
  `Adapter.load("adapters/faber-elixir")` (line 297) uses a relative path. This works when tests run from the project root (`mix test`), but is fragile to cwd changes. The other test files consistently use `Path.expand("../../adapters/faber-elixir", __DIR__)`. Align for consistency:
  ```elixir
  Path.expand("../../adapters/faber-elixir", __DIR__)
  ```
