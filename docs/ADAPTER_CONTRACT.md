# Faber Adapter Contract (v0.2)

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
| `metadata.example_step` | string | – | A stack-idiomatic example of one actionable workflow step (e.g. `"Run the failing test in isolation with \`mix test path:line\`"`). The proposer injects it as the worked example when instructing the LLM to write `workflow:` steps. Omitted → the engine uses a stack-neutral fallback. |

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

**Bulk form.** Instead of one file per signature, a `detect/` may provide a single
`detect/signatures.yaml` holding a top-level `signatures:` list whose entries carry the
same fields plus a `body` (the prose). See §5.1 for the general bulk-form rule.

### 4.1 Detection vocab (`detect/signatures.yaml` sibling keys) — *new in v0.2*

The friction *signatures* above tune the friction **score** (how painful a session was).
Three further, **optional** top-level keys in `detect/signatures.yaml` make the engine's
**fingerprint** (what kind of work the session was) and **opportunity** (which skills could
have helped) outputs stack-aware too. Without them the engine uses its built-in,
agent-generic defaults — so v0.1 packs are unaffected. The reference adapter (`faber-elixir`)
migrates its Elixir/plugin command vocabulary into these keys.

```yaml
# detect/signatures.yaml — alongside the `signatures:` list

# fingerprints: command → session-type bonus. Each rule adds `bonus` to a fingerprint
# type's score when ANY of its `commands` appears (substring match) in the session's Bash
# calls. Layers on top of the engine's generic tool-ratio/keyword fingerprinting.
fingerprints:
  - type: maintenance          # the session-type this bonus credits (free-form string)
    commands: ["mix deps", "mix hex"]
    bonus: 3.0                  # number; added to that type's running score
  - type: review
    commands: ["gh pr", "gh issue"]
    bonus: 3.0

# opportunities: a missed-automation rule → a suggested skill name. Order is preserved in
# the reported `missed` list. Each rule fires on ONE `when` condition (below) and, unless
# `unless_used: false`, only when the session did not already use `skill`.
opportunities:
  - skill: investigate
    when: retry_loops          # 3+ consecutive same-prefix Bash commands
    unless_used: false         # suggest even if `investigate` was already used (default: true)
  - skill: plan
    when: tool_count           # total tool calls  >  threshold
    threshold: 50
  - skill: verify
    when: commands             # count of Bash calls matching ANY `commands`  >=  threshold
    commands: ["mix test", "mix compile"]
    threshold: 3
  - skill: review
    when: edit_count           # Edit/Write calls  >  threshold
    threshold: 10

# skill_namespaces: the `ns:` prefixes the engine scans session text for to detect which
# skills were already used (e.g. `/phx:verify` → `verify`). Replaces a hardcoded regex.
skill_namespaces: ["phx", "ecto", "lv"]
```

**`fingerprints[]`** — `type` (string, required), `commands` (string[], required, substring
matched against Bash command text), `bonus` (number, required). A `type` need not be one of
the engine's built-in types; novel types are scored and selectable.

**`opportunities[]`** — `skill` (string, required, the suggested skill name) and `when` (one
of `retry_loops` | `tool_count` | `edit_count` | `commands`, required). `tool_count` and
`edit_count` require an integer `threshold` and fire on **strictly greater than**.
`commands` requires a non-empty `commands` list **and** an integer `threshold` and fires on
**count ≥ threshold**. `retry_loops` takes no threshold. `unless_used` (bool, default
`true`) suppresses the suggestion when the skill is already in the session's used set.

**`skill_namespaces`** — string[]. The namespace prefixes matched as `(?:ns1|ns2):skill` in
session text. Absent (no adapter) → the engine default; an adapter that supplies the key
owns it (an empty list means "this stack has no skill namespaces").

All three keys are **optional**. An adapter may supply any subset; each absent key falls back
to engine defaults only when **no adapter** is in play. When an adapter *is* selected it owns
its detection vocab — so the reference adapter must restate the defaults it wants to keep
(see `adapters/faber-elixir/detect/signatures.yaml`).

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

