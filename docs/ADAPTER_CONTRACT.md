# Faber Adapter Contract (v0.1)

> The specification for a **Faber adapter pack** — the declarative bundle that teaches the
> domain-free Faber engine how a specific stack thinks. This document is precise enough to
> build an adapter from scratch, with no reference to the engine's source.

## 1. What an adapter is

Faber's engine is **domain-free**. Everything stack-specific — what friction looks like,
what the non-negotiable rules are, how to debug, what "a correct skill" means, and what an
idiomatic artifact looks like — lives in an **adapter pack**. An adapter supplies BOTH:

1. **Generation knowledge** — the laws, playbooks, and templates injected when a skill is
   proposed, so the output is right *for this stack*.
2. **Stack-specific eval criteria** — the bar the eval gate holds a proposed skill to.
   This is the part a generic skill-creator cannot commoditize: correct-for-Elixir ≠
   correct-for-Rails.

An adapter is **declarative** — YAML, Markdown, prompt templates, and (for `eval/` only)
matcher/fixture files the Python sidecar runs. A community author writes **no engine
host-language (Elixir) code**.

### Read-only over its sources

An adapter may be *assembled by referencing* an upstream repository (the reference adapter
`faber-elixir` references the `claude-elixir-phoenix` plugin). The engine and the adapter
**only ever read** their sources. Producing or maintaining an adapter must require **zero
diffs** to the upstream it draws from. If extracting some knowledge would force an upstream
edit, that knowledge is *entangled* — record it (see §8), do not edit upstream.

## 2. Directory layout

An adapter is a directory whose name matches the manifest `name`:

```
adapters/<name>/
├── faber.adapter.yaml   # REQUIRED — the manifest (§3)
├── detect/              # friction/repetition signatures for this stack (§4)
├── laws/                # the stack's non-negotiables → skill content + checks (§5)
├── investigate/         # stack-specific debugging playbooks (§6)
├── eval/                # domain matchers + trigger fixtures (§7)
└── templates/           # skill/agent/hook scaffolds in the stack's idiom (§7? see §6.5)
```

`faber.adapter.yaml` is **required**. Each subdirectory is **optional but recommended**;
an absent subdirectory means the adapter contributes nothing for that stage and the engine
falls back to generic behavior. An empty subdirectory (or one holding only a `README.md`)
is treated as absent. Files beginning with `.` or `_`, and any `README.md`, are ignored as
content (READMEs document the directory for humans).

## 3. The manifest — `faber.adapter.yaml`

```yaml
name: faber-elixir            # REQUIRED
version: 0.1.0                # REQUIRED
agent_targets:               # REQUIRED, non-empty
  - claude-code
file_globs:                  # REQUIRED, non-empty
  - "mix.exs"
  - "lib/**/*.ex"
metadata:                    # REQUIRED (object; fields below optional unless noted)
  display_name: "Elixir / Phoenix"
  description: "…"
  homepage: "https://…"
  source_repo: "/path/or/url/to/upstream"
  maintainers:
    - "Name <email>"
  license: "MIT"
```

### Field reference

| Field | Type | Req. | Rules |
|---|---|---|---|
| `name` | string | ✓ | Must equal the directory name. `^[a-z0-9]([a-z0-9-]*[a-z0-9])?$` (lowercase kebab). Unique within an adapter search path. |
| `version` | string | ✓ | Semantic version `MAJOR.MINOR.PATCH`. Bump MAJOR on a breaking change to any subdirectory's meaning. |
| `agent_targets` | string[] | ✓ | Non-empty. Coding agents this knowledge targets. Known values: `claude-code` (others as ingest adapters land). Unknown values are allowed but ignored by an engine that doesn't support them. |
| `file_globs` | string[] | ✓ | Non-empty. Globs (relative to a *target project* root) whose presence marks a project as this stack. Used to auto-select the adapter. Standard glob syntax (`**`, `*`, `{a,b}`). |
| `metadata` | object | ✓ | Free-form bag; the keys below are recognized. Unknown keys are preserved and ignored. |
| `contract` | string | – | The adapter-contract version this pack targets (e.g. `"0.1"`). See §9. Recognized top-level key. |
| `metadata.display_name` | string | – | Human label for UIs. Defaults to `name`. |
| `metadata.description` | string | – | One-paragraph summary. |
| `metadata.homepage` | string (URL) | – | Project/docs URL. |
| `metadata.source_repo` | string | – | Provenance: the upstream this adapter references (path or URL). Read-only (§1). |
| `metadata.maintainers` | string[] | – | `Name <email>` entries. |
| `metadata.license` | string | – | SPDX identifier. |

The manifest **must** parse as a single YAML mapping. Unknown **top-level** keys are a
validation **warning** (likely a typo); unknown keys **under `metadata`** are allowed.

## 4. `detect/` — friction signatures

Each non-README file is one **friction signature**: a declarative description of a painful,
repetitive pattern in a session transcript, layered on top of the engine's generic signals.

Recommended shape (Markdown + YAML frontmatter):

