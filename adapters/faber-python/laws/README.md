# `laws/` — the stack's non-negotiables (Iron Laws)

The Python rules a senior reviewer treats as hard constraints — injected into skill
*generation*, and (where mechanizable) compiled into eval *checks*.

For `faber-python` these are **hand-curated** from PEP 8 (style), PEP 257 (docstrings),
PEP 484 (type hints), the stdlib docs, and established idioms — not extracted from a single
upstream. 15 laws across typing, exceptions, correctness, resources, idiom, imports,
observability, packaging, and verification.

Format: bulk form (`laws.yaml`) per ADAPTER_CONTRACT.md §5.1 — `id`, `category`, `severity`, a
human `statement`, and an optional `check` (a regex for the few rules reducible to a token
pattern; the rest are semantic). **No host-language code.**