### 5.1 Bulk form (applies to `detect/`, `laws/`, `investigate/`)

A knowledge subdirectory may use **either** one entry per file (per §4–§6) **or** a single
bulk file named `<dir-singular>.yaml` — `detect/signatures.yaml`, `laws/laws.yaml`,
`investigate/playbooks.yaml` — holding one top-level list (`signatures:` / `laws:` /
`playbooks:`). Each list entry carries the same fields the per-file frontmatter would, with
the markdown body moved into a `body:` (or `statement:` for laws) string. Bulk form is the
natural shape when an adapter is **extracted by reference** from a single upstream source
(e.g. all 26 Iron Laws lifted from one `CLAUDE.md` section). Mixing forms in one
subdirectory is allowed; `id` uniqueness still spans the whole subdirectory.

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

### 7.0 Reference modes — `eval/eval.yaml`

An adapter may *vendor* its eval code or *reference* an existing eval package in place. A
small `eval/eval.yaml` declares which, via `mode:`. If `eval/eval.yaml` is absent, `mode:
vendored` is assumed.

```yaml
# eval/eval.yaml
mode: vendored                 # default — matcher/fixture files live in eval/, run by the sidecar
```

```yaml
# eval/eval.yaml — referencing an external, repo-rooted eval framework without forking it
mode: exec-in-place
root: "${source_repo}"                          # cwd + PYTHONPATH for the run (manifest var or path)
entrypoints:
  score: "python3 -m lab.eval.scorer"
  trigger: "python3 -m lab.eval.trigger_scorer"
requirements: ["PyYAML>=6.0.3,<7.0"]            # what the referenced package needs installed
```

- **`mode: vendored`** — matcher modules + trigger fixtures live under `eval/` and are run
  by Faber's own sidecar. Right for adapters authored from scratch. Subject to the validation
  in §8 (every `laws/*.check.ref` matcher must resolve here).
- **`mode: exec-in-place`** — Faber's sidecar shells out to each `entrypoints` command with
  cwd / `PYTHONPATH` = `root`, instead of importing vendored files. Right when referencing an
  existing eval framework that is **rooted at its own repo** (package-relative imports,
  `__file__`-relative paths). It keeps the upstream at **zero diffs** and avoids maintaining a
  fork. `root` may be `${source_repo}` (resolved from the manifest) or an explicit path.

The two content kinds below describe **`vendored`** mode. In `exec-in-place` mode the
referenced package supplies them and `eval/` need contain only `eval.yaml`.

Two kinds of content (vendored mode):

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
- In `vendored` eval mode, every `laws/*.check.ref` of `kind: matcher` resolves to an
  existing `eval/` callable. In `exec-in-place` mode, matcher resolution is the referenced
  package's responsibility and is not statically validated.
- No content file requires a diff to the adapter's `source_repo` to produce.

**Entanglement report.** When assembling an adapter by reference, the author records any
knowledge that could not be extracted cleanly (no standalone artifact upstream; embedded in
a larger file; coupled to upstream-private code/paths). The reference adapter keeps this in
`adapters/<name>/EXTRACTION_PROBE.md`. Entanglement is a finding, not a license to edit the
upstream.

## 9. Versioning this contract

This document is **v0.2** and will change before 1.0. Adapters declare the engine
contract version they target via an optional top-level `contract: "0.2"` key in the
manifest; if omitted, the engine assumes the latest it supports and may warn.

**v0.1 → v0.2.** Added the optional detection-vocab keys to `detect/signatures.yaml`
(§4.1: `fingerprints`, `opportunities`, `skill_namespaces`) and the optional
`metadata.example_step` generation hint (§3). All additions are **optional** and
backward-compatible — a v0.1 pack is a valid v0.2 pack, and an engine running adapter-free
behaves exactly as before.
