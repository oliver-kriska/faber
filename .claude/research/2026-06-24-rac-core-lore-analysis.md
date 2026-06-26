# rac-core / "Lore" — deep analysis & lessons for Faber

**Date:** 2026-06-24
**Source:** https://github.com/itsthelore/rac-core (cloned + read in full; 4 parallel analysis agents)
**Author of rac-core:** Tom Ballard (`itsthelore`). PyPI: `requirements-as-code`. Product brand: **Lore**. MCP server id: `io.github.tcballard/lore`. License Apache-2.0. ~23.5K LOC Python, src/ layout, 100+ test files, 83 ADRs authored in ~3 weeks (v0.1.0 2026-06-01 → 2026.06.4).

---

## 1. What it is

**Lore = Requirements as Code.** A deterministic, read-only knowledge-grounding system for coding agents. A team's recorded knowledge — requirements, decisions (ADRs), designs, roadmaps, prompts — lives as **typed Markdown** in the repo, is classified + validated against per-type schemas, and is served **read-only over MCP** to Claude Code / Cursor / Claude Desktop so the agent cites decisions instead of violating them.

Hard stance: **no RAG, no embeddings, no LLM judge.** Retrieval/classification/scoring is a deterministic function of `(corpus bytes, query, code)`. Enforcement happens at **write time** in CI (`rac validate` / `rac gate`), so bad knowledge never lands.

Three surfaces over one engine: **library** (`rac.__all__`), **CLI** (`rac`), **MCP server** (`lore`). Satellites spun out: **Wayfinder** (deterministic prompt-complexity router), **lore-connectors** (RAG/memory/graph export consumers).

**Relationship to Faber: adjacent and complementary, not competitive.** Same axis (make your coding agent better), different station: Lore *grounds* the agent in decisions already made; Faber *compiles* new skills from session friction. Composition is real both directions (see §5).

---

## 2. The big strategic parallel — determinism

Lore independently arrived at exactly Faber's recent conclusion (commit `3cdf897`: dropped reflective-opt because deterministic eval sidesteps variance). But Lore turned it into a **product pillar**, not a footnote.

- **ADR-066 (Deterministic Grounding Eval):** the scored path is "a pure deterministic function of (corpus, query set, retrieval code)" — no embeddings, no vector search, no LLM judge. Reasoning: an LLM-judge benchmark "could neither gate CI honestly nor detect a real regression versus model drift. We would be measuring the judge, not the retrieval."
- Determinism buys four things they sell as **trust**: reproducibility, CI-enforceability, auditability, and "the one number competitors cannot fake." They cite Sourcegraph publicly reversing out of embeddings as validation, and explicitly **decline to compete on vector-RAG**.

**Lesson for Faber:** Reframe deterministic eval from "we avoid variance" to a trust/CI claim: *"Faber's quality gate is a deterministic, reproducible function of (skill, adapter eval criteria, fixture set) — a green gate means the skill is genuinely better, not that a judge had a good day."* Hold the tension honestly: skill quality is partly behavioral/semantic, so Faber can't refuse LLM-judging entirely like Lore does — but the **gated statistic must be deterministic and byte-stable**, even if exploratory generation (GEPA/DSPy) is stochastic. Keep the stochastic part out of the *scored* path, exactly as Lore keeps fuzzy memory out of the *served* path.

---

## 3. The grounding-eval blueprint (most directly portable)

`src/rac/services/eval.py`, ADR-066, fixtures in `tests/eval/`. This is a near-exact blueprint for Faber's eval gate:

