# Faber — Tidewave handoff

Orientation for an agent working on Faber **through Tidewave's MCP** (runtime introspection
against the live dev node). Read [`../HANDOFF.md`](../HANDOFF.md) for the product thesis and
[`../CLAUDE.md`](../CLAUDE.md) for the conventions — this file only covers what's different when
you have a running node to interrogate.

---

## 1. Boot the node first

Tidewave talks to a **running dev server**. Nothing below works until one is up:

```sh
mix deps.get
iex -S mix phx.server        # → http://localhost:4010
```

`mix phx.server`, **not** `iex -S mix`. `config/dev.exs` deliberately omits `server: true`,
because `mix faber.scan` and every other mix task boot the same OTP app — a listener bound in
dev config would make them all die on `:eaddrinuse` whenever the dashboard is running.
`phx.server` opts the listener in for the one entrypoint that wants it.

Two MCP servers live on that port, and they are **not** the same thing:

| URL | What | Scope |
|---|---|---|
| `http://localhost:4010/tidewave/mcp` | **Tidewave** — introspect the running node | dev only |
| `http://localhost:4010/mcp` | **Faber's own** read-only MCP (friction, skills) | Faber's product surface |

`faber serve` (the shipped binary) serves only the latter, on `4710`. Tidewave is `only: :dev` in
`mix.exs` and its endpoint plug is behind a compile-time `Code.ensure_loaded?/1` guard, so the
release contains no trace of it — it evaluates arbitrary code against the node, and that must
never ship.

Register it once:

```sh
claude mcp add --transport http tidewave http://localhost:4010/tidewave/mcp
```

---

## 2. What Tidewave gives you here — and what it doesn't

Faber has **no Ecto and no database**. It scans the filesystem read-only. So Tidewave exposes
exactly four tools for this app, and the SQL/schema half of its toolkit is simply absent:

| Tool | Use it for |
|---|---|
| `project_eval` | run Elixir against the live node — the main event (see §3) |
| `get_logs` | read what the app logged, excluding your own tool calls |
| `get_source_location` | jump to a module/function definition |
| `get_docs` | docs at **this project's** locked versions, not latest |

Don't go looking for `execute_sql_query` or `get_ecto_schemas`; there's no repo to point them at.

---

## 3. project_eval recipes

All verified against the current tree.

**Load the adapter** (the stack-awareness — Iron Laws, eval criteria):

```elixir
{:ok, a} = Faber.Adapter.load(Faber.adapter_dir())
{a.name, a.eval["mode"]}
#=> {"faber-elixir", "exec-in-place"}
```

**Scan for friction** — always against `test/fixtures`, never your real `~/.claude` history,
unless you specifically mean to. Fixtures are fast, deterministic, and 5 results wide:

```elixir
Faber.Scan.run(base: "test/fixtures", min_messages: 0)
|> Enum.take(3)
|> Enum.map(&{&1.fingerprint, &1.raw, &1.tier2})
```

**Cap your output.** Scan results are fat structs and a real scan is hundreds of sessions.
`Enum.take/2` and `inspect(x, limit: 50, printable_limit: 500)` before you dump anything.

**Propose + eval** — this spends tokens (`claude -p`) and takes ~60s. Deliberate, not casual:

```elixir
result = Faber.Scan.run(base: "test/fixtures", min_messages: 0) |> hd()
{:ok, adapter} = Faber.Adapter.load(Faber.adapter_dir())
{:ok, proposal} = Faber.Propose.propose(result, adapter)
{:ok, eval} = Faber.Eval.score(proposal, adapter: adapter)
{eval.composite, eval.passed, eval.threshold}
```

In `MIX_ENV=test` the LLM is `Faber.LLM.Stub` and returns deterministic proposals — but you're on
a **dev** node here, so the real `claude -p` runs.

**Inspect the dashboard's LiveView state** (get the PID from the browser, or via the registry):

```elixir
pid = pid("0.1234.0")
:sys.get_state(pid).socket.assigns |> Map.take([:scanning, :proposing, :total, :tier2])
```

---

## 4. Gotchas that will bite you

- **The eval gate is a renderer guarantee, not a prompt wish.** If a generated skill fails a
  deterministic check, fix `Faber.Propose.render_skill_md/2` so it satisfies the check *by
  construction*. Never clamp or truncate content to force a proxy green — that games the metric
  against its intent. See `CLAUDE.md` § "Generators & eval gates".
- **`adapters/` is untrusted declarative input.** Anything becoming a regex or atom is validated at
  `Faber.Adapter.validate/1`, with a fail-closed runtime guard. Don't move validation deeper.
- **Don't touch the plugin repo** (`elixir-live-claude-engineer`). Faber *reads* it to assemble the
  `faber-elixir` adapter; the whole extraction premise is zero diffs there.
- **`get_docs` returns your locked versions.** That's the point — don't cross-check it against
  hexdocs' latest and "correct" it.
- **The gate is `mix verify`** (format · compile --warnings-as-errors · credo --strict · dialyzer ·
  test), and it's an Iron Law before every commit. `project_eval` proving something works at runtime
  does **not** substitute for it.

---

## 5. Logging

The dev node is verbose on purpose. The **release** is not: `config/prod.exs` ships `faber serve`
quiet (Logger at `:info`, Phoenix's logger detached, `Plug.Telemetry` off) because its console is
the user's terminal, not a log aggregator. If you're debugging a built binary and need the
per-event narration back:

```sh
FABER_LOG_LEVEL=debug faber serve
```

Faber's own `Logger.info` calls (e.g. `Faber.Eval`'s "adapter eval is exec-in-place…") survive the
prod defaults by design — it's the *framework's* chatter that's suppressed, not Faber's voice.
