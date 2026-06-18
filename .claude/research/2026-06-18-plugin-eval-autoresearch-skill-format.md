# Plugin source study — eval gate, autoresearch loop, skill format (M3–M6)

> Read-only study of the plugin repo (`/Users/oliverkriska/Projects/elixir-live-claude-engineer`)
> to port its skill-evaluation, self-improvement loop, and skill-authoring conventions into
> Faber's M3 (proposer), M4 (eval sidecar), M5 (loop), M6 (dashboard). Source of truth for the
> ports; quote exact thresholds here so the Elixir/Python re-implementations match.

## M3 — Skill proposer (LLM, adapter-informed)

**LLM client:** use **ReqLLM** (`agentjido/req_llm`). `ReqLLM.generate_object/4` for structured
JSON output (Anthropic via tool-calling; Azure/OpenAI via `response_format: json_schema`).
Confirmed in KB (xuku-enaia, phd-knowledge-pipeline both standardized on ReqLLM). One library,
one API-key setup, unified errors. Faber wraps it behind a `Faber.LLM` behaviour so tests use a
stub and no key/network is needed in CI.

**What a well-formed skill looks like** (the proposer must emit this):

- **Frontmatter:** `name` (namespaced, e.g. `phx:my-skill`), `description` (50–250 chars,
  *what + when*), `effort` (low/medium/high). Optional `disable-model-invocation: true` for
  user-invoked orchestrators; `paths:` globs for file-context auto-load.
- **Description formula:** `"<domain noun phrase> — <specific sub-topics>. Use when <scenario1>,
  <scenario2>. [NOT for <adjacent domain>.]"` Concrete tech/error names beat category labels
  ("CSRF/CSP/path traversal" > "OWASP"). Negative triggers short (≤30 chars).
- **Body:** ~100 lines target, hard cap 185; no section > 40 lines.
- **Mandatory sections:** `## Iron Laws — Never Violate These` (≥3 numbered invariants, treated
  **append-only** by the loop); `## Usage` (fenced code block); `## References`
  (`${CLAUDE_SKILL_DIR}/references/*.md`). At least one `elixir`/`bash` fenced example.
- **Inline execution-critical content** — plugin skills live outside cwd, so `references/` reads
  prompt a permission dialog that subagents can't answer. Decision logic goes in SKILL.md.

session-scan/deep-dive/trends are the detection source; their `friction`, `fingerprint`,
`plugin_opportunity` are exactly Faber's `Scan.Result` fields — the proposer's input.

## M4 — Eval gate (Python sidecar `score`)

**Dependencies (critical):** the plugin's `lab/eval/` is **pure stdlib + PyYAML** (`requirements.txt`:
`PyYAML`, `pytest`). No dspy/litellm/openai. `trigger_scorer.py` shells out to the `claude` CLI
(needs a key) — that's the ONLY API-dependent part. **⇒ Structural scoring runs with plain
`python3`, no uv, no key.** GEPA/`optimize` is the only blocked piece (needs dspy + key).

**Scoring contract:**
- Input `ScoreRequest`: `target_path`/content, `target_kind` ∈ {skill, agent, trigger},
  optional `eval_def` (dimensions→weight + checks→{check_type, weight, params}).
- Output `ScoreResult`: `composite` (0–1), `dimensions{name → {score, passed, failed, total,
  assertions[]}}`.
- `dimension.score = Σ(weight | passed) / Σ(weight)`; `composite = Σ(dim.weight × dim.score) / Σ(dim.weight)`.
- Matcher signature: `(content, **kwargs) -> (bool, evidence_str)`. Pure, no I/O (except optional
  file line-count / cross-ref existence).

**Default dimension weights** (`scorer.py`): completeness 0.20, accuracy 0.15, conciseness 0.15,
triggering 0.15, safety 0.10, clarity 0.10, specificity 0.10, behavioral 0.10. Template variant
(no clarity/specificity/behavioral): completeness 0.25, accuracy 0.25, conciseness 0.20,
triggering 0.15, safety 0.15.

**Core matchers to port** (with thresholds):
- `section_exists(section)`; `max_section_lines(max=40)`; `line_count(target=100, tolerance=85)`
  (≤185 ok); `token_estimate(max_tokens=500)` (words/0.75).
- `frontmatter_field(field, expected?)`; `description_length(min=50, max=250)`;
  `description_keywords(min=5, keywords=<40 domain words>)`; `description_no_vague(forbidden=
  ["general","various","etc","sometimes","might","possibly"])`; `description_structure`
  (has_what = `^[A-Z][a-z]+\s`; has_when = `\b[Uu]se\s+(when|after|for|to)\b`).
