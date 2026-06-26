# `investigate/` — stack-specific debugging playbooks

Structured "when symptom X, check Y then Z" recipes the proposer can fold into generated
skills and the loop can consult.

For `faber-python` these are **hand-curated** from common Python failure modes and the
stdlib/tooling docs: reading tracebacks bottom-up, `ImportError`/`ModuleNotFoundError`,
venv/interpreter mismatch, isolating tests with `pytest -x --pdb`, `ruff`/`mypy` triage,
profiling before optimizing, and the bytes↔str boundary.

Format: bulk form (`playbooks.yaml`) per ADAPTER_CONTRACT.md §5.1 — `id`, `symptoms` (for
retrieval), `source`, and the playbook `body`. **No host-language code.**
