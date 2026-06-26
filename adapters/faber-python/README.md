# faber-python — second adapter (Python)

A Faber adapter for **Python** projects, and the proof that Faber's engine is **domain-free**.

Where [`faber-elixir`](../faber-elixir/README.md) is *extracted by reference* from a single
upstream plugin, `faber-python` is **hand-curated** from general Python knowledge — and yet
standing it up required **zero stack-specific `lib/faber` changes**. The only engine work was
the *generic*, adapter-aware detection mechanism (contract v0.2 §4.1) plus the prompt
`example_step` seam — both stack-neutral. Two adapters, one engine. (See the repo `README.md`
and `HANDOFF.md` for the thesis; `../EXTRACTION_PROBE.md`-style provenance is inline below.)

## Layout

| Path | Role | Source |
|---|---|---|
| `faber.adapter.yaml` | manifest (`contract: 0.2`, `metadata.example_step`) | hand-written |
| `detect/signatures.yaml` | 6 generic friction signatures + Python detection vocab (§4.1) | Python tooling conventions |
| `laws/laws.yaml` | 15 Iron Laws (PEP 8 / idiomatic Python) | PEP 8/257/484, stdlib docs, common idiom |
| `investigate/playbooks.yaml` | 7 debugging playbooks | traceback/import/venv/pytest/ruff/mypy docs |
| `eval/eval.yaml` | eval reference (**vendored**, structural + trigger only) | — |
| `templates/skill.md.tmpl` + `manifest.yaml` | SKILL.md scaffold (```python example) | Claude Code skill conventions |

## Provenance (hand-curated, NOT auto-extracted)

Unlike `faber-elixir`, there is **no single upstream repo** this pack is lifted from. The
knowledge is synthesized from widely accepted Python sources, cited per file:

- **Laws** — [PEP 8](https://peps.python.org/pep-0008/) (style),
  [PEP 257](https://peps.python.org/pep-0257/) (docstrings),
  [PEP 484](https://peps.python.org/pep-0484/) (type hints), the Python stdlib docs, and
  established idioms. Only the rules a senior Python reviewer treats as non-negotiable.
- **Playbooks** — the `traceback`, `pdb`, import-system, `venv`/`pip`, and `unicode` HOWTO
  docs, plus the `pytest`, `ruff`, and `mypy` tool docs.
- **Detection vocab** — Python dependency tools (`pip`/`poetry`/`uv`) and test/lint runners
  (`pytest`/`ruff`/`mypy`), mapped to the same fingerprint/opportunity shape the engine uses.

Because nothing is referenced from a private upstream, the "zero-diff to source" rule is
trivially satisfied here — the thesis being proven is *engine* domain-independence, not
auto-extraction.

### Zero-`lib/faber`-diff proof

Adding this entire adapter required **no engine code change**. The generic, adapter-aware
detection mechanism landed in a *separate, earlier* commit (Phase 0: contract v0.2 +
`Detect.fingerprint/2` / `opportunity/2` + `Scan` threading + the `example_step` seam — all
stack-neutral). Everything since is declarative pack data + a test + a fixture:

```
$ git diff --stat <phase-0-commit> -- lib/faber/ python/
   (empty — zero engine/sidecar diffs)

$ git status --short            # the faber-python work
   adapters/faber-python/                  # the declarative pack
   test/faber/faber_python_test.exs        # scan→detect→propose→eval proof
   test/fixtures/python_session.jsonl      # a real Python session fixture
```

`test/faber/faber_python_test.exs` drives the full pipeline on the fixture and shows the same
engine produces **Python**-flavored detection (`pip install → maintenance`, `pytest → verify`,
`py:` namespaces) where `faber-elixir` produces Elixir-flavored detection. Two adapters, one
domain-free engine.

## Status

Phase 1 populated (hand-curated). Eval is **vendored / structural + trigger only** — no
Python-specific domain matchers yet (a future step: drop matcher modules under `eval/` and
reference them from `laws/*.check.ref`). Each subdirectory's `README.md` describes its stage.