```markdown
---
id: repeated-compile-fix-loop
severity: high          # one of: low | medium | high
weight: 0.8             # 0.0–1.0, relative contribution to the friction score
---
Repeated `mix compile` failure → edit → recompile cycles on the same file within a
session, indicating a missing guardrail the proposed skill should encode.
```

The engine reads `id`, `severity`, `weight`, and the prose (used as the matching intent).
A signature **must** have a unique `id` within the adapter. No host-language code.

## 5. `laws/` — the stack's non-negotiables

Each non-README file is one **law**, serving two roles: a generation constraint **and**, where
mechanizable, an eval check.

```markdown
---
id: ecto-no-float-money
category: ecto          # free-form grouping (liveview | ecto | oban | security | otp | …)
severity: high          # low | medium | high
check:                  # OPTIONAL — omit for laws that are guidance only
  kind: matcher         # one of: regex | matcher
  ref: "eval/matchers.py::no_float_money"   # for kind: matcher → file::callable in eval/
  # pattern: ":float"   # for kind: regex → a regex applied to candidate skill content
---
**NEVER use `:float` for money.** Use `:decimal` or `:integer` (cents). Floating-point
rounding silently corrupts financial calculations.
```

Rules:

- `id` unique within the adapter; `severity` required; `category` recommended.
- The body (everything after frontmatter) is the human statement injected at generation.
- `check` is optional. When present, `kind: regex` runs `pattern` against candidate skill
  content; `kind: matcher` references a callable in `eval/` (`<relpath>::<callable>`) the
  eval gate invokes. A law with no `check` informs generation but is not gated.

## 6. `investigate/` — debugging playbooks

Each non-README file is one **playbook** (Markdown, frontmatter optional):

```markdown
---
id: n1-query-rootcause
symptoms: ["slow endpoint", "many similar queries in logs"]
---
## Symptom
…
## Hypotheses
…
## Ordered checks
1. …
## Resolution patterns
…
```

The engine treats `id` (unique) and `symptoms` (string[]) as metadata for retrieval and
the body as the playbook the proposer/loop may fold in. No host-language code.

### 6.5 `templates/` — artifact scaffolds

Each non-README file is a scaffold for an artifact the proposer emits (a skill, an agent,
a hook), in the stack's idiom. Placeholders use `{{double_brace}}` tokens. A
`templates/manifest.yaml` (optional) names each template and the artifact type it produces:

```yaml
templates:
  - file: skill.md.tmpl
    produces: skill            # skill | agent | hook
    description: "SKILL.md scaffold with Iron Laws + quick-patterns sections"
```

If `manifest.yaml` is absent, the engine infers `produces` from a `.<type>.tmpl` suffix
(e.g. `foo.skill.tmpl`). Unknown placeholders left unfilled are a generation warning.

## 7. `eval/` — domain matchers + trigger fixtures

This is the only subdirectory that may contain **executable code**, and it is **Python**,
run by the Faber eval sidecar (`python -m faber_eval score`) — never by the Elixir engine.
It contributes the stack's notion of *correct* on top of generic structural/trigger
scoring.

Two kinds of content:

1. **Domain matchers** — Python modules exposing callables referenced by `laws/*.check`
   (`<relpath>::<callable>`) and/or by an `eval/matchers.yaml` index. A matcher is a pure
   function `(candidate: dict) -> {"passed": bool, "score": float, "detail": str}`.
2. **Trigger fixtures** — behavioral cases checking that a skill *fires on the right
   prompts and stays quiet on the wrong ones*. Recommended `eval/triggers/*.yaml`:

   ```yaml
   skill: ecto-changeset-helper
   should_trigger:
     - "add a validation to the user changeset"
   should_not_trigger:
     - "write a LiveView mount callback"
   ```

The eval sidecar discovers matchers via `eval/matchers.yaml` (if present) or by importing
referenced `file::callable` paths. Matchers **must not** import the Faber engine; they may
use the sidecar's own helpers and third-party eval deps (declared in `python/pyproject.toml`).

## 8. Validation & entanglement

An adapter is **valid** when:

- `faber.adapter.yaml` parses and every REQUIRED field is present and well-typed (§3).
- `name` equals the directory name.
- Every `id` (within `detect/`, `laws/`, `investigate/`) is unique within its subdirectory.
- Every `laws/*.check.ref` of `kind: matcher` resolves to an existing `eval/` callable.
- No content file requires a diff to the adapter's `source_repo` to produce.

**Entanglement report.** When assembling an adapter by reference, the author records any
knowledge that could not be extracted cleanly (no standalone artifact upstream; embedded in
a larger file; coupled to upstream-private code/paths). The reference adapter keeps this in
`adapters/<name>/EXTRACTION_PROBE.md`. Entanglement is a finding, not a license to edit the
upstream.

## 9. Versioning this contract

This document is **v0.1** and will change before 1.0. Adapters declare the engine
contract version they target via an optional top-level `contract: "0.1"` key in the
manifest; if omitted, the engine assumes the latest it supports and may warn.
