# Test Review: commits 06248b5^..HEAD — deferred-features batch

## Summary

The new tests are materially better than the prior stub era. Coverage is genuine: the managed-block
tests exercise real idempotency/tamper semantics; the no-egress tests use BEAM tracing with a
positive-control that would catch a silent tracer no-op; the privacy test proves the allowlist
exhaustively; the Optimize stubs implement a real `@behaviour` and cover every response branch; the
Python optimizer tests inject a fake runner and never touch dspy or a provider. Verdict: **APPROVE
with fixes for two blockers and three warnings.**

---

## Iron Law Violations

None outright violated. `async: false` is correct for both no-egress modules and the CLI test (IO
capture + Application.put_env). `async: true` is correct everywhere else. No Mox in scope.

---

## Issues Found

### Critical / BLOCKER

- [ ] **`server_test.exs:35` — `start_supervised!` leaks into the next test's process registry.**
  The "boots cleanly" test calls `start_supervised!({Server, transport: {:streamable_http, start: true}})`.
  ExUnit's `start_supervised!` ties the child to the *test process*; when that process exits the
  Anubis supervisor tree is killed. However `Anubis.Server.Registry` is a named registry
  (`Registry.supervisor_name(Server)` → a well-known atom). If any subsequent test in the same
  async-grouped run (or a retry) queries that name before teardown completes, it can observe a
  transiently registered name and produce a false result.
  The immediately preceding test in the same describe block (`refute Process.whereis(...)`) runs
  first and asserts the name is absent — that sequencing depends entirely on ExUnit's within-module
  ordering (guaranteed) but is fragile if the boot test is ever reordered or the module is
  async-grouped with another module that also inspects the registry.
  **Fix:** add `on_exit(fn -> :ok end)` after `start_supervised!` is fine as-is for teardown, but
  add an explicit `assert Process.alive?(pid)` (not just `is_pid`) to verify the tree is
  *actually* running and not in a startup crash — `start_supervised!` succeeds as long as
  `start_link` returns `{:ok, pid}`, even if children crash immediately after. Without
  `Process.alive?` the test proves "started without raising" not "stays alive."

- [ ] **`no_egress_test.exs` (MCP) — positive-control module may not be correct for the MCP path.**
  `@control_mfa {Faber.Scan, :run, :_}` is a *public* function. `:erlang.trace_pattern` with
  `[:local]` covers local (unexported) calls on any module but public functions are also captured
  when they are the direct call target. The concern is whether `Faber.Scan.run/1` is always called
  directly by `SearchFriction.execute/2` in a way that fires the trace in the same process or a
  spawned one. Looking at `SearchFriction.execute/2`, it calls `Scan.run(opts)` synchronously in
  the calling process — so the trace *will* fire. However, the collector's `collect/1` never
  terminates (it loops on `receive`), meaning if the `:dump` message arrives while a `:trace`
  message is in-flight the collector replies before draining the mailbox. The `flush_trace_delivery`
  call already guards against late arrivals, but `collect/1` processes messages sequentially: it
  could reply to `:dump` before processing a `:trace` that is already in the mailbox *after* `{:dump,
  ref, to}` matched. This is because Elixir's `receive` picks the *first matching* message from the
  mailbox, not the first-arrived. If a `:dump` is already in the mailbox when `:trace` messages are
  arriving, the collector drains `:dump` first.
  **Fix:** change `collect/1` to drain all pending `:trace` messages before replying to `:dump`:
  ```elixir
  defp collect(acc) do
    receive do
      {:trace, _pid, :call, {mod, fun, _args}} -> collect([{mod, fun} | acc])
      {:dump, ref, to} ->
        # Drain any in-flight trace messages already in our mailbox before replying.
        acc = drain_traces(acc)
        send(to, {:calls, ref, acc})
    end
  end

  defp drain_traces(acc) do
    receive do
      {:trace, _pid, :call, {mod, fun, _args}} -> drain_traces([{mod, fun} | acc])
    after
      0 -> acc
    end
  end
  ```
  The same race exists in the base `Faber.NoEgressTest` (same pattern). Both should be fixed
  together.

### Warnings

- [ ] **`tools_test.exs:54-80` — privacy test proves the allowlist at the *Elixir struct* level but
  not the *JSON wire* level.**
  `summarize/1` returns an atom-keyed map; `json_reply/1` decodes to string keys. The privacy test
  in `test "PRIVACY: ..."` checks that the raw phrase is absent from the concatenated JSON text,
  which is the real boundary (good). But `test "summarize/1 exposes exactly the aggregate allowlist"`
  only checks `Map.keys()` of the Elixir map, not the JSON-serialised output. If `Jason.encode!`
  were to include extra derived keys (e.g., via a `@derive` or a protocol override on `Scan.Result`
  that leaks `path`), the allowlist test would miss it.
  **Fix:** add one assertion inside the allowlist test that also encodes the summarized map and
  confirms the JSON keys match the expected string set, tightening the contract to the actual wire
  format.

- [ ] **`cli_test.exs:61-84` — `propose --install` test only checks the wildcard glob succeeds,
  not that the installed file contains the expected skill body for the fixture.**
  `assert [path] = installed` + `assert File.read!(path) =~ "name:"` is a very weak post-install
  assertion — any SKILL.md header passes. The test comment says "the stub proposal's name is
  `investigate-retry-loops`" but the assertion does not verify the name, so it would pass if a
  differently-named stub were written.
  **Fix:** `assert File.read!(path) =~ "investigate-retry-loops"` (or whatever the stub produces).

- [ ] **`test_optimize.py::UnavailableReasonTests::test_api_key_detected_from_env` — wrong
  positional call, masking the test intent.**
  ```python
  self.assertIsNotNone(unavailable_reason({}, has_dspy=True))
  ```
  `unavailable_reason` signature is `(has_dspy, has_key)`. Passing `{}` (a dict) as `has_dspy` is
  falsy, so this returns the "dspy missing" reason, *not* the env-read path the test claims to
  exercise. The comment says "api_key_present reads the env; an empty env means no key" but the
  call never reaches that branch because `has_dspy={}` is falsy. The test passes for the wrong
  reason.
  **Fix:**
  ```python
  self.assertIsNotNone(unavailable_reason(has_dspy=True, has_key=False))
  # Or, to genuinely test env reading:
  with unittest.mock.patch.dict(os.environ, {}, clear=True):
      self.assertIsNotNone(unavailable_reason(has_dspy=True, has_key=_api_key_present()))
  ```

### Suggestions

- [ ] **`install_managed_block_test.exs` — no test for `upsert/2` with a body that contains the
  `FABER:BEGIN` / `FABER:END` marker strings literally.** If a user's preamble text coincidentally
  contains those strings, the regex-based replacement could mangle it. Low probability but a known
  edge case worth a single test.

- [ ] **`server_test.exs` — the supervision test only checks `is_pid(Process.whereis(...))`;
  does not verify the tools supervisor or session supervisor are alive beneath it.** The boot claim
  "registry, sessions, tools" is in the comment but only the top-level registry pid is asserted.
  One `assert length(Supervisor.which_children(pid)) > 0` would make the comment truthful.

- [ ] **`optimize_test.exs` — `@describetag :sidecar` on the real-subprocess describe block is
  correct, but there is no `@moduletag`-level exclusion guard.** The test file docstring says it
  "stays in the hermetic suite" for the stub tests, which is true. Just confirm
  `test/test_helper.exs` excludes `:sidecar` by default so the file-level tagging is never needed.
  (Informational — no action if already excluded.)