- `has_iron_laws(min_count=1)` (count list items in an "iron law" section);
  `no_dangerous_patterns(default=[raw(/1, String.to_atom(, MIX_ENV=prod, |raw])` — **excludes**
  sections named iron law/anti-pattern/red flag/detection/checklist/vulnerabilit/confidence level
  and table rows.
- `content_present(pattern)`/`content_absent(pattern)`/`grep_count(pattern,min,max)`.
- `has_examples(min_blocks=1, min_lines=2)`; `action_density(min_ratio=0.4)`;
  `specificity_ratio(min_ratio=0.3)`; `no_duplication(ngram=5, max_dupes=3)`.
- accuracy cross-ref matchers (`valid_skill_refs`/`valid_agent_refs`/`valid_file_refs`) need a
  plugin tree on disk → for a *standalone proposal* treat as optional/skip (no tree to resolve).
- behavioral reads cached trigger results (accuracy≥0.75, precision≥0.80, recall≥0.60,
  high-sev deviations≤2); skip when no cache → neutral score 1.0.

**trigger_scorer:** builds a system prompt listing all skill descriptions (≤150 chars each),
asks a judge model "which skill(s)?" via `claude -p ... --model ...`, computes a confusion matrix
(tp/fp/fn/tn), `precision = tp/(tp+fp)` (1.0 if denom 0), `recall = tp/(tp+fn)`, `accuracy =
correct/total`. Deviations classified heuristically (no API). Needs a key ⇒ later.

Integration test bar: a real skill scores composite ≥ 0.95.

## M5 — Autoresearch loop (deterministic keep/revert/plateau)

The proven loop is **not GEPA** — it's a hand-rolled generate→eval→keep with git as the ratchet.

**One iteration:** read state → select target (failing dimension) → propose **exactly one**
mutation → apply → eval (score + checks.sh) → keep or revert.

**Keep/revert decision** (`run-iteration.py` `cmd_eval`):
```
improved = new_composite >= prev_best        # tie → KEEP (newer wins)
verdict  = KEEP if (improved and checks_passed) else REVERT   # checks failure overrides score
```
`prev_best` = max `new_composite` of last 50 kept journal entries for that skill (else = new).

**Git ratchet:**
- KEEP: `git add <skill_dir>/ && git commit -m "autoresearch: {skill} {dim} {old}->{new}"`
- REVERT: `git checkout -- <skill_dir>/`   (HEAD always = current best)
- Branch: `autoresearch/sweep-{date}`.

**Stop conditions:** all targets composite ≥ **0.95** → COMPLETE; **max_iterations** (default 50)
→ COMPLETE; **50** consecutive global discards → STUCK; per-skill: **10** consecutive discards →
skip that skill; composite flat for **20** iters → switch strategy. (Tournament/Retention@K is a
post-saturation refinement: K=30, threshold 0.90, streak 2.)

**checks.sh (structural guard, forces REVERT on any fail):** markdownlint (if present); YAML
frontmatter parses with name+description; `wc -l ≤ 535`; referenced files exist; no conflict
markers; no empty sections; **Iron Laws append-only** (diff vs `git show HEAD:` — deletion/reword
fails). 30s timeout.

**Journal (`results.jsonl`, one obj/line):** `iteration, skill, dimension, old_composite,
new_composite, kept, timestamp(ISO8601 UTC), description, asi{}` (+ optional `deviation_type`,
`strategy_applied`).

**Faber port:** `Faber.Loop.run/1` pure driver (inject propose_fn/eval_fn → deterministic tests);
`Faber.Loop.Server` GenServer under a `DynamicSupervisor` for overnight runs. Oban scheduling is a
later add (don't pull ecto/oban yet). git ops scoped to the working dir only.

## M6 — Phoenix LiveView dashboard

No-build setup (no esbuild/tailwind): deps phoenix + phoenix_live_view + phoenix_html + bandit +
plug. Vendor `deps/phoenix/priv/static/phoenix.min.js` and
`deps/phoenix_live_view/priv/static/phoenix_live_view.min.js` into `priv/static/assets/`, serve via
`Plug.Static`, connect the LiveSocket with an inline `<script>` using the UMD globals. One
`FaberWeb.DashboardLive` mounts → `Faber.Scan.run/1` → ranked table + summary; "rescan" event.
Endpoint added to the supervision tree. Verify with `Phoenix.LiveViewTest` (no browser needed).
Ecto/DB not needed — scan is read-only over the filesystem.
