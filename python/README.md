# faber_eval — Python eval sidecar

The Python half of Faber. It hosts the eval matchers (ported from the plugin's
`lab/eval` in M4) and the GEPA / DSPy optimizer (M4/M5). The Elixir spine reaches it over
a **subprocess boundary**: it spawns `python -m faber_eval <command>`, writes a JSON
request on stdin, and reads a JSON response on stdout.

## Boundary contract (v1)

| | |
|---|---|
| Invocation | `python -m faber_eval <command>` (or console script `faber-eval`) |
| Request | one JSON object on **stdin** (empty stdin ⇒ `{}`) |
| Response | one JSON object on **stdout**, newline-terminated |
| Diagnostics | **stderr** (stdout stays pure JSON) |
| Exit codes | `0` ok · `1` bad request (e.g. invalid JSON) · `2` unknown command |

### Commands

- **`score`** — structural / trigger eval of a proposed skill. *Stub in M0* (returns
  `status: "not_implemented"`); ports `lab/eval` matchers + `trigger_scorer.py` in M4.
- **`optimize`** — evolve→eval→keep optimization wrapping GEPA / `dspy.GEPA`. *Stub in
  M0*; implemented in M4/M5.

Example:

```sh
echo '{"skill": {"name": "demo"}}' | python -m faber_eval score
# {"command": "score", "status": "not_implemented", "version": "0.1.0", "echo": {...}, "result": null}
```

## Development

Managed by [`uv`](https://docs.astral.sh/uv/). The v1 boundary is **pure stdlib**, so it
runs with nothing installed beyond CPython ≥ 3.11.

```sh
# with uv:
uv sync
uv run python -m unittest discover -s tests

# without uv (stdlib only):
python -m unittest discover -s tests
```

> Note: `uv` is not assumed to be on the build host. The smoke test runs under plain
> `python -m unittest`. Third-party deps (`gepa`, `dspy`) arrive with M4.
