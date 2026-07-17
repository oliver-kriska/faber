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
have helped) outputs stack-aware too. Without them the engine falls back to its built-in
defaults, which are **stack-neutral**: no fingerprint bonuses, no skill namespaces, and only
the opportunity rules that need no command vocabulary (`retry_loops` → investigate,
`tool_count` → plan, `edit_count` → review). ALL stack vocabulary — commands, tool prefixes,
namespaces — lives in adapters; the reference adapter (`faber-elixir`) carries the historical
Elixir/plugin vocabulary.

```yaml
# detect/signatures.yaml — alongside the `signatures:` list

# fingerprints: command/tool → session-type bonus. Each rule adds `bonus` to a fingerprint
# type's score when ANY of its `commands` appears (substring match) in the session's Bash
# calls, OR any tool name starts with one of its `tools` prefixes (e.g. an MCP tool family).
# Layers on top of the engine's generic tool-ratio/keyword fingerprinting.
fingerprints:
  - type: maintenance          # the session-type this bonus credits (free-form string)
    commands: ["mix deps", "mix hex"]
    bonus: 3.0                  # number; added to that type's running score
  - type: review
    commands: ["gh pr", "gh issue"]
    bonus: 3.0
  - type: bug-fix
    tools: ["mcp__tidewave"]   # tool-name PREFIX match — fires on mcp__tidewave__project_eval etc.
    bonus: 1.5

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

**`fingerprints[]`** — `type` (string, required), `bonus` (number, required), and at least
one of `commands` (string[], substring matched against Bash command text) or `tools`
(string[], **prefix** matched against tool names — the way to credit MCP tool families like
`mcp__tidewave`). A rule with both fires when either matches. A `type` need not be one of
the engine's built-in types; novel types are scored and selectable.

**`opportunities[]`** — `skill` (string, required, the suggested skill name) and `when` (one
of `retry_loops` | `tool_count` | `edit_count` | `commands`, required). `tool_count` and
`edit_count` require an integer `threshold` and fire on **strictly greater than**.
`commands` requires a non-empty `commands` list **and** an integer `threshold` and fires on
**count ≥ threshold**. `retry_loops` takes no threshold. `unless_used` (bool, default
`true`) suppresses the suggestion when the skill is already in the session's used set.

**`skill_namespaces`** — string[]. The namespace prefixes matched as `(?:ns1|ns2):skill` in
session text. The engine default (no adapter) is **none** — text-based used-skill detection
is entirely adapter-supplied (an empty list means "this stack has no skill namespaces").

All three keys are **optional**. An adapter may supply any subset; each absent key falls back
to the stack-neutral engine defaults only when **no adapter** is in play. When an adapter *is*
selected it owns its detection vocab — the engine contributes nothing stack-specific either
way (see `adapters/faber-elixir/detect/signatures.yaml` for the full reference vocab).

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
a hook), in the stack's idiom. Placeholders use `{{double_brace}}` tokens.
`templates/manifest.yaml` names each template and the artifact type it produces:

```yaml
templates:
  - file: skill.md.tmpl
    produces: skill            # skill | agent | hook
    description: "SKILL.md scaffold with Iron Laws + quick-patterns sections"
  - file: hook.sh.tmpl
    produces: hook
    description: "hook.sh scaffold — provenance header, shebang, and the script body"
