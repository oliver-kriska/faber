# Dogfood — Faber on real ~/.claude history (2026-06-25)

First end-to-end run of the engine against the **real** corpus (not fixtures), to judge whether
the output is *good*, not just whether the mechanics work. Verdict: **thesis validated**, with one
concrete proposer weakness found.

## Scan (`mix faber.scan --top 20`)

- **1435 non-trivial sessions scored in ~4.4s** (5742 raw transcripts; 1226 tier-2 eligible).
  Fast enough to run interactively on a large history.
- Ranking matches lived experience: enaia (the most-iterated project) dominates the top
  (#1,2,6–9,11–13); **this very Faber session (`31f10cff`) ranked #3** — flagged
  `user_corrections` + `context_compactions`, which is accurate (we compacted once + had
  course-corrections).
- Signals (`context_compactions`, `user_corrections`, `retry_loops`) and fingerprints
  (`bug-fix`/`feature`/`review`/`maintenance`) are interpretable — not noise.
- #1: enaia `ed546e0c`, raw 121.06, 5543 msgs, 2056 tools, 62 errs, dominant `context_compactions`.

## Propose (`mix faber.propose --rank 1`, keyless `claude -p`, ~90s)

Produced **`debug-context-budget`** — composite **0.88 (PASS @ 0.75)**. Genuinely useful, not
generic:
- Correctly diagnosed the friction (60 compactions from whole-file re-reads + raw mix/test dumps
  → thread-loss → the follow-on corrections/retries).
- Ecosystem-aware: noted none of the 12 already-used skills governs context budget; positioned to
  **complement** `/phx:investigate` ("investigate answers 'why', this answers 'how to survive a
  long why'"); routes fan-out reads to the plugin's real subagents (Explore/call-tracer/
  deep-bug-investigator); checkpoints to the scratchpad the SessionStart hook advertises.
- Iron Laws are concrete + Elixir-specific (focused `mix test file:line`, reserve the full gate
  for verify, quote file:line vs re-read).

## Concrete finding (next improvement)

Eval dimensions: clarity **0.50**, triggering **0.67** (the rest 1.0). Root cause: the LLM left
the **`## Workflow`** and **`## Patterns`** sections **empty**. So the proposer/template doesn't
force those sections to be filled — the single highest-leverage proposer-quality fix surfaced by
dogfooding. Options: (a) prompt the proposer to always populate Workflow/Patterns, (b) have the
template omit sections the model leaves empty, or (c) confirm the clarity matcher is penalizing
empty headers (it appears to, correctly).

Note: eval logged "adapter eval is exec-in-place; using default native scoring" — the faber-elixir
adapter's referenced scorer is env-bound, so scoring fell back to native default (per
ADAPTER_CONTRACT §7). Expected, but worth confirming the vendored-dims path on a real run later.

## Takeaway

The detector ranks real friction sensibly and the proposer produces a genuinely useful, stack-aware,
eval-passing skill from a real session — the core premise holds. The clearest next lever is
proposer completeness (empty Workflow/Patterns), not the detector.

---

## Follow-up (same day): fixing the proposer gaps + closing the install loop

Acting on the finding above. Two **renderer-structural** bugs found and fixed, plus one
**cross-agent feature** bug found and deliberately *not* auto-fixed.

### Fix 1 — populate Workflow/Patterns (commit `dfd9cd5`)

Added `workflow: [String.t()]` + `patterns: [String.t()]` to `Faber.Proposal`, the `@schema`, the
system-prompt asks, `build_proposal` mapping, `template_context`, and both render paths. Renderers
**presence-gate** each section (empty list ⇒ the whole `## Section` header drops — no dangling
heading). Workflow → numbered list, Patterns → bold do/don't bullets — both shapes the clarity
matcher's `action_density` counts as actionable.

Result on re-propose (rank 1): `action_density` went from failing to **0.83 (pass)**.

### Fix 2 — guarantee a ≥2-line worked example (commit `4e12f33`)

Re-dogfooding revealed the fix above was necessary but not sufficient: **clarity stayed at 0.50**.
`clarity` is two checks — `action_density` (now pass) AND `has_examples` (a fenced block with ≥2
non-empty lines). The faber-elixir `skill.md.tmpl` ships a single fenced block (Usage) and the
renderer filled it with **one** prose line. (The built-in renderer only passed because it has a
separate two-line `## Examples` fence.)

Introduced `usage_block/1` — a usage comment over the concrete example, **always ≥2 non-empty
lines** even when the LLM omits usage/example (fallback comment + stub) — and used it for *both* the
built-in `## Examples` fence and the template's Usage fence. The minimum is structural, so the check
can't regress on an uncooperative draw.

Result on re-propose (rank 1): **clarity 0.50 → 1.00, composite 0.88 → 0.93.**

### Deliberate non-fix — `triggering` 0.67 (description length)

The last sub-1.0 dimension is `triggering` (2/3): `description_length` fails because the LLM draws a
**287-char** description vs the 250 cap. *Not* clamped: a deterministic truncation would cut the
genuinely useful `NOT for …` disambiguation clause (which `description_structure` rewards and which
helps routing) — i.e. gaming the proxy *against its own intent*. This is LLM content variance, which
is the **reflective loop's** (`Faber.Optimize.reflect`) job, not a renderer guarantee. The skill
already PASSes at 0.93.

**Lesson:** fix the generator when the *renderer structurally can't pass* regardless of the model
(Fixes 1 & 2); do **not** add deterministic shims that satisfy a proxy metric by degrading real
output quality (the description clamp).

### Install (loop closed)

Installed the vetted 0.93 artifact to `~/.claude/skills/context-budget/SKILL.md` via
`Faber.Install.install/2`. **Claude Code auto-discovered it immediately** (appeared in the
available-skills list mid-session) — for Claude, dropping the `SKILL.md` *is* the sync; the
managed-block pointer is only for agents that don't auto-discover (e.g. codex/AGENTS.md).

### New finding — `sync_pointer` over-claims on a shared skills dir (NOT fixed; needs a decision)

`Faber.Install.sync_pointer/2` builds its managed block from `list_installed(dir)`, which returns
**every** `*/SKILL.md` under the dir. Against the real `~/.claude/skills` that is **38 skills**
(cmux-*, cloudflare, agents-sdk, …) — almost all pre-existing and *not* Faber-installed. Running the
sync would inject a `# Faber-managed skills` block into the user's **global `~/.claude/CLAUDE.md`**
falsely claiming Faber installed all 38, polluting the instructions loaded into every session.

Root cause: the cross-agent pointer design assumes a **Faber-dedicated** skills dir. It has no
notion of *provenance* (which skills Faber installed vs. which were already there).

**FIXED** (commit `5d1032d`) — went with the provenance marker. `Faber.Install.install/2` now drops
a `.faber.json` sentinel beside each `SKILL.md` (a `%Proposal{}` also records
adapter/source_session/fingerprint — never the transcript `path`, per the privacy boundary). New
`list_faber_installed/1` filters `list_installed/1` to marked dirs; `sync_pointer`/`check_pointer`
**and** the MCP `faber_list_skills`/`faber_get_skill` tools now use it (the MCP fork resolved itself
— both tools' moduledocs already said "skills Faber has installed", so the filter is simply the
behavior they always documented). `list_installed/1` stays the generic "all skills in dir" primitive.

Verified on the real dir: `list_faber_installed` → `["context-budget"]` while `list_installed` → 39.
The other options were rejected: a frontmatter `faber: true` key pollutes the visible skill content,
and a dedicated dir breaks Claude's `~/.claude/skills/*` auto-discovery.

The pointer-sync into the global `~/.claude/CLAUDE.md` was still **not run** — it's now safe (lists
only `context-budget`) but redundant for Claude (auto-discovery already loads the installed skill;
the pointer's real value is cross-agent, e.g. codex's `AGENTS.md`). Left as a one-command opt-in.
