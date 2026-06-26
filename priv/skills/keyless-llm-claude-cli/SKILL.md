---
name: keyless-llm-claude-cli
description: "Add a real, KEYLESS LLM call to an Elixir app by shelling out to the local `claude -p` CLI behind a behaviour, so the feature's real path can be live-tested for free (no API key, no secret in CI, no per-run cost). Use when an LLM-backed feature is only ever tested against a stub, when you want one :live smoke test that drives the whole pipeline through a real model, or when you need a dev/test LLM backend without managing keys. Generalizes to any local agent CLI (codex, etc.)."
effort: medium
argument-hint: ""
allowed-tools:
---

# Keyless LLM via the `claude` CLI

Code whose headline feature calls an LLM is usually tested only against a stub — so the
*real* path (a real model producing usable output that flows through the rest of the
pipeline) never runs. A true live test normally needs an API key (cost, secrets, CI
flakiness), so it gets skipped forever and the feature stays unproven.

If `claude` (Claude Code CLI) is on PATH, you can run a real generation **keyless** on the
existing subscription: `claude -p "<prompt>" --output-format json`. Coax structured output
by appending a "return ONLY JSON with these fields" instruction to `--append-system-prompt`,
then parse the envelope's `result`. Wrap it as **one backend behind your LLM behaviour**, and
write **one** `:live`-tagged smoke test that drives the whole feature through it.

This is the pattern behind `Faber.LLM.ClaudeCLI` + `mix test.live`.

## Iron Laws - Never Violate These

1. **Redirect stdin from `/dev/null`.** `System.cmd/3` can't close the child's stdin, so
   `claude -p` waits ~3s for piped input that never comes (`no stdin data received in 3s`)
   and stalls. Wrap the invocation in `sh -c '… < /dev/null'`.

2. **Pass every dynamic value through the ENVIRONMENT, never the command string.** Prompt and
   system content are untrusted text — interpolating them into the shell script is a
   word-split / injection hole. Bind them as env vars and reference `"$FB_PROMPT"` inside the
   script. Use `${VAR:+--flag "$VAR"}` to omit empty optional flags.

3. **Tag the live test `:live` and EXCLUDE it by default.** `mix test` and CI must stay
   hermetic (no shell-out, no model) — only an explicit `mix test.live` runs it.

4. **Set a generous `@moduletag timeout:`.** A real generation is ~60–90s; ExUnit's default
   test timeout is 60_000ms and WILL flake. Use `timeout: 240_000` or similar.

5. **Assert STRUCTURE, never content.** The model is nondeterministic — assert shape (regex,
   type) and a sane floor with margin (`score >= 0.6`), never substrings of the model's prose
   or the strict production gate value.

## Usage

```
# The keyless backend powers a real generation on your existing Claude Code auth.
mix test.live          # runs only the :live-tagged smoke test against a real model
mix test               # default suite stays hermetic — backend never invoked
```

## Workflow

1. Define an `Faber.LLM`-style behaviour with a `generate_object(prompt, schema, opts)` callback.
2. Implement a CLI backend: resolve the binary, build the system prompt + JSON-shape
   instruction, shell out injection-safely, parse the envelope then the JSON object.
3. Add a `:live` smoke test driving the whole feature; wire `test.live` alias + exclude tag.

```elixir
# Backend — injection-safe shell-out, no key (see Laws 1 & 2)
defp run(bin, prompt, system, model) do
  script =
    ~s(exec "$FB_BIN" -p "$FB_PROMPT" --output-format json) <>
      ~s( ${FB_SYS:+--append-system-prompt "$FB_SYS"}) <>
      ~s( ${FB_MODEL:+--model "$FB_MODEL"} < /dev/null)

  env = [{"FB_BIN", bin}, {"FB_PROMPT", prompt},
         {"FB_SYS", system}, {"FB_MODEL", to_string(model || "")}]

  case System.cmd("sh", ["-c", script], env: env, stderr_to_stdout: false) do
    {out, 0} ->
      with {:ok, text} <- parse_envelope(out),     # JSON envelope.result → text
           {:ok, obj}  <- extract_json(text) do    # text → object (tolerate fences/prose)
        {:ok, obj}
      else _ -> {:error, {:claude_cli_parse, out}} end

    {out, code} -> {:error, {:claude_cli_exit, code, out}}
  end
rescue
  e in ErlangError -> {:error, {:claude_cli_unavailable, e}}
end

# Envelope parse — claude --output-format json wraps the text in `result`.
def parse_envelope(out) do
  case Jason.decode(out) do
    {:ok, %{"result" => t}} when is_binary(t) -> {:ok, t}
    {:ok, %{"text"   => t}} when is_binary(t) -> {:ok, t}
    _ -> {:ok, out}   # not the expected envelope — treat raw output as text
  end
end
```

```elixir
# The single live smoke test (Laws 3-5)
defmodule MyApp.LiveSmokeTest do
  use ExUnit.Case, async: false
  @moduletag :live              # excluded by default
  @moduletag timeout: 240_000   # a real generation is ~60-90s

  test "the real feature works end to end against a real model" do
    {:ok, out} = MyApp.run(input, llm: MyApp.LLM.ClaudeCLI, model: "sonnet")
    assert is_binary(out.name) and out.name =~ ~r/\A[a-z0-9-]+\z/   # shape, not content
    assert out.score >= 0.6                                          # floor with margin
  end
end
```

```elixir
# test/test_helper.exs
ExUnit.configure(exclude: [:live, ...])
# mix.exs
"test.live": ["test --include live"]   # preferred_envs: ["test.live": :test]
```

## Patterns

- **Why it's worth it:** proves the feature for real, for free (no key/secret/per-run cost),
  keeps the default suite hermetic, and catches integration drift unit/stub tests can't —
  schema actually accepted, prompt actually yields parseable structured output, the
  downstream gate actually accepts real output.
- **Keep parse helpers pure + unit-tested** (`render_schema/1`, `parse_envelope/1`,
  `extract_json/1`); only the `generate_object/3` I/O shell-out is impure.
- **Generalizes** to any local agent CLI (codex, etc.): one keyless backend + one `:live`
  test per agent.

## References

- Faber: `lib/faber/llm/claude_cli.ex`, `test/faber/live_propose_test.exs`, `mix test.live`.
- Pattern note: `.claude/scriptorium/2026-06-25-keyless-llm-smoke-test-via-claude-cli.md`.