1. **Score the REAL surface, never a parallel scorer.** A `search_artifacts` eval case calls the exact `resolve.search_index` the MCP tool calls; `get_related` calls the exact `relationships.incoming_references` the tool serializes. Production ranking consumed verbatim — no re-sort. → *Faber's trigger-accuracy eval must invoke the same matching/trigger code that runs in production. Best defense against "passes the eval but behaves differently when installed."*
2. **Reframe quality as countable structural properties.** Precision@k / Recall@k at k∈{1,3,5} + a **hard-negative `negative_violations` count** (a `must_not_return` id in top-5). The hard negative is a *gate, not a soft metric* — the canonical failure is "a superseded decision presented as current." → *Faber: curated sessions with labelled `should_trigger` / `must_not_trigger` sets; a skill must NEVER fire on the must-not set ("must-not-break" fixtures per adapter). A skill that improves the metric but trips a must-not-break case fails outright — more defensible than aggregate score deltas.*
3. **Separate gated `metrics` (byte-stable) from `metadata`/`per_query` (diagnostic, excluded from comparison).** Floats rounded to 6 dp; tie-break by ascending id; `generated_at`/version live only in excluded `metadata`. → *Faber: keep timestamps/hashes out of the compared object so the gate is reproducible.*
4. **Floor + (baseline − tolerance), human-gated re-baseline.** Fixed floor = absolute regressions; baseline−0.02 = drift; **CI can never rebaseline** (a test statically parses every workflow's `run:` steps to prove `--update-baseline` never appears in CI). → *Critical for Faber's self-improving loop: the loop must never lower its own bar.*
5. **Prove the gate is real with regression-injection tests.** Remove a relevant artifact → recall drops → fail; force a query that surfaces the superseded decision → hard-negative fail; clean fixture passes. → *Faber should ship "this bad skill MUST be rejected" fixtures. A gate that can't fail is worthless.*
6. **Pin determinism with a byte-stability test** so nobody can quietly add an embedding/LLM scorer without it being a superseding decision.

---

## 4. Agent-integration mechanics worth stealing

### 4a. Ship an MCP server (yes, Faber should)
`src/rac/mcp/server.py`. Tools-only, read-only, 5 tools (`get_artifact`, `search_artifacts`, `get_related`, `find_decisions`, `get_summary`). Design pins (ADR-029..034):
- **Tools-only surface:** tools are the one MCP primitive every client invokes *autonomously mid-task* (resources need user attachment, prompts need user invocation — neither hits the grounding moment). Keep it ~4-5 tools.
- **Tool descriptions are engineered product copy**, shipped character-for-character, pinned — they're the only interface the agent sees when deciding whether to call.
- **Stateless re-read per call** (no cache/watcher) → identical bytes + input → identical output (reproducibility).
- **Per-response character budget** (`budget.py`, default 10K chars), truncate at whole-item boundaries with `{truncated, omitted, hint}` markers — "responses land directly in the agent's context window, the scarcest resource."
- **Structured errors, never protocol exceptions** (agent recovers from a JSON body).
- **In-process consumption + isolation test** (`tests/test_mcp_isolation.py` asserts the server imports no write-capable service).

**Lesson for Faber:** Ship a `faber` MCP server exposing mined skills/insights/eval-status to the agent at the relevant moment — the highest-leverage delivery channel, cross-client, no per-edit hooks platforms don't support. Faber's eval sidecar (JSON-over-stdio, spine→sidecar) is a *different* boundary from an MCP server (server→agent); keep them separate, both deterministic.

### 4b. Managed-block CLAUDE.md injection
`src/rac/services/agent_rules.py`, `rac export --agent-rules`. Writes a digest-guarded block into `CLAUDE.md` / `AGENTS.md` / `.cursor/rules` / `.github/copilot-instructions.md` — **one identical block, all four clients**:
- `<!-- BEGIN RAC MANAGED BLOCK (digest: <sha256>) -->` … markers (HTML comments, invisible in render, machine-locatable). Digest rides in the BEGIN marker.
- **Distilled pointers, not bodies** — one line per live decision + "ask the MCP tools for full text" (attention budget).
- **Digest = freshness, not timestamp** → two generations of the same corpus are byte-identical → idempotent.
- **Preserve content outside the block** byte-for-byte; `--check` is a CI drift gate (exits non-zero on stale/missing).
- **Single source of truth for "active":** the `is_live_decision` predicate is shared by both the static block and the live `find_decisions` MCP tool, so they can't disagree.

**Lesson for Faber:** This is the right skill-install / context-supply mechanism — idempotent, reviewable in a PR, reversible, cross-agent. Faber should write digest-guarded managed blocks announcing installed/active skills (pointers, not bodies; MCP fetches ground truth). Two-layer cross-agent story: **MCP server for tool-capable clients + committed managed block for universal zero-setup coverage (incl. Copilot).**

### 4c. Bundled skills + git hooks (install mechanics)
Skills (`src/rac/skills/<name>/SKILL.md`) and hooks (`src/rac/hooks/*.sh`) ship as **package resources via `importlib.resources`** — install works from an installed wheel, offline, no repo. Install to canonical `.claude/skills/<name>/SKILL.md`, **never-overwrite, all-or-nothing, byte-identical**. SKILL.md shape: frontmatter trigger-copy + "Hard constraints" + numbered steps with exact commands + explicit human-review gate + "Out of scope". The `rac-import` skill = "one document → one valid artifact" with a *mandatory human-review step* before any write, closing on deterministic `rac validate`.

**Lesson for Faber:** Faber's mined skills should be emitted in that SKILL.md shape (= the Claude Code skill format, see §6). Borrow the install mechanics wholesale (canonical path, never-clobber, all-or-nothing, offline). Ship a meta-skill ("faber-install-skill") that walks the agent through reviewing a mined skill before install — mirroring `rac-import`'s propose→human-ratify→deterministic-check loop (which IS Faber's eval-gate-then-install model expressed as a skill).

### 4d. Integration philosophy (ADR-067 / ADR-065)
- **ADR-067:** "Agent Integration is Context-Supply and Post-Edit Enforcement, Not Pre-Edit Interception." They reject (1) the engine computing a *semantic verdict* (needs LLM, breaks determinism, "makes the engine a confident liar") and (2) pre-edit interception (no agent platform exposes a generic inspect-and-veto hook — except Claude Code `PreToolUse`, where they DO wire one). The engine asserts *which live decisions bind a change*; it never asserts a change *is wrong* — semantic entailment stays in the agent.
- **ADR-065:** "Artifact Content Is Untrusted Input; the Trust Boundary Is Human PR Review." Served content is a prompt-injection attack surface; read-only protects the *store*, not the *agent*. Content becomes authoritative only because a human reviewed and merged it. `lore doctor` *flags* injection-style content as a reviewable warning — never auto-sanitizes (would break byte-stable read-only) and never scores trust (would be a lexical score consumed as a verdict).

**Lesson for Faber:** (a) Faber's eval gate is a legit *pre-install* gate on a skill artifact (Faber owns it) — keep it. But once a skill is installed and the agent acts, Faber faces the same reality: no generic cross-platform pre-edit veto. So deliver via context-supply (MCP + managed block) + post-edit enforcement (hooks/eval-on-diff), with a true pre-edit veto only on Claude Code `PreToolUse` (Faber's first target); fall back to context-supply for Codex/OpenCode/Pi. Don't promise cross-platform interception. (b) **Faber ingests sessions → treat session content as untrusted.** A proposed skill is untrusted until a human reviews/merges it; the trust boundary is human PR review of the proposed skill, with the eval gate as an aid, not a substitute. (c) Keep semantic judgment out of the deterministic delivery surface — the MCP server returns the skill + eval status + friction evidence; the agent/sidecar reasons.

### 4e. Agent guidance as gated artifacts (ADR-047)
`rac/prompts/` — session-start, commit, PR, release-gate guidance are **Prompt artifacts** conforming to the Prompt schema, so `rac validate rac/` catches drift. "The guidance that governs how agents work on RAC is the one body of product knowledge the gates do not [otherwise] check." Root `CLAUDE.md` is a *router* that `@`-imports always-on prompts and lists situational ones.

**Lesson for Faber:** Hold Faber's own agent operating-guidance to the same bar as mined skills — schema'd, validated, drift-checked, surfaced via the router pattern. Your highest-leverage context shouldn't be your least-validated content.

---

## 5. Product strategy lessons

### 5a. Lore ↔ Faber composition (the strategic headline)
- **Faber's mined friction → missing decisions.** When Faber detects "the agent re-did something the team ruled out," that *is* a missing decision artifact — Faber could emit it into a Lore-style corpus.
- **A decisions corpus → a friction signal.** An agent violating a recorded decision is detectable friction. Faber could treat an ADR/Lore corpus as an *input signal* to friction detection, not just session transcripts.
- **Steal "recall fuzzily, then verify deterministically"** as the legible framing for Faber's own pipeline: GEPA/DSPy explore fuzzily; the deterministic adapter-eval is the "verify" step. (Lore applies the same loop to retrieval: recall in Supermemory/RAG, verify verbatim in Lore.)

### 5b. Ride the carrier, own the enforcement (OKF lesson)
ADR-048/049/052: Google's Open Knowledge Format commoditized the *carrier* (git tree of Markdown + YAML); MADR/dotprompt commoditized *per-type schemas*. Lore's response: "If RAC's pitch rests on the file format or the per-type schema, it is defending ground that is being levelled." So they redefined the product as the layer the standard leaves out — **deterministic, CI-enforced, cross-artifact graph validation**. "OKF is read-time interchange; RAC is write-time enforcement." `rac export --okf` emits conformant bundles; the OKF dependency is informative-only and re-pinnable (zero code/package/network dependency on it).

**Lesson for Faber:** The analogous standard is the **Anthropic Agent Skills / Claude skill format**. Emit skills in that format (the carrier) so any agent consumes them with zero Faber lock-in — *don't compete on format, it's table stakes being commoditized*. Faber's defensible layer is the **adapter-gated eval** (the write-time enforcement): "anyone can write a skill file; Faber guarantees the skill actually improves the agent on your stack, verified in CI." Conform-and-export, keep the engine independent of the spec version.

### 5c. Thin clients over a stable contract (validates + challenges Faber)
ADR-062/063/064/068/073: one deterministic engine; every other-language client is a **thin client over the published contract** (`--json`, export payload, exit codes, MCP) — "a second engine is a second source of truth... the exact drift the promise can't afford." Brand split (ADR-068): `lore-*` = anything a user installs; `rac-*` = engine/build-coupled. Connectors consolidate (ADR-073): the export contract is the product; most backends need zero RAC-side code. Spin out off-identity concerns (Wayfinder, routing — "a runtime inference concern, the opposite pole to a knowledge engine").

**Lesson for Faber:** Validates the cross-agent thin-client ambition — define Faber's stable contract explicitly (skill artifact + eval verdict JSON + exit codes), `schema_version` it, make every agent integration a thin consumer. **But it also challenges the two-runtime split:** Lore's entire determinism guarantee rests on *one engine, one language*; it refuses a native port precisely because two engines = drift. Faber's Elixir-spine + Python-sidecar is only safe if the sidecar is a **thin contract consumer that computes the verdict but the spine owns the source of truth** (which is the stated v1 design). The rule to enforce: domain logic must never live in *both* runtimes. Adapters are the satellite category — consolidate as declarative packs consuming a stable adapter-contract (the `lore-connectors` model), and pre-commit to spinning out any *runtime inference* concern rather than absorbing it ("compose GEPA/DSPy, don't rebuild" extended to "compose runtime concerns, don't absorb them").

### 5d. Record what you DON'T do (boundary ADRs)
ADR-017 ("Manages Knowledge, Not Work"), ADR-024 ("Not a Content Store"), ADR-034 ("facts vs judgment"), ADR-010 ("Documents Are Not Artifacts"). The litmus test for any feature: "does this improve knowledge correctness, or does it manage documents?" The discipline of recording rejections is the moat-protector.

**Lesson for Faber:** Declare Faber's boundary — *"Faber compiles skills, it doesn't run the agent."* Model a **session transcript as a container, a friction instance as the typed artifact extracted from it** (one session → 0..N friction artifacts → 0..N skill candidates) — same extraction-flexibility + traceability the document↔artifact split (ADR-010) gives Lore. Ship a skill *template-as-contract* (ADR-021) so every generated skill passes baseline structural validation *before* the expensive stochastic loop — a cheap deterministic pre-filter.

### 5e. The dogfooded ADR practice
83 ADRs in ~3 weeks, fine-grained (one records a boundary for a *removed* prototype; one exists solely to *reject* a brief and explain why). Each carries Status / Category / Context / Decision / Consequences / **Alternatives Considered with rejection reasons** / typed cross-links. Lifecycle is machine-enforced: status-consistency rule fails CI if a live artifact references a retired one. The ADRs *are* RAC artifacts validated by `rac validate rac/`. The disciplined corpus *is the demo*.

**Lesson for Faber:** Adopt it — Faber already has conventional commits + `.claude/plans/`; the gap is durable decision records with supersession. Highest-signal habit: *record the alternatives you rejected and why* (e.g. "deterministic eval over reflective-opt" deserves a written ADR with the rejected alternative, or it gets re-litigated). Machine-validate your own decision records — on-brand for a quality-gate engine. The records double as product signal: mined-friction + compiled-skill records are both internal memory and the evidence corpus proving the loop produces real improvements.

---

## 6. Engine/SDK architecture & engineering discipline

- **Clean layering** `core → services → output / explorer / mcp`; core imports nothing upward; explorer & mcp are isolated leaf consumers; the *one* deliberate upward import (gate reusing the SARIF builder) is to prevent message drift. Enforced by an isolation test. → *Faber: a test asserting the engine never imports adapter/output-specific modules — domain-free by construction, not convention. Route any fact emitted two ways through one function so they can't diverge.*
- **Declarative spec registry** (`core/artifacts.py` `ARTIFACT_SPECS`, frozen dataclass): one registry drives classification, validation, schema, templates, relationship legality for all 5 types; per-type validators share structural helpers (`_validate_required_sections` etc.). → *This IS Faber's adapter-contract problem solved in another domain. Faber's adapter (yaml+md+templates) should resolve to an analogous in-memory spec the engine consumes uniformly. Caveat Faber must additionally solve that rac sidesteps: loading/validating an UNtrusted on-disk spec (rac kept its registry code-defined/closed).*
- **Artifact model:** machine envelope (id/type/schema_version/relationships) kept distinct from prose body; **no stored timestamps — recency is git-derived** (ADR-045); single shared `MarkdownIt` parser instance (parsing is the dominant cost); parse never raises — returns a "degraded Product" with `parse_issues`. ID minting: `<REPO>-<12-char Crockford base32>` = 8-char ms-timestamp (ULID, time-sortable) + 4-char CSPRNG, **clock+entropy injectable for deterministic tests**, identity conflicts reported never auto-resolved. → *Faber: skills carry a machine envelope distinct from instructions; injectable clock+entropy for reproducible IDs in eval; git-derived metadata keeps artifacts diff-stable; report skill collisions as findings, don't silently pick.*
- **Public SDK = `rac.__all__`** (ADR-062): flat re-exports, single `RACError` root (one `except` catches the family), every result has `to_dict()` with `schema_version:"1"`, **append-only / absent-when-N/A** field evolution, golden byte-for-byte tests. MCP responses bounded by char budget. → *Faber sidecar boundary: adopt `schema_version` + append-only + single structured-error root + byte-stable golden/parity tests (Faber already runs native↔Python `:sidecar` parity tests — pin them).*
- **Determinism enforced as runnable controls:** `tests/test_no_egress.py` monkeypatches `socket` to raise and runs the whole pipeline — the no-network claim is CI, not a promise. `content_hash` = SHA-256 of source bytes, **never mtime** → identical inputs never reprocess. Digest-not-timestamp idempotency throughout. → *Faber: a no-egress test proving the deterministic matchers make no network/LLM call; hash session inputs so identical inputs never re-run (reproducible loop).*
- **Validation/gate commands:** typed result object → `to_dict()` IS the contract → CLI only renders, maps `.ok` to exit code. `validate` (per-file schema) / `relationships --validate` (graph integrity, Tarjan cycle detection) / `review` (prioritized health) / `gate` (all three, policy-classified, one exit code + one SARIF, single corpus walk). Exit codes: 0 pass / 1 gate-fail / 2 usage. Shared severity map feeds both SARIF and gate. → *Faber: 3-tier exit codes let the Elixir spine distinguish "skill failed eval" (1) from "sidecar broke" (2) — don't treat a crash as a rejection. Define each matcher's severity once, consume everywhere.*
- **GitHub Actions:** three composite actions (`watchkeeper` PR-diff review, `validate --sarif`, `pr-gate --sarif`), each a *thin wrapper* over the same CLI a dev runs, re-surfacing the exit code verbatim, uploading SARIF for inline PR annotations. **ADR-075:** the pre-merge tier is a *required, non-bypassable* branch-protection gate — "running a check and enforcing it are distinct decisions" (born from a PR that merged red). Dogfood jobs run the actions in source mode so they can't rot. → *Faber: ship `faber eval --sarif` wrapped in a reusable Action that fails the PR when a proposed skill fails the gate; document which checks are required, not just which run; dogfood on Faber's own PRs.*
- **Test topology (ADR-027):** per-service batteries (matrix of Python version × battery); a guard test parses the CI yaml and asserts every `test_*.py` maps to exactly one battery (caught 8 silently-unrun files); 30+ golden byte-for-byte CLI-output tests (`RAC_UPDATE_GOLDEN=1` to refresh); a dogfood test validates rac's own corpus with rac. → *Faber: per-stage batteries (Ingest/Detect/Adapter/Eval/Loop) so a red run names the failing stage; golden byte-stable tests for sidecar JSON; battery-coverage guard for tagged subsets (Faber already tags `:sidecar`).*
- **Release engineering:** CalVer `YYYY.MM.N` (ADR-076) **decoupled from the contract version** — CalVer says *when*, `schema_version` says *what's compatible*; setuptools-scm derives version from git tag (no manual edits); fail-closed `verify-release` (rejects non-canonical version or missing CHANGELOG heading); deterministic CycloneDX SBOM with a drift-guard test (covers every declared dep, timestamp-free); PyPI trusted publishing (OIDC, no stored token); machine-checked Keep-a-Changelog. → *Faber: decouple the sidecar JSON `schema_version` from the Elixir app release version (own clocks); fail-closed release verification; deterministic SBOM if shipping a binary; OIDC publishing.*

---

## 7. Tools rac-core uses (candidates for Faber's Python sidecar)

| Tool | Use in rac-core | Relevance to Faber |
|---|---|---|
| **`mcp` (FastMCP, `mcp>=1.0`)** | The `lore` MCP server | Direct: if Faber ships an MCP server, this is the Python SDK (or build it on the Elixir side) |
| **`markdown-it-py`** | Single shared parser; structural extraction only | Faber parses skills/transcripts — a shared instance is the cost lesson |
| **`markitdown`** (ADR-072) | Optional ingestion: DOCX/PDF/PPTX/XLSX → Markdown, split by extra | If Faber ever ingests non-transcript docs as friction sources |
| **`pyyaml`** (alias ban!) | Frontmatter | Faber's declarative adapter loader — **ban YAML aliases** (billion-laughs) on untrusted input |
| **`textual`** | Optional `rac explorer` TUI | Faber has a LiveView dashboard; TUI is a lighter alternative surface |
| **SARIF output** | Gate findings → Code Scanning inline annotations | Faber eval findings as SARIF for PR annotation |
| **CycloneDX SBOM** + drift test | Supply-chain attestation, deterministic | On-brand for a determinism-first tool |
| **setuptools-scm** | Tag-derived version | Faber's sidecar package |
| **ruff + mypy (strict) + src/ layout** | Quality gates; golden tests pin output so lint can't change strings | Table stakes for `python/faber_eval` |
| **importlib.resources** | Bundle templates/skills/hooks in the wheel | Faber adapters/templates load installed, not from repo |
| **PyPI trusted publishing (OIDC)** | No stored token | Any Faber package publish |

---

## 8. Top 10 actionable takeaways for Faber (ranked)

1. **Build the grounding-eval blueprint into Faber's eval gate** (§3): score the real surface, P@k/R@k + hard-negative "must-not-break" fixtures, gated-metrics/metadata split, floor + baseline−tolerance with human-only rebaseline, regression-injection tests proving the gate fails.
2. **Ship a `faber` MCP server** (§4a) to deliver mined skills/insights — tools-only, read-only, stateless, engineered descriptions, char budget, structured errors, isolation test.
3. **Adopt the managed-block CLAUDE.md injection** (§4b) as the skill-install/context-supply mechanism — digest-guarded, idempotent, distilled pointers, `--check` drift gate, one block across CLAUDE.md/AGENTS.md/.cursor/.github.
4. **Elevate deterministic eval to a loud trust/CI pillar** (§2) with the honest tension (gate deterministic, generation stochastic).
5. **Ride the Agent Skills format, own the adapter-gated eval** (§5b) — "anyone can write a skill; Faber proves it works on your stack."
6. **Treat session content as untrusted; trust boundary = human PR review of the proposed skill** (§4d / ADR-065).
7. **Make adapters a declarative spec registry the domain-free engine consumes uniformly** (§6), and solve untrusted-spec loading (the part rac sidestepped).
8. **Define one stable contract + thin clients** (§5c); enforce "domain logic never lives in both runtimes."
9. **Adopt the test/release discipline** (§6): per-stage batteries + battery-coverage guard, golden byte-stable tests, no-egress test, `schema_version` decoupled from release version, fail-closed release verify.
10. **Adopt the dogfooded, supersession-aware ADR practice** (§5e) — record rejected alternatives, machine-validate your own decisions.

---

## 9. Open question to revisit
Should Faber emit a **Lore-compatible decision artifact** when it detects "agent re-did something ruled out"? That would make Faber a *producer* for Lore's ecosystem and concretize the composition in §5a — worth a spike once the MCP server / managed-block work lands.

---

## 10. Implementation log — what landed (2026-06-24 session)

The "harden determinism" batch from takeaway #1/#9 shipped, plus a polish fix surfaced
alongside. All verified (`mix format` + `compile --warnings-as-errors` + `mix test` +
`mix test.full`) and committed.

| Lesson (§) | What shipped | Commit |
|---|---|---|
| #8/#9 — one stable contract, `schema_version` decoupled from release; domain logic must not silently diverge across the two runtimes | **Exact per-assertion native↔Python sidecar parity** (was loose composite ±0.05; now asserts schema_version, composite, weight_total, and every dimension's score/passed/failed/total + each assertion's id/check_type/passed) + `schema_version "1.0"` carried by both engines, parity test asserts equality | `da34a0a` |
| #1 — regression-injection tests proving the gate actually fails on bad input | **Regression-injection gate test**: well-formed skill passes; structurally broken skill rejected; dangerous-command skill trips `safety/no_dangerous_patterns` and fails; good strictly beats bad (guards a stuck always-fail gate) | `c988223` |
| #9 — no-egress test | **No-egress guard via BEAM tracing**: traces `:gen_tcp`/`:ssl`/`:socket` `.connect` across all processes over the full native pipeline (scan → propose(stub) → eval(native) → install), asserts zero connects; positive control proves the tracer was live; separate tracer process + `Code.ensure_loaded!` handle the two silent-false-pass pitfalls | `189f60c` |
| (polish, surfaced by Codex ingest) | **cwd project label**: sessions now labelled by working-dir basename, not the opaque transcript slug (Claude) / date dir (Codex). `Event.cwd` (general) → `Scan.Result.cwd` → CLI label | `ba372d8` |

Cross-project pattern extracted: `.claude/scriptorium/2026-06-24-beam-no-egress-tracing-test.md`
(the BEAM no-egress tracing test + its two pitfalls + positive-control technique).

### Deferred (need a product decision or are blocked — NOT done this session)
- **#2 faber MCP server** — milestone-level new surface; defer to an explicit design pass.
- **#3 managed-block install** — faber currently writes *dedicated* `<dir>/<name>/SKILL.md`
  files (faber-owned, not shared), so a managed block isn't needed yet. It becomes relevant
  only if faber starts writing into *shared* configs (CLAUDE.md/AGENTS.md/.cursor). Defer
  until cross-agent install into shared files is on the table.
- **Live propose on a Codex session** — blocked: no `ANTHROPIC_API_KEY`/`OPENAI_API_KEY` in
  this env. Stub-LLM path is fully covered; live call is a manual step.
- **dspy.GEPA + Pareto loop selection** — out of v1 scope per the keyless-evolution decision.