```

The manifest is how a template is found: the engine keys the loaded templates by `produces`
and the proposer fetches the scaffold for the kind it is rendering. Both `file` and `produces`
are **required** per entry, and `produces` must be one of `skill | agent | hook` — an unknown
value is a load-time validation error, not a template that silently renders nothing. There is
no inference from the filename; a pack with no `manifest.yaml` contributes no templates.
`file` must resolve inside `templates/` (an absolute path or `..` escape is rejected and
logged). Unknown placeholders left unfilled are a generation warning.

**The built-in fallback is skill-only.** A `kind: :skill` proposal with no `skill` template
renders through the engine's built-in `SKILL.md` scaffold. Any other kind with no template
**raises** — there is no built-in hook scaffold to fall back *to*, and silently rendering a
skill (or an empty string, which would sail through the eval) is worse than a loud failure.
So a pack that proposes hooks must ship a `produces: hook` template.

Each kind's template gets its own token set — a hook's artifact *is* its script, so its
scaffold is a thin wrapper rather than a document with sections:

| `produces` | tokens |
|---|---|
| `skill` | `skill_name`, `skill_title`, `description`, `effort`, `one_line_purpose`, `usage_examples`, `iron_laws[]`, `workflow_present`/`steps[]`, `patterns_present`/`patterns[]` |
| `hook` | `hook_name`, `description`, `one_line_purpose`, `event`, `matcher`, `script`, `hazard`, `hazard_evidence` |

The **template owns the shebang**, not the model: `{{script}}` is the body with any leading
`#!` line stripped, so the rendered file has exactly one and it is the template's. A `#!` is
only a shebang on line 1 — a second one is a comment, and a file whose line 1 says `bash`
while line 3 says `zsh` says one thing and does another.

## 7. `eval/` — domain matchers + trigger fixtures

This is the only subdirectory that may contain **executable code**, and it is **Python**. It
contributes the stack's notion of *correct* on top of generic structural/trigger scoring.

Who runs that Python depends on `mode` (§7.0): **vendored** matchers are run by the Faber
eval sidecar (`python -m faber_eval score`); an **exec-in-place** adapter's `entrypoints` are
spawned directly by the Elixir engine (`Faber.Eval.ExecInPlace`), because the referenced
framework must run with cwd = its own repo, which is the sidecar's whole reason not to own it.

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
- **`mode: exec-in-place`** — Faber's Elixir engine (`Faber.Eval.ExecInPlace`) spawns the
  `entrypoints.score` command with cwd / `PYTHONPATH` = `root`, instead of importing vendored
  files. Right when referencing an existing eval framework that is **rooted at its own repo**
  (package-relative imports, `__file__`-relative paths). It keeps the upstream at **zero diffs**
  and avoids maintaining a fork. `root` may be `${source_repo}` (resolved from the manifest's
  `metadata.source_repo`) or an explicit path.

  **Invocation contract.** The command is split on whitespace and executed **without a shell**
  (a pack cannot smuggle `;` or globs into a subshell), then receives **one positional argument:
  an absolute path to the rendered `SKILL.md`**. It must print a single JSON object to stdout and
  exit 0. Faber writes the skill to `<tmp>/<skill-name>/SKILL.md`, because a scorer conventionally
  derives the skill's name from the file's **parent directory**. Faber reads `composite`
  (0..1, already weight-normalized) and `dimensions`; a `weight_total` is not expected. Assertions
  may use either `check_type`/`evidence` or the legacy `type`/`desc`.

  **Failure is never silent, and never claimed as yours.** If `root` is absent, the command exits
  non-zero, or the output doesn't decode, Faber logs a warning and falls back to its generic native
  eval, marking the result `engine: "native:fallback"` (vs `"adapter:exec-in-place"` on success).
  A fallback PASS certifies generic markdown structure — **not** this adapter's stack-specific bar.
  Validation of `entrypoints`/`root` happens at `Adapter.load/1`, so a malformed pack is a load
  error rather than a silent downgrade at score time.

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
(§4.1: `fingerprints` — including the `tools:` prefix-list form — `opportunities`,
`skill_namespaces`) and the optional `metadata.example_step` generation hint (§3). All
additions are **optional** and backward-compatible — a v0.1 pack is a valid v0.2 pack.
Alongside v0.2 the engine's own adapter-free defaults were neutralized (no stack vocabulary);
packs wanting the historical Elixir/plugin detection behavior restate it, as `faber-elixir`
does.
