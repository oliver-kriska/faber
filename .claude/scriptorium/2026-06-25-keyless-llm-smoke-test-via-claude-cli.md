---
scriptorium: true
action: create
title: "Keyless live LLM smoke test via the local claude CLI"
type: pattern
domain: general
tags: [testing, llm, claude-cli, elixir, exunit, smoke-test, ci]
---

# Keyless live LLM smoke test via the local claude CLI

**Problem.** Code whose core feature calls an LLM is usually tested only against a stub, so the
*real* path — a real model actually producing usable output that flows through the rest of the
pipeline — never runs. But a true live test normally needs an API key (cost, secret management, CI
flakiness), so it gets skipped forever and the headline feature stays unproven.

**Technique.** If `claude` (Claude Code CLI) is on PATH, you can run a real generation **keyless**
on the existing subscription via `claude -p "<prompt>" --output-format json` (coax structured
output by appending a "return ONLY JSON with these fields" instruction to `--append-system-prompt`,
then parse the envelope's `result`). Wrap that as one backend behind your LLM boundary, and write
**one** `:live`-tagged smoke test that drives the *whole* feature through it.

```elixir
# backend: shell out, no key
args = ["-p", prompt, "--output-format", "json", "--append-system-prompt", sys]
       ++ (model && ["--model", model] || [])
System.cmd(bin, args, stderr_to_stdout: false)   # parse JSON envelope.result → object
```

```elixir
defmodule MyApp.LiveSmokeTest do
  use ExUnit.Case, async: false
  @moduletag :live              # excluded by default
  @moduletag timeout: 240_000   # a real generation is ~60–90s — the 60s ExUnit default WILL time out

  test "the real feature works end to end against a real model" do
    {:ok, out} = MyApp.run(input, llm: MyApp.LLM.ClaudeCLI, model: "sonnet")
    # assert STRUCTURE, never exact content — the model is nondeterministic:
    assert is_binary(out.name) and out.name =~ ~r/\A[a-z0-9-]+\z/
    assert out.score >= 0.6     # a sane floor with margin, not the strict production gate
  end
end
```

Exclude it from the default + CI runs and give it its own alias:

```elixir
# test/test_helper.exs
ExUnit.configure(exclude: [:live, ...])
# mix.exs aliases
"test.live": ["test --include live"]   # preferred_envs: ["test.live": :test]
```

## Why this is worth it
- **Proves the feature for real, for free** — no key, no secret in CI, no per-run cost beyond the
  subscription you already pay for. The single most convincing test you can have.
- **Keeps the default suite hermetic** — `mix test` / CI never shell out or hit a model; only the
  explicit `mix test.live` does.
- **Catches integration drift** unit/stub tests can't: schema actually accepted, prompt actually
  produces parseable structured output, the downstream gate/pipeline actually accepts real output.

## Gotchas
- **Timeout.** ExUnit's default test timeout is 60_000ms; a real generation often exceeds it. Set
  `@moduletag timeout:` generously or it flakes.
- **Assert structure, not content.** Floors and shape, never substrings of the model's prose.
- **stdin wait.** `System.cmd` keeps the child's stdin open, so `claude -p` may log
  `no stdin data received in 3s` and stall 3s. Harmless (stderr-only) but to remove it, invoke via
  `sh -c '"$BIN" … < /dev/null'` passing dynamic values through `env:` (injection-safe).
- The same idea generalizes to any local agent CLI (codex, etc.) — one keyless backend + one
  `:live` test per agent.

Implemented in Faber (`Faber.LLM.ClaudeCLI` + `test/faber/live_propose_test.exs`, `mix test.live`,
commit 86d6e77) to prove scan → propose(real model) → eval → install end to end.
