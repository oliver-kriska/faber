# faber_eval — Python eval sidecar

The Python half of Faber. It hosts the eval matchers (ported from the plugin's
`lab/eval`) and the GEPA / DSPy optimizer. The Elixir spine reaches it over a
**subprocess boundary**: it spawns `python -m faber_eval <command>` with the JSON
request in a temp file (`--input PATH`), and reads a JSON response on stdout.

## Boundary contract (v1)

| | |
|---|---|
| Invocation | `python -m faber_eval <command>` (or console script `faber-eval`) |
| Request | one JSON object on **stdin** (canonical; empty stdin ⇒ `{}`) or via `--input PATH` — the Elixir spine uses `--input` to avoid feeding stdin from a Port |
| Response | one JSON object on **stdout**, newline-terminated |
| Diagnostics | **stderr** (stdout stays pure JSON) |
| Exit codes | `0` ok · `1` bad request (e.g. invalid JSON) · `2` unknown command |

### Commands

- **`score`** — structural eval of a proposed skill (implemented, stdlib-only, no API
  key). Ports the plugin's `lab/eval` matchers. Request: `skill_md` (or `content`),
  optional `eval` dict / `eval_set: "full"` / `refs` known-sets. The *behavioral*
  trigger eval is Elixir-side (`Faber.Eval.Trigger`), not this command.
- **`optimize`** — `dspy.GEPA` optimization of a SKILL.md against the eval matchers.
  The orchestration (capability gate, eval-matcher metric, budget clamp) is implemented
  and tested; the live dspy path needs the `gepa` extra + a provider API key, and
  degrades to `status: "not_implemented"` with a precise reason without them.

Example:

```sh
echo '{"skill_md": "---\nname: demo\ndescription: Demo skill\n---\n\n# Demo\n"}' | python -m faber_eval score
# {"command": "score", "status": "ok", "version": "0.1.0",
#  "result": {"schema_version": "1.0", "composite": 0.3917, "dimensions": {...}}}
```

## Development

Managed by [`uv`](https://docs.astral.sh/uv/). The v1 boundary is **pure stdlib**, so it
runs with nothing installed beyond CPython ≥ 3.11.

```sh
# with uv:
uv sync
uv run --extra dev pytest

# without uv (stdlib only):
python -m unittest discover -s tests
```

> Note: `uv` is not assumed to be on the build host. The smoke test runs under plain
> `python -m unittest`. The only third-party deps are optional extras: `pytest` (dev)
> and `dspy` (`gepa` extra, for the live optimizer).
