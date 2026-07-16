# Faber — User Guide

Step-by-step guide to using Faber end to end: mining your real coding-agent sessions for
friction, generating skills that pass a stack-aware eval gate, installing them across agents,
self-improving them in a loop, and checking whether they actually helped.

This is the *how-to* document. For the product thesis and architecture rationale see
[`HANDOFF.md`](../HANDOFF.md); for the adapter pack spec see
[`ADAPTER_CONTRACT.md`](ADAPTER_CONTRACT.md).

---

## Table of contents

1. [What Faber does](#1-what-faber-does)
2. [Prerequisites & install](#2-prerequisites--install)
3. [Five-minute quickstart](#3-five-minute-quickstart)
4. [Concepts](#4-concepts)
5. [Step 1 — Scan: rank your sessions by friction](#5-step-1--scan-rank-your-sessions-by-friction)
6. [Step 2 — Propose: draft a skill for a friction finding](#6-step-2--propose-draft-a-skill-for-a-friction-finding)
7. [Step 3 — The eval gate](#7-step-3--the-eval-gate)
8. [Step 4 — Refine: the self-improving loop](#8-step-4--refine-the-self-improving-loop)
9. [Step 5 — Install & sync across agents](#9-step-5--install--sync-across-agents)
10. [Step 6 — Feedback: did the skill actually help?](#10-step-6--feedback-did-the-skill-actually-help)
11. [Proposing across many sessions (`--top N`)](#11-proposing-across-many-sessions---top-n)
12. [Dashboard & MCP server](#12-dashboard--mcp-server)
13. [Cross-agent ingest (Codex, Cline, Gemini, OpenCode…)](#13-cross-agent-ingest)
14. [Adapters: the stack-awareness](#14-adapters-the-stack-awareness)
15. [LLM backends](#15-llm-backends)
16. [Scheduled / overnight runs](#16-scheduled--overnight-runs)
17. [Python sidecar & GEPA (optional)](#17-python-sidecar--gepa-optional)
18. [Configuration reference](#18-configuration-reference)
19. [Privacy & safety guarantees](#19-privacy--safety-guarantees)
20. [Testing & development](#20-testing--development)
21. [Troubleshooting](#21-troubleshooting)

---

## 1. What Faber does

Faber closes a loop most coding-agent setups leave open:

```
your real agent sessions                       your agent, next session
  (Claude Code, Codex, …)                              ▲
        │                                              │
        ▼                                              │
  ingest → detect friction → propose skill → eval gate → install → sync
                 ▲               (adapter-       │
                 │               informed)       ▼
                 │                          refine loop (optional)
                 │                               │
                 └────────── feedback ◄──────────┘
                    (did installed skills fire? did friction drop?)
```

- **Scan** finds the sessions where you and your agent struggled (retry loops, corrections,
  error storms, context compactions).
- **Propose** turns the worst finding into a draft skill (a Claude Code `SKILL.md`), written by
  an LLM but *informed by your stack's adapter* (Iron Laws, playbooks, idioms).
- **Eval** gates the draft against a deterministic, stack-specific bar — a skill that isn't
  well-formed and stack-correct never reaches your agent.
- **Refine** (optional) self-improves the draft: propose → eval → keep-the-best, looping.
- **Install + sync** puts the accepted skill where your agents load it, with provenance.
- **Feedback** (the outer loop) later reports whether installed skills actually fire.

Everything defaults to **local-first and keyless**: the LLM runs through your local `claude -p`
(no API key), the eval runs natively in Elixir (no Python on the hot path), nothing leaves your
machine, and no autonomous action happens unless you opt in.

---

## 2. Prerequisites & install

**Required**

| What | Version | Why |
|---|---|---|
| Erlang/OTP + Elixir | see [`.tool-versions`](../.tool-versions) (Erlang 29, Elixir 1.20) | the app |
| `claude` CLI | any recent | the default keyless LLM backend (`claude -p`) |

**Optional**

| What | Needed for |
|---|---|
| `python3` | the Python eval sidecar (`eval_engine: :sidecar`) and GEPA — *not* needed for normal use |
| `sqlite3` CLI | the `opencode` ingest format and the `ccrider` source |
| Zig 0.15.2 | only for building the single-binary release yourself |
| an Anthropic API key | only for the `ReqLLM` backend (see [LLM backends](#15-llm-backends)) |

**Run from source (dev mode)**

```sh
git clone <repo> faber && cd faber
make deps             # mix deps.get
make test             # sanity: hermetic suite, no python needed
mix faber.scan        # first real run against your ~/.claude sessions
```

`make help` lists every target; `make verify` is the pre-commit gate.

**Build the single binary**

```sh
make build            # host target only — fastest dev loop
make build-all        # cross-build every target: faber_macos, faber_macos_silicon, faber_linux
ls burrito_out/
```

Prefer `make build` over a bare `MIX_ENV=prod mix release faber`: on macOS 26 the raw command fails
with hundreds of `undefined symbol: _abort/_getenv/...`, because Burrito pins Zig 0.15.2 and that
Zig predates the macOS 26 SDK (whose umbrella `libSystem` no longer advertises a plain `arm64-macos`
slice). `make build` detects this and points Zig at an SDK that still has the slice, via
`DEVELOPER_DIR`. It engages only when needed — `make doctor` shows whether it's active.

**Install it on your PATH**

```sh
make install                      # → ~/.local/bin/faber
make install PREFIX=/usr/local    # → /usr/local/bin/faber (may need sudo)
faber scan                        # now works from any directory
```

`make install` also purges Burrito's extracted runtime. That step is load-bearing during
development: Burrito keys its self-extraction on the **app version**, not on a payload hash, and
re-extracts only when that cache is absent — so at a pinned `0.1.0` a rebuilt binary would
otherwise silently keep running the previously extracted code. `make uninstall` removes both.

The binary embeds the Erlang runtime and ships the `adapters/` packs beside it. **The binary is the
product; `mix faber.*` is the dev bench.** They are not two spellings of one command — only
`faber refine` and `mix faber.refine` are (the task delegates to `Faber.CLI`, so the flags cannot
drift). For `scan` and `propose` each surface carries flags the other does not:

| Binary | From a checkout | How they differ |
|---|---|---|
| `faber scan` | `mix faber.scan` | task adds `--top N` (rows) and `--no-dedupe`; binary adds `--rank-by`, `--source`/`--db`, `--json`, `--quiet` |
| `faber propose` | `mix faber.propose` | task adds `--adapter DIR`, `--write DIR`, `--no-eval`, `--trigger-samples N`; binary adds `--install`/`--force`, `--top N`/`--cluster-threshold`, `--dry-run`, `--source`/`--db`, `--min-messages N` |
| `faber refine` | `mix faber.refine` | identical — the task is a thin delegate |
| `faber propose --top N` | — | library: `Faber.Consolidate.run/3` |
| `faber feedback` | — | library: `Faber.Feedback.report/1` |
| `faber sync` | — | library: `Faber.Install.sync_pointer/2` |
| `faber serve` | `iex -S mix phx.server` | dashboard on port 4010 |

Both surfaces scope to the project you're standing in and take `--all` to opt out (§5), and both
print the same scope line — that one is shared code (`Faber.CLI.Render`), not a convention.

---

## 3. Five-minute quickstart

Run these from inside one of your projects — Faber scopes to the project you're standing in.

```sh
# 1. Rank this project's sessions by friction (read-only, no LLM call)
faber scan                       # ...or `faber scan --all` for every project

# 2. Draft + eval a skill for the worst session (one keyless claude -p call)
faber propose --dry-run          # what it would draft and spend, for free
faber propose

# 3. Happy with it? Install it into ~/.claude/skills
faber propose --install

# 4. Make other agents see it too (managed block in their context file)
faber sync --target claude,codex

# 5. Days later: did it actually fire?
faber feedback
```

Each step is expanded below. Nothing in steps 1, 4, 5 calls an LLM; step 2/3 makes exactly one
generation call through your local `claude` CLI.

**Flags and `--help`.** `faber <command> --help` (or `-h`) prints usage and exits 0 — it never runs
the command, which matters most for `propose` / `refine`, where running one costs an
LLM call. An unrecognized or wrongly-typed switch is refused outright: Faber names the offending
flag on stderr, prints usage, and exits non-zero rather than running the command without it. So a
typo'd `--dry-runn` fails loudly instead of quietly doing the real thing.

---

## 4. Concepts

**Session / transcript.** One recorded conversation of a coding agent (for Claude Code, a
`.jsonl` under `~/.claude/projects/`). Faber only ever *reads* transcripts.

**Friction.** A per-session score built from detection signals: retry loops (same command
re-run after an error), user corrections, error/tool ratio, approach changes, context
compactions, interrupted requests. `raw` friction favors long painful sessions; `rate`
(`raw / messages`) surfaces short, concentrated pain.

**Fingerprint.** What kind of session it was — `bug-fix`, `feature`, `exploration`,
`maintenance`, `review`, `refactoring` — inferred from the opening messages and tool mix.

**Opportunity.** Which existing skills *could* have helped but weren't used (e.g. retry loops
with no `investigate` skill loaded), and which skills the session *did* use (`skills_used`).

**Adapter.** A declarative pack (`adapters/<name>/`: YAML + markdown + templates) that carries
everything stack-specific: Iron Laws, investigation playbooks, detection vocabulary, the
render template, and the eval criteria. The engine itself is domain-free. Two packs ship:
`faber-elixir` (default) and `faber-python`.

**Proposal.** The structured draft skill (`%Faber.Proposal{}`): name, description, iron laws,
usage, example, workflow, patterns, plus `should_trigger` / `should_not_trigger` routing
fixtures. Rendered to `SKILL.md` via the adapter's template.

**Eval gate.** Deterministic structural scoring across dimensions → a composite in `0..1`
against a threshold (default **0.75**). Opt-in behavioral dimension: trigger accuracy.

**Provenance marker.** Every skill Faber installs gets a `.faber.json` beside its `SKILL.md`.
Faber only ever manages skills carrying this marker — your own skills in the same directory are
never claimed, listed, synced, or analyzed.

---

## 5. Step 1 — Scan: rank your sessions by friction

```sh
faber scan                                 # this project's sessions (see "Scope" below)
faber scan --all                           # every project on the machine
faber scan --limit 200 --rank-by rate
faber scan --format codex                  # scan OpenAI Codex sessions instead
faber scan --source ccrider --db ~/.config/ccrider/sessions.db
```

Output: a scope line, a summary line, then a ranked table:

```
project: faber (/Users/you/Projects/faber) — use --all for every project
12 sessions in 84ms

  # friction(raw) fingerprint  signal              events  turns  tools  errs   ctx   opp  t2  session
  1           9.0 bug-fix      retry_loops             11      3      4     2   62%  0.20   ✓  faber/a1b2c3d4
```

### Scope: `faber scan` means "this project"

Run from inside a project, `scan` ranks **that project's** sessions — not every session on your
machine. `propose`, `refine` and `feedback` scope the same way, so `propose` drafts a
skill for *your* worst session rather than the worst one you have ever had anywhere.

The scope is resolved from the working directory, **walking up to the git root** — so `faber scan`
from `lib/faber/` scopes to the repo, not to a `lib/faber` that has no sessions of its own. The walk
stops at the repo boundary on purpose.

The first line always says which scope you got, because a count is unreadable without it — 12
sessions out of what?

| You ran | You get |
|---|---|
| `faber scan` in a project with sessions | `project: <name> (<path>) — use --all for every project` |
| `faber scan --all` | `all projects` |
| `faber scan` somewhere with no recorded sessions | `all projects — no sessions recorded for this directory…` and the global ranking (never a silently empty table) |
| `faber scan --base DIR` | `all projects` — an explicit root already names the files to read, so it is not narrowed further |

Scoping also makes scans dramatically cheaper: one project's directory instead of the whole corpus
(on a real machine, 174 transcripts rather than 6,770).

| Column | Meaning |
|---|---|
| `friction(raw)` | raw weighted friction — the metric rows are ranked by (see §7 for the scale) |
| `fingerprint` | session type, read off the first ten human messages |
| `signal` | the dominant friction signal that drove the score |
| `events` / `turns` | see below |
| `tools` / `errs` | tool calls made, and errors hit |
| `ctx` | peak context used; `—` means the transcript never reported it (not `0%`) |
| `opp` | missed-automation score |
| `t2` | tier-2 eligible |

**`events` vs `turns`.** `events` counts transcript lines (every user + assistant message,
including the agent's own tool traffic); `turns` counts messages *you* actually typed. They differ
by 20–70× on real sessions — a 9,000-event session is often fewer than 100 human turns — so a
single "messages" number badly overstates how involved a person was. Note `--min-messages` and the
tier-2 gate still count **events**.

**On a terminal** the `session` column is clipped with `…` to fit the width. Piped or redirected
(`faber scan > out.txt`, `| less`), nothing is clipped — there is no width to fit.

**Nothing matched?** The empty result names the things that cause it — and names the ones that
actually apply: inside a project whose directory was found, the root is provably right, so it points
at `--min-messages` and `--all` rather than at `--base`/`--format`. See §21.

| Flag | Meaning | Default |
|---|---|---|
| `--all` | rank every project on the machine, not just the one you're in | off (scoped to the cwd's project) |
| `--limit N` | cap sessions scored (an even sample across the corpus, not a prefix) | all |
| `--rank-by raw\|rate` | total friction vs. friction per message | `raw` |
| `--json` | machine-readable: raw values, the full signal vector, no padding | off |
| `--format F` | agent format: `claude`, `codex`, `cline`, `gemini`, `opencode` | `claude` |
| `--source S` | `files` (walk the format's directory) or `ccrider` (SQLite index) | `files` |
| `--db PATH` | ccrider DB path | `~/.config/ccrider/sessions.db` |
| `--base DIR` | transcript root override (also disables cwd scoping) | the format's default |
| `--min-messages N` | skip sessions shorter than N user+assistant messages | 4 |
| `--quiet` | suppress status/progress lines on stderr; results still go to stdout | off |

Dev mode: `mix faber.scan [--top N] [--all] [--limit N] [--min-messages N] [--base DIR] [--format F]`
prints a fuller report (`--top` controls rows shown, default 20). It scopes to the current project
and honors `--all` exactly as the binary does, but has no `--json` — it is a reading surface, not a
scripting one.

Scanning is pure analysis — no LLM, no writes.

### Machine-readable output: `--json` and `--quiet`

Faber is human-readable by default and machine-readable on request. `--json` is available on the
four read-only surfaces — **`scan`, `proposals`, `show`, `feedback`** — and `--quiet` on every
command.

```sh
faber scan --json | jq '.sessions[0].friction.raw'
faber scan --json | jq -r '.scope.project'
faber proposals --json | jq -r '.proposals[] | select(.installed | not) | .id'
faber feedback --json | jq -r '.skills[] | select(.verdict == "unused") | .skill'
faber show a1b2c3 --json | jq -r .md > SKILL.md
```

What `--json` gives you over the table:

- **Raw values, not display values.** The table rounds `friction(raw)` to one decimal and never
  shows the sigmoid score at all; JSON carries both at full precision.
- **The full signal vector**, not just the dominant one.
- **`null`, not `—`.** A session with no context reading is `"max_ctx_pct": null` — a dash is not a
  number and a script should not have to parse one.
- **The scope it used**, so a script can tell a project-scoped ranking from a global one.

Empty is an *answer*, not an error: a scan matching nothing is `{"count": 0, "sessions": []}` and
exit 0, and an empty proposal store is `[]` rather than the prose explaining how to get one. Exit
codes stay meaningful when piped, and `--quiet` silences the stderr status lines while leaving
stdout untouched — so the two compose: `faber propose --quiet > skill.md`.

---

## 6. Step 2 — Propose: draft a skill for a friction finding

```sh
faber propose                    # rank-1 session of THIS project, faber-elixir adapter, keyless LLM
faber propose --dry-run          # what it would draft and spend — costs nothing
faber propose --rank 3           # the 3rd-ranked session
faber propose --all              # rank across every project, not just the one you're in
faber propose --top 5            # the top 5 sessions at once, clustered and merged (see §11)
faber propose --trigger          # also run the behavioral routing eval (see §7)
faber propose --install          # install if you like what you see
faber propose --force            # skip the stack-match gate (see below)
```

Like `scan`, `propose` ranks **this project's** sessions by default (§5) — `--all` widens it.

What happens:

1. The ranked session's finding (fingerprint, dominant signal, missed opportunities) is woven
   into a prompt together with the adapter's Iron Laws and playbooks.
2. **Stack gate**: if the session's touched files don't match the adapter's `file_globs`
   (e.g. proposing an Elixir skill for a Next.js session), Faber refuses — `--force` overrides.
3. One structured-output LLM call produces the proposal.
4. The eval gate scores the rendered `SKILL.md` and prints the composite + verdict.
5. With `--install`, the skill lands in your skills dir with a provenance marker.

**Progress.** Step 3 is a real `claude -p` call and can take a minute, so a pre-flight line goes to
**stderr** before it — `Proposing for bug-fix session (raw 9.0, dominant retry_loops) via ClaudeCLI…`
— naming the session, its score, and the backend about to be spent. Progress and diagnostics always
go to stderr; **stdout carries only results**, so `faber propose > skill.md` stays clean. `--quiet`
drops the status lines and keeps the results.

**`--dry-run`: see the bill before you pay it.** It stops at exactly the point where the free work
ends and the paid work begins — after the scan, the adapter load and the stack gate, before the LLM
call — and prints the decision it would act on:

```
DRY RUN — nothing was drafted, nothing was filed, no LLM calls were spent.

  session to draft (1):
    1. faber/31f10cff  (feature, raw 61.5)
  adapter:   faber-elixir
  eval:      adapter:exec-in-place
  backend:   ClaudeCLI
  LLM calls: 1 (the draft)

Re-run without --dry-run to spend it.
```

Exit status is 0 and nothing reaches `~/.faber/proposals/`. `--dry-run` does the same
for a whole `--top N` batch (§11). Where a count genuinely isn't knowable in advance it says so rather
than inventing one: `--trigger` spends one call per fixture *in the skill that hasn't been drafted
yet*, and `--top N`'s merge calls depend on clusters that don't exist until the drafts do. The
`eval:` line names the engine that will be **attempted** — an `exec-in-place` adapter falls back to
the native eval if its referenced repo is absent, which is only knowable by running it (§7).

**The draft is kept.** Before anything is printed, the proposal is written to `~/.faber/proposals/`
and the run ends by naming its id. You never pay for the same skill twice, and nothing is lost by
closing the terminal — see §9.

Dev mode has a few extras:

```sh
mix faber.propose --rank 2 --adapter adapters/faber-python \
                  --write proposals --no-eval --trigger --trigger-samples 3
```

`--write DIR` saves the rendered skill without installing; `--adapter` picks a pack;
`--trigger-samples N` pools the (stochastic) routing eval N times for a stable estimate.

---

## 7. Step 3 — The eval gate

Every proposal is scored **deterministically** — no LLM — across structural dimensions
(completeness, conciseness, safety, specificity, triggering, clarity in the default set;
`eval_set: :full` opts into the extended set with accuracy checks). Each dimension runs matcher
assertions (frontmatter present, ≥3 Iron Laws, a ≥2-line fenced example, description with
"what + when", no vague filler, no dangerous live commands, …), and the weighted composite must
clear the threshold (default **0.75**).

Three things to know:

- **The bar is the adapter's.** A pack can vendor its own dimensions/checks
  (`eval.mode: vendored`, scored natively in Elixir — no Python on the hot path), or *reference*
  an existing eval framework in place (`eval.mode: exec-in-place`), which Faber runs against that
  framework's own repo. Either way "good skill" means good *for this stack* — that's the moat.
  The reference `faber-elixir` adapter uses exec-in-place, so with the plugin repo present your
  skills are judged by its full 8-dimension scorer.

  If a referenced scorer can't run (its repo isn't on this machine, it exits non-zero, its output
  doesn't decode), Faber **warns and falls back** to the generic native eval rather than blocking
  the gate — and says so: the result is marked `engine: "native:fallback"` instead of
  `"adapter:exec-in-place"`. A PASS from the fallback certifies generic markdown structure, not
  your stack's bar. Check the engine before reading a composite as a stack-specific verdict.
- **The behavioral dimension is opt-in** (`--trigger` / `trigger: true`): each
  `should_trigger` / `should_not_trigger` fixture is sent to the LLM asking "would this skill
  activate for this request?". The score folds in at weight **0.10** as the continuous mean of
  accuracy / precision / recall (precision uses the sklearn `zero_division=0` convention, so a
  never-firing skill isn't rewarded). Routing is stochastic — one call is a single coin flip —
  so `trigger_samples: N` repeats and pools the eval, reporting a `σ`.
- **The Python engine is optional parity, not the default.** `config :faber, :eval_engine,
  :sidecar` routes scoring through `python/faber_eval` instead; a CI-tested parity suite keeps
  the two engines assertion-identical.

Library API, if you're composing:

```elixir
{:ok, adapter} = Faber.Adapter.load("adapters/faber-elixir")
{:ok, eval}    = Faber.Eval.score(proposal, adapter: adapter, trigger: true)
{:pass, eval}  = Faber.Eval.gate(proposal, adapter: adapter)   # or {:fail, eval}
```

---

## 8. Step 4 — Refine: the self-improving loop

When a draft is decent but not great, let the loop improve it:

```sh
faber refine                          # rank-1 session of this project, 5 reflective iterations
faber refine --rank 2 --iterations 3
faber refine --all                    # rank across every project
faber refine --trigger                # also optimize routing recall
faber refine --trigger --holdout      # + report a held-out validation score
faber refine --install                # install the final best
```

Each iteration: generate a candidate → run structural checks → eval → **keep only strict
improvements** (`composite > best`, plus an optional `--min-improvement` margin), revert
otherwise. The run stops at the target composite (default 0.95), the iteration cap, or a
patience plateau. Output: the per-iteration keep/reject history, the holdout report (if any),
and the final best `SKILL.md`.

**Progress.** Each iteration is a real `claude -p` call, so the loop reports each one to stderr as
it is decided — `iteration 2/5: composite 0.8130 KEEP` — rather than printing nothing until the
whole run ends. (Library callers get the same via `Faber.Loop.refine/3`'s `:on_progress` option.)

| Flag | Meaning | CLI default |
|---|---|---|
| `--strategy reflect\|regenerate` | `reflect` = each candidate is a *targeted edit* of the current best, driven by its weakest eval dimension (keyless GEPA-style). `regenerate` = independent redraft each time. | `reflect` |
| `--iterations N` | max iterations (each is a real `claude -p` call — budget minutes each) | 5 |
| `--patience N` | stop after N consecutive discards | 50 |
| `--target F` | stop when the composite reaches F | 0.95 |
| `--min-improvement F` | keep only when the gain exceeds F (noise margin) | 0.0 |
| `--trigger` | fold the behavioral routing dimension into the objective | off |
| `--trigger-samples N` | pooled routing samples per eval | 3 in trigger mode |
| `--holdout` | split fixtures; report the final best on a never-optimized validation half | off |

**Why trigger mode is safe to optimize** (the part that's easy to get wrong): candidates are
always scored against the **seed proposal's fixtures, pinned for the whole run** — a candidate
can never "improve" by generating routing fixtures its own description trivially passes. And
because a single routing call is one Bernoulli draw, trigger mode pools 3 samples by default so
the loop doesn't bank lucky noise. `--holdout` is the overfit detector: the loop optimizes
against half the fixtures and is graded on the other half; a large train/validation gap means
it learned the phrasings, not the routing.

Library API (more knobs: git ratchet, journal, seeding):

```elixir
{:ok, adapter} = Faber.Adapter.load("adapters/faber-elixir")
[result | _]   = Faber.Scan.run()

state = Faber.Loop.refine(result, adapter,
  strategy: :reflect,
  max_iterations: 5,
  trigger: true,
  trigger_holdout: true,
  seed: existing_proposal,        # start from a skill you already have (optional)
  path: "skills/foo/SKILL.md",    # write candidates to disk (optional)
  git: true, git_paths: ["SKILL.md"], dir: "skills/foo",   # commit keeps / revert rejects
  journal_path: "refine.jsonl"    # one JSONL entry per iteration
)

state.best_composite   # final score
state.best_proposal    # final %Faber.Proposal{} — install this
state.holdout          # %{composite:, behavioral:, fixtures:} when --holdout
state.history          # every iteration's keep/reject entry
```

---

## 9. Step 5 — Install & sync across agents

### Proposals are kept

Every skill Faber drafts costs real LLM tokens, so **every one is written to disk before it is
printed** — `~/.faber/proposals/`, one JSON file per proposal, readable with `cat` and removable
with `rm`. Nothing is ever evicted, expired, or invalidated on Faber's initiative; the only thing
that removes a proposal is you asking (`--prune`).

```sh
faber proposals                  # everything drafted and kept
faber show <id>                  # one proposal's SKILL.md + eval breakdown + provenance
faber install <id>               # install it (diff-first — see below)
faber proposals --prune --keep 20
```

`<id>` is `<session-hash>-<content-hash>`, and **any unambiguous prefix works** (git-style). Note
the first segment is the session, so proposals from the same session share a prefix — an ambiguous
prefix lists the candidates rather than guessing.

| Column | Meaning |
|---|---|
| `composite` | the eval score this artifact was gated on |
| `outcome` | `single` (one session), `merged` (a `--top N` merge), `kept` (singleton cluster), `kept_original` (its cluster's merge failed) |
| `engine` | which scorer produced the composite — `adapter:exec-in-place` is the stack's real bar, `native:fallback` only certifies generic markdown structure |
| `src` | how many sessions fed it (a `merged` artifact spans several) |

A **`merged` artifact is the only copy there will ever be**: it's drawn from several sessions at
once, so no `propose --rank N` can reproduce it. That's why it's recorded with every session that
fed it.

### Installing

**Install** writes `<skills_dir>/<name>/SKILL.md` (default `~/.claude/skills`) plus the
`.faber.json` provenance marker (installer, name, `installed_at`, source session, and a hash of
what Faber wrote — never the transcript path).

```sh
faber install <id>               # from an artifact
faber propose --install          # or: faber refine --install (same code path)
```

An existing skill is **never silently overwritten**. If one is already installed under that name,
`install` prints a diff of what would change and exits 1:

```
investigate-retry-loops is already installed at ~/.claude/skills/investigate-retry-loops/SKILL.md.

DRIFT — this skill has been hand-edited since Faber installed it. --force discards
those edits permanently; they are not in the proposal store.

Installed (-) vs this proposal (+):
    ## Iron Laws
  - - MY OWN HAND-EDITED LAW
    ⋯ 34 unchanged lines
```

**DRIFT** appears only when the installed file differs from what Faber itself wrote — i.e. when
`--force` would destroy *your* edits rather than Faber's own earlier output. A skill Faber can't
verify (no recorded hash) is reported as *not* drifted, never as drifted.

```elixir
Faber.Install.install(proposal, adapter: adapter)          # library form
Faber.Install.list_faber_installed()                       # only Faber's own skills
Faber.Install.drift?(path)                                 # hand-edited since we wrote it?
```

**Sync** makes *other* agents aware of the installed skills. It maintains one managed,
digest-guarded block in each agent's shared context file — your own text in that file is never
touched, and hand-edits *inside* the block are detected and refused without `--force`:

```sh
faber sync --target claude,codex     # write/update the pointer blocks
faber sync --check                   # report drift only, write nothing (exit 1 on drift)
```

Registered targets: `claude` → `~/.claude/CLAUDE.md`, `codex` → `~/.codex/AGENTS.md`.
(`--dir` / `--file` override the skills dir and context file, mainly for testing.)

---

## 10. Step 6 — Feedback: did the skill actually help?

Days or weeks after installing, close the outer loop:

```sh
faber feedback                       # usage across THIS project's sessions
faber feedback --all                 # usage across every project
faber feedback --format codex        # judge usage in another agent's sessions
```

For **every Faber-installed skill** (provenance marker — your own skills are never analyzed),
Faber partitions the scanned sessions that ran *after the install* (`installed_at` from the
marker; transcript mtime is the proxy for when a session ran) into those whose `skills_used`
mention the skill and those that don't, then reports:

```
  skill                            sessions  used   rate   friction w/  w/o   verdict
  investigate-retry-loops                12     3    25%         0.31  0.55   active
  ecto-migration-safety                  12     0     0%            —  0.48   unused

unused: ecto-migration-safety — sessions ran but the skill never fired; `faber refine --trigger`
its routing, or remove it.
```

| Verdict | Meaning | What to do |
|---|---|---|
| `active` | fires regularly | nothing — it's working |
| `low_usage` | fires in <10% of sessions | check whether its trigger description is too narrow |
| `unused` | sessions ran, never fired | `faber refine --trigger` (routing problem) or retire it |
| `no_sessions` | nothing ran since install | wait |

**Scope matters here.** A skill judged against one project's sessions is judged on whether it fires
*in that project*. That is usually the question you want — but a general-purpose skill that fires
happily elsewhere will read as `unused` here. Use `--all` for the machine-wide verdict.

Feedback is read-only — it never retires or edits anything, and it consumes only scan
aggregates (usage flags + friction scores), never transcript text.

---

## 11. Proposing across many sessions (`--top N`)

Scanning many sessions produces near-duplicates ("investigate-retry-loops",
"investigate-failing-commands", …). Installing all of them pollutes routing. `--top N` drafts a
skill per top-ranked session, clusters near-duplicates, and LLM-merges each cluster — every merge
must pass the eval gate or the originals are kept:

```sh
faber propose --top 5                   # top 5 sessions → propose → cluster → merge → gate
faber propose --top 10 --dry-run        # which 10 it would draft, and the calls that costs
faber propose --top 10 --cluster-threshold 0.5
faber propose --top 5 --trigger         # score merges with the behavioral trigger dimension
```

`--rank N` (§6) and `--top N` are the two ways to say *which sessions* — one session by rank, or
the top N. They contradict each other, so passing both is an error rather than a silent
precedence rule.

This is the most expensive thing here — `--top 10` is ten drafts plus a merge call per cluster —
so `--dry-run` (§6) is worth a look first. Like the rest, it ranks **this project's** sessions
unless you pass `--all`.

> **`faber consolidate` is the deprecated spelling of this.** It still runs, forwarding every flag
> unchanged (bare `consolidate` means `--top 5`), and prints a pointer here. One difference worth
> knowing if you scripted it: `consolidate --top 1` used to cluster a lone proposal with nothing
> and file it ungated. `propose --top 1` is now just `faber propose` — one draft, through the eval
> gate like any other.

| Flag | Meaning | Default |
|---|---|---|
| `--top N` | how many top-friction sessions to draft proposals from | 5 |
| `--dry-run` | list the sessions it would draft and the calls it would spend, then exit 0 | off |
| `--all` | draw the top-N from every project, not just the one you're in | off |
| `--cluster-threshold F` | token-Jaccard similarity for two proposals to share a cluster | 0.3 |
| `--trigger` | add the behavioral trigger-accuracy dimension to the merge gate | off |
| `--force` | include sessions that fail the adapter's stack-match gate | off |

(`--source`, `--format`, `--db`, `--base`, `--min-messages`, `--limit` pass through to the scan,
same as a single-session propose.) Output is one line per cluster outcome — `MERGED` (with the merge's
eval composite), `kept` (singleton), `kept-originals` (merge scored below the gate), `error`
(merge LLM call failed) — plus a summary count.

**Every outcome is kept** (§9): merges, kept singletons, and the originals of a merge that failed
its gate are each written to `~/.faber/proposals/` before anything prints, and the run ends by
listing their ids. This matters most for a `merged` artifact — it's drawn from several sessions at
once, so no `propose --rank N` can reproduce it. Nothing is installed automatically; install a
winner with `faber install <id>`.

**Progress.** A `--top 10` run is ~10 LLM calls for the drafts plus one per cluster merge, so each
step reports to stderr as it happens: `drafting 3/10 faber/a1b2c3d4…`, then `merging cluster 2/4 —
investigate-retry-loops + investigate-failing-commands…`. Sessions that fail the stack gate are
skipped and **named** (`--force` includes them) rather than silently dropped.

The same pipeline as a library:

```elixir
{:ok, adapter} = Faber.Adapter.load("adapters/faber-elixir")

# Stage 1 — pure & deterministic: inspect clusters BEFORE spending tokens.
clusters = Faber.Consolidate.cluster(proposals)             # token-similarity grouping

# Stage 2 — one LLM call per multi-proposal cluster, gated by the eval:
outcomes = Faber.Consolidate.run(proposals, adapter)
# [{:merged, merged, eval, originals},   # merge passed the gate — install `merged`
#  {:kept, single},                      # singleton, untouched
#  {:kept_originals, originals, eval},   # merge FAILED the gate — originals survive
#  {:error, originals, reason}]          # LLM call failed — originals survive
```

A merged skill that scores below the bar is rejected and the originals kept — consolidation can
never trade quality for tidiness. Merged provenance records `merged_from` + all source
session ids.

---

## 12. Dashboard & MCP server

```sh
faber serve                     # opens http://localhost:4710 (release) — Ctrl-C to stop
faber serve --port 5000 --no-open
iex -S mix phx.server           # dev mode: http://localhost:4010
```

The **dashboard** is a LiveView table of ranked friction with a per-row **Propose** button.
That button spends LLM tokens, so it sits behind a browser confirm; it's on by default
(human-initiated) and can be disabled outright with `config :faber, :web_allow_propose, false`.
The endpoint binds loopback only and pins socket origins to localhost.

The same process serves a **read-only MCP server** at `http://localhost:<port>/mcp`. Connect a
coding agent:

```sh
claude mcp add --transport http faber http://localhost:4710/mcp
```

| Tool | What | Opt-in? |
|---|---|---|
| `faber_search_friction` | ranked friction findings — **aggregates only**, never transcript text | no |
| `faber_list_skills` | installed skills (name + description) | no |
| `faber_get_skill` | one skill's full `SKILL.md` | no |
| `faber_propose_skill` | propose + gate (+ optionally install) — calls an LLM | **yes**: `config :faber, :mcp_allow_propose, true` |

The MCP server only starts under `faber serve` / `mix phx.server` — never for one-shot
commands.

---

## 13. Cross-agent ingest

Faber is agent-agnostic: each agent's on-disk transcript shape is one format module behind a
single behaviour, so the engine never learns whose session it's reading. Pick with `--format`
(or `config :faber, :ingest_format`):

| `--format` | Agent | Reads | Notes |
|---|---|---|---|
| `claude` (default) | Claude Code | `~/.claude/projects/**/*.jsonl` | validated on real data |
| `codex` | OpenAI Codex | `~/.codex/sessions/**/rollout-*.jsonl` | validated on real data |
| `cline` | Cline (VS Code) | `…/saoudrizwan.claude-dev/tasks/*/api_conversation_history.json` | documented shape |
| `gemini` | Gemini CLI | `~/.gemini/tmp/*/chats/…` | documented shape |
| `gemini` + `--base ~/.qwen/tmp` | Qwen Code | same shape, different root | |
| `opencode` | OpenCode | `~/.local/share/opencode/opencode.db` | needs the `sqlite3` CLI |

Every format canonicalizes tool names to Faber's vocabulary (`Bash`/`Read`/`Edit`/`Write`/…),
so the same friction signals fire across agents. Whole-file formats (cline, gemini) cap reads
at 50 MB defensively; opencode caps each session's query result the same way.

OpenCode keeps every session in one shared DB, so its session handles are **pseudo-paths** —
`"<db>#<session_id>"` — one per session (this is what `Ingest.discover(format: :opencode)`
returns and what shows up as the session label). If the `sqlite3` CLI is missing, ingest
degrades to a single whole-DB handle whose read reports the error.

**Sources** are orthogonal to formats: `--source files` (default) walks the directories above;
`--source ccrider` reads ccrider's SQLite index of Claude sessions instead (`--db` to point at
it, default `~/.config/ccrider/sessions.db`) — useful when you already index sessions there.

---

## 14. Adapters: the stack-awareness

The adapter is why Faber's output isn't generic slop: it supplies both the **generation
knowledge** (Iron Laws, playbooks, idioms → woven into the propose prompt) and the **eval
criteria** (what "correct for this stack" means). Correct-for-Elixir ≠ correct-for-Rails.

- Ships today: [`adapters/faber-elixir`](../adapters/faber-elixir/) (reference; extracted from
  the `claude-elixir-phoenix` plugin with zero plugin diffs) and
  [`adapters/faber-python`](../adapters/faber-python/).
- Select via `config :faber, :adapter_dir, "adapters/faber-python"` (the CLI uses the
  configured adapter; `mix faber.propose --adapter DIR` overrides per-run).
- The **stack gate** keeps sessions and adapters honest: a session whose touched files don't
  match the adapter's `file_globs` is refused unless `--force`.
- **Writing your own** is a declarative exercise — YAML + markdown + a render template, no
  Elixir. Follow [`ADAPTER_CONTRACT.md`](ADAPTER_CONTRACT.md) (v0.2). The `faber-python` pack
  is the proof this works: it stood up with zero engine diffs.
- Adapter packs are treated as **untrusted input**: validated at load, fail-closed at runtime
  (bad regexes degrade to never-match; template paths can't escape the pack).

---

## 15. LLM backends

All generation goes through one behaviour (`Faber.LLM`); pick the backend globally or per-call.

**`Faber.LLM.ClaudeCLI` (default — keyless).** Shells out to your local `claude -p` with
structured-output prompting. Uses your existing Claude Code auth; no API key, no per-token
bill beyond your subscription.

```elixir
config :faber, :llm, Faber.LLM.ClaudeCLI     # already the default
config :faber, :claude_bin, "claude"          # path/name of the CLI
config :faber, :claude_model, "sonnet"        # optional; omit for the CLI's default
config :faber, :claude_timeout_ms, 300_000    # kill a hung CLI after 5 min (default)
```

**`Faber.LLM.ReqLLM` (API).** Direct Anthropic API via ReqLLM.

```elixir
config :faber, :llm, Faber.LLM.ReqLLM
config :faber, :llm_model, "anthropic:claude-sonnet-4-6"
# export ANTHROPIC_API_KEY=…  (or CLAUDE_API in .env — the live test maps it)
```

**`Faber.LLM.Stub` (tests/offline).** Deterministic canned proposal; `:stub_response`
overrides it. This is why the whole pipeline is testable with no key and no network.

---

## 16. Scheduled / overnight runs

`Faber.Schedule` runs the whole pipeline (scan → propose → eval → optional install) on a fixed
interval. It is **started inert** — the supervision tree always boots it, but it does nothing
until you opt in:

```elixir
config :faber, :schedule,
  enabled: true,
  every_ms: :timer.hours(8),
  initial_delay_ms: :timer.minutes(1),   # optional; defaults to every_ms
  max_run_ms: :timer.minutes(30),        # wedge guard: kill a run exceeding this
  adapter_dir: "adapters/faber-elixir",
  top: 3,                                # propose for the top-N ranked sessions
  install: false,                        # auto-install passing skills? (default: no)
  scan: [limit: 400, min_messages: 4]
```

Runs never overlap (a tick during a running job is skipped), each run logs a one-line summary,
and `Faber.Schedule.run_once/1` drives the same pipeline synchronously if you want it in a cron
of your own. Faber takes **no autonomous action by default** — `enabled: true` and
`install: true` are both explicit choices.

---

## 17. Python sidecar & GEPA (optional)

The `python/` directory hosts a stdlib-only eval engine (matcher parity with the native one,
enforced by tests) and the seam for `dspy.GEPA` optimization. You need it only if you:

- want scoring through Python: `config :faber, :eval_engine, :sidecar` (JSON over
  stdin/stdout; `config :faber, :python` / `FABER_PYTHON` picks the interpreter,
  `:sidecar_timeout_ms` guards hangs — default 2 min), or
- opt into the heavy GEPA optimizer: `Faber.Optimize.run/2` → the sidecar's `optimize` command.
  The orchestration is implemented and tested, but the live `dspy.GEPA` path needs the optional
  `gepa` extra plus a provider key, and degrades to `not_implemented` without them. For v1
  self-improvement use the keyless reflective loop (§8) — that's the supported default.

```sh
cd python && python3 -m unittest discover -s tests    # sidecar's own suite
```

---

## 18. Configuration reference

All under `config :faber, …` unless noted. Everything has a working default; an empty config
is a valid setup.

| Key | Default | Meaning |
|---|---|---|
| `:llm` | `Faber.LLM.ClaudeCLI` | LLM backend module |
| `:llm_model` | `"anthropic:claude-sonnet-4-6"` | model for ReqLLM |
| `:claude_bin` | `"claude"` | CLI binary for ClaudeCLI |
| `:claude_model` | (CLI default) | `--model` for ClaudeCLI |
| `:claude_timeout_ms` | 5 min | hung-CLI guard |
| `:eval_engine` | `:native` | `:native` or `:sidecar` |
| `:eval_threshold` | `0.75` | gate bar |
| `:adapter_dir` | `adapters/faber-elixir` | active adapter pack |
| `:skills_dir` | `~/.claude/skills` | install target |
| `:proposal_store` | `true` | keep every drafted proposal on disk (§9). Off ⇒ nothing is kept and you pay again for anything you didn't copy out |
| `:proposals_dir` | `~/.faber/proposals` | where kept proposals live. Retention is manual: `faber proposals --prune [--keep N]` (default 50) is the only thing that removes one |
| `:ingest_format` | `:claude` | default `--format` |
| `:ingest_source` | `:files` | default `--source` |
| `:python` / `FABER_PYTHON` | `"python3"` | sidecar interpreter |
| `:sidecar_timeout_ms` | 2 min | sidecar hang guard |
| `:schedule` | `enabled: false` | see §16 |
| `:mcp_allow_propose` | `false` | enable the side-effecting MCP tool |
| `:web_allow_propose` | `true` | dashboard Propose button |
| `PORT` (env, release) | `4710` | serve port (`faber serve --port` overrides) |
| `FABER_HOME` (env, release) | `~/.faber` | where the release keeps its secret |
| `FABER_LOG_LEVEL` (env, release) | `info` | the release ships quiet (no per-request/per-event framework logs); set `debug` to get them back |

---

## 19. Privacy & safety guarantees

These are design invariants, not defaults you can accidentally flip:

- **Transcripts never leave analysis.** Everything user-facing (MCP tools, dashboard, propose
  prompts, provenance markers) carries *aggregates* — signal counts, scores, fingerprints —
  never raw transcript text or transcript file paths.
- **Your directories are shared, not owned.** Faber tracks what *it* installed via
  `.faber.json` and only ever lists/syncs/analyzes those. Sync writes one delimited managed
  block and refuses to overwrite hand-edits without `--force`.
- **No autonomous spending.** Every LLM call is triggered by an explicit human action; the MCP
  propose tool and the scheduler's auto-install are opt-in config.
- **Local only.** The web endpoint binds `127.0.0.1` with origins pinned to localhost; there is
  no auth because there is no remote exposure.
- **Faber never commits to your projects.** The loop's git ratchet only ever operates on the
  skill directory you point it at.
- **Untrusted-input hardening.** Transcripts and adapter packs are parsed defensively:
  string keys only (no atom exhaustion), validated regexes, path-traversal-safe templates,
  size caps on whole-file reads, timeouts on every subprocess.

---

## 20. Testing & development

```sh
mix verify            # THE pre-commit gate: format · compile --warnings-as-errors ·
                      #   credo --strict · dialyzer · test   (also `make verify`)
mix test              # hermetic — no python3/sqlite3/network/key; the default gate
mix test.full         # + :sidecar (python3) + :ccrider/:opencode (sqlite3) — run before
                      #   committing eval-matcher / sidecar / SQLite-ingest changes
mix test.live         # keyless END-TO-END with a real model via `claude -p` (spends quota)
mix test.live.api     # ReqLLM against the real API — needs CLAUDE_API in .env, costs money
mix credo --strict    # lint on its own
mix dialyzer          # type-check on its own (first run builds a PLT into _build/plts)
```

Lint rules live in `.credo.exs`; Dialyzer's config is `dialyzer/0` in `mix.exs`, with justified
exceptions in `.dialyzer_ignore.exs`. Both are expected to stay green.

CI (`.github/workflows/ci.yml`) runs two parallel jobs on every push/PR: **check** (format check,
warnings-as-errors, `mix credo --strict`, `mix test.full`, the Python suite) and **dialyzer**
(split out because it's the slow one; findings appear as inline PR annotations). Releases build
from tags (`.github/workflows/release.yml`).

---

## 21. Troubleshooting

The CLI explains these itself now — it maps known failures to plain English rather than dumping an
Elixir tuple. This section is the longer form (and covers what an unrecognized error, which still
prints as a raw tuple, might mean).

**`faber scan` shows "No sessions matched." / `propose` says "no sessions found under …".**
Wrong root or too-strict filter — both commands list the causes inline, and which causes they list
depends on the scope (§5). Inside a project Faber found, the root is provably right, so try
`--min-messages 0` or `--all`. Globally, check `--base` (see §13 for each format's default location)
and confirm the format matches the agent whose sessions you want. Note "no sessions found" (an empty
corpus) is a *different* problem from "no session at rank N — only M sessions matched" (a rank past
the end of a real corpus).

**`faber scan` ranks sessions from other projects.**
You asked it to, one of three ways: `--all`, a `--base DIR` override (an explicit root disables cwd
scoping), or standing somewhere with no recorded sessions — in which case it falls back to the
global ranking *and says so* on the first line. See §5.

**`faber scan` says "no sessions recorded for this directory" in a project you've used.**
The scope is keyed on the working directory, walking up to the git root. If your sessions were run
from a *different* path for the same code — a worktree, a symlinked checkout, a different mount —
they're recorded under that path, not this one. Use `--all` to see everything, or `--base DIR` to
name the transcript root directly (§13).

**`faber propose` fails with `stack mismatch`.**
Working as intended: the session's files don't match the adapter's globs. Either switch the
adapter (§14) or `--force` if you really want an off-stack draft. `--top N` *skips* mismatched
sessions and names them rather than failing, since it works on a batch.

**"the `claude` CLI isn't on PATH" or propose hangs then times out.**
The `claude` CLI isn't installed/on PATH (set `config :faber, :claude_bin`) or is hung —
`:claude_timeout_ms` kills it after 5 min and reports the bound it exceeded.

**`--format opencode` / `--source ccrider` errors mentioning sqlite3.**
Install the `sqlite3` CLI; for ccrider also check the `--db` path. A corrupt/missing DB
degrades to a logged warning and an empty scan, not a crash.

**Trigger eval scores jump between runs.**
Expected — routing is a noisy LLM classification. Use `--trigger-samples 3` (pooled; the loop
already defaults to 3) and read the reported `σ`.

**`{:error, :insufficient_fixtures_for_holdout}` from `faber refine --holdout`.**
The seed proposal needs at least 2 `should_trigger` AND 2 `should_not_trigger` fixtures to
split. Re-propose (the proposer normally emits 2+2) or drop `--holdout`.

**Eval composite seems stuck below threshold on your own hand-written skill.**
Run `Faber.Eval.score(skill_md, [])` in IEx and read `dimensions.*.assertions` — each failed
check names exactly what's missing (frontmatter fields, ≥3 Iron Laws, a ≥2-line example, …).

**Dashboard Propose button missing.**
`config :faber, :web_allow_propose, false` is set, or you're not on localhost (origins are
pinned to loopback by design).
