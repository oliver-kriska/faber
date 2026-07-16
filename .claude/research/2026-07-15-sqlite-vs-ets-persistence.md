# Handoff: should Faber's persistence move to SQLite?

**Date:** 2026-07-15
**Status:** ~~research delegated to a follow-up session~~ → **research completed same day; see Part II below** (deep-research workflow: 5 angles, 21 sources, 101 claims extracted, 25 adversarially verified → 23 confirmed / 2 refuted; plus local empirical probes). Part I is the original handoff, unchanged — its §-references are used throughout Part II.
**Question as asked:** *"can we maybe use sqlite in ~/ in some global folder where we can store data
and that would be better than some complex cache"* — with the follow-up that users work across
**multiple days** and there is a **web UI**, so persistence matters more than a one-shot framing
suggests.

---

## TL;DR verdict (mine, not binding — go verify it)

**No for the scan cache. Probably no for the proposal store. The install markers cannot move at
all.** The multi-day + web-UI argument is real, but it points at a *missing feature* (triage state),
not at a wrong storage engine.

Confidence: **high** on the cache and the install markers, **medium** on the proposal store,
**low** on the cross-process question (§6) — that one is genuinely open and is the best reason to
revisit.

The single most important framing: **the complexity is invalidation, not storage.** Every hard part
of the cache survives an engine swap completely unchanged. See §3.

---

## 1. What exists today (three mechanisms — and why three is not automatically a smell)

| What | Where | Category | Why it's shaped this way |
|---|---|---|---|
| Scan cache | ETS + `~/.faber/cache/scan.cache` snapshot | **Cache** — recomputable | µs lookups on a hot path hit ~6.6k times per scan |
| Proposals | one JSON per proposal, `~/.faber/proposals/` | **Store** — paid-for | Cost real LLM tokens; write-through, never invalidated |
| Installed skills | `.faber.json` beside each `SKILL.md` in `~/.claude/skills/<name>/` | **Store** — provenance | Must live next to the artifact it describes (§5) |

The **Cache vs Store** distinction is load-bearing and predates this question:

- **Cache** = recomputable. A debounce is fine, invalidate freely, losing it costs time only.
- **Store** = paid for with tokens or user intent. Immediate write, never invalidated.

Three mechanisms *looks* like something to unify behind one database. §5 is why that unification
buys much less than it appears to.

---

## 2. Hard constraints — verified, don't re-derive

**Faber has zero SQLite library dependencies today, deliberately.**
`lib/faber/ingest/source/ccrider.ex:137` shells out to the `sqlite3` CLI and the comment says why:
*"no hex/NIF dependency"*. `mix test.full` documents `sqlite3` as required external tooling.

**Faber ships as a Burrito single binary, cross-compiled with Zig** (`mix.exs:44,52,157).

**Oliver's own KB already graded this exact tradeoff** — `scriptorium/wiki/burrito-single-binary-distribution.md`
(`verdict: use`, `confidence: high`, updated **2026-07-14**):

> **Easy** when prod deps are pure Elixir/Erlang (no NIFs) and assets are prebuilt into
> `priv/static`. Burrito *can* cross-compile NIFs via Zig, **but that's where the pain is.**

That same article records a Zig-vs-macOS-SDK failure **already hit on 2026-06-19**: Burrito 1.5.0
pins Zig 0.15.2, which has no libSystem stubs for a bleeding-edge macOS SDK, so the build dies at
the wrapper **link** step and `SDKROOT` does not help. Builds must happen on GitHub `macos-14`.
**Faber's binary already can't be built on this host.** Adding a NIF makes that strictly worse, in
the exact area the KB flags as "where the pain is".

**SQLite is single-writer** — `scriptorium/solutions/postgres-to-sqlite-migration-compat.md`
(`confidence: high`):

> SQLite allows only a single writer. Async ExUnit tests that all share one SQLite file produce
> "Database busy" errors. **Fix:** run tests sequentially (`ExUnit.start(max_cases: 1)`).

Note the irony and take it seriously: **the main argument *for* SQLite here is cross-process
concurrent writes (§6), and single-writer is precisely SQLite's weakest axis.** It needs WAL +
`busy_timeout` to be tolerable. And if a shared DB reached the test suite, Faber's 498 tests (many
`async: true`) could be forced to `max_cases: 1` — Oliver measured that as a real slowdown on a
281-test suite.

---

## 3. Why the cache is a "no" (the core argument)

What actually makes `Faber.Scan.Cache` non-trivial:

1. **Source stamp** — `{mtime, size}` per session, deciding whether the *source* changed.
   (`Source.stamp/2`, optional callback; Files = `{mtime,size}`; ccrider = `{db, db-wal, id}` —
   the `-wal` part matters because a committed write can land in the WAL leaving the main file's
   mtime untouched.)
2. **Scorer version** — `module_info(:md5)` over `Application.spec(:faber, :modules)`, deciding
   whether *our code* changed. (NOT `:code.all_loaded/0` — lazy loading makes that order-dependent.)
3. **Transparency contract** — `warm == cold == uncached`, exactly. Proven and mutation-tested.

**All three survive a move to SQLite completely unchanged.** SQLite would replace `:ets.lookup` and
one `term_to_binary` snapshot write. You keep 100% of the hard part, add a NIF, and slow a hot path
that runs ~6.6k times per scan. You'd want ETS in front of SQLite anyway — and then you have both.

The transparency contract is also *why a TTL memo is forbidden* anywhere inside `Scan.run`: the CLI
would silently serve stale results. Single-flight (`Faber.Scan.Coalesce`) is allowed precisely
because a joiner receives the result of a scan that **overlapped its own call**, so it's an answer a
scan running right now legitimately produces. Any future staleness-tolerating layer must live
*above* `Scan.run`, never inside it. **Don't let a storage rewrite quietly break this.**

---

## 4. Measured numbers (established; do not re-measure)

| Metric | Value |
|---|---|
| Corpus | 6,614 transcripts / 4.0 GB |
| Full cold scan | 9.12s → 1,591 results (2.6 MB) |
| Real corpus, cold → warm | **5.48s → 0.45s (12.1×)** |
| Frozen read-only corpus | 0.93s → 0.02s (54×), `warm == cold == uncached` exactly |
| Warm dashboard mount | 424ms total — `discover/1` 253ms of it (**60%**) |
| `stat` × 6614 | 188ms |
| Daily cache miss rate | 1.57% |

Read that last row with §3: **98.4% of sessions are unchanged day-to-day**, which is exactly what
makes stamp-keyed memoization the right shape for multi-day use.

`discover/1` being 60% of a warm mount is the *next* real optimization target — and note SQLite
does nothing for it, because it's a filesystem tree walk, not a lookup.

---

## 5. The install markers cannot centralize (decisive, high confidence)

`lib/faber/install.ex:102` writes `.faber.json` **beside** the `SKILL.md`, at
`~/.claude/skills/<name>/.faber.json`.

That placement is load-bearing, not incidental. `~/.claude` is a **shared directory the user edits
by hand**. If someone `rm -rf`s a skill directory, the marker goes with it and reality stays
consistent. A central `~/.faber/faber.db` would keep insisting the skill is installed after it was
deleted — the DB would drift from the filesystem with no way to notice.

This is the existing project rule *"treat the user's dirs as shared… never enumerate-and-claim"*
(`.claude/solutions/2026-06-25-sync-pointer-over-claim-provenance.md`), applied to storage.

**Consequence for the unification argument:** SQLite could absorb at most 2 of the 3 mechanisms, and
one of those two is the cache, which shouldn't move (§3). So "unify three things into one database"
collapses to "move the proposal store into SQLite" — a much smaller prize than it first appears.

---

## 6. The genuinely open question: cross-process writes

**This is the strongest pro-SQLite argument and the part I'm least confident about.**

Today `faber serve` (long-lived, dashboard open all day) and a one-shot `faber scan` each hold their
own ETS table and each rewrite the **whole** snapshot. Last writer wins.

Why it is *currently* tolerable:
- The write is an atomic rename → **no corruption**, only lost entries.
- Every process loads the snapshot at boot, so its view is usually a superset of what it found.
- Lost entries are **recomputable** — cost is one slow rescan. Self-healing.

The bad case: `serve` holds a stale in-memory view for hours, a CLI run adds 500 entries, then
`serve` flushes at shutdown and overwrites with its own view. Those 500 are gone. Cost: one slow
scan. **Annoying, not broken.**

**Open questions for you:**

1. Does last-writer-wins actually bite in practice, or is mixing `serve` + CLI heavily rare?
   Instrument before engineering.
2. **Could `sqlite3`-CLI-as-file-format fix it with no new dep?** We already shell out to `sqlite3`.
   A subprocess *per lookup* is obviously fatal (6.6k lookups), but: batch-load at boot (one query →
   all rows → ETS) + batch-upsert at flush (one transaction) is *the current snapshot design with
   incremental writes*, which is exactly what kills last-writer-wins. Cost: SQL escaping, blob
   handling, a subprocess. **This is the option I'd research first** — it gets the one real benefit
   without touching the NIF/Burrito constraint in §2.
   - Prior art to check: `SQLite Bulk Insert Elixir Exqlite` in the KB (~52,980 rows: ~25s → 0.x s).
     Different boundary (NIF, not CLI) but the batching lesson transfers.
3. Would per-key cache files (instead of one snapshot) fix last-writer-wins more cheaply than any
   database? 1,591 small files vs one 2.6 MB blob — worse for load, but writes stop colliding.
4. If exqlite were on the table anyway: does it *actually* cross-compile through Burrito+Zig for all
   four targets? The KB says NIFs are "where the pain is" but doesn't say it's impossible. **Needs
   evidence, not vibes** — and note the host can't build the binary at all right now (§2).

---

## 7. The real multi-day gap — and it isn't storage

Oliver's follow-up ("users will not check all sessions in one session… multiple days… web UI") is
correct and points somewhere better than the engine.

**Grepped: there is no dismissal, triage, or "seen" state anywhere in `lib/`.** If someone works
through 1,591 ranked sessions over a week, nothing remembers where they left off or what they
already rejected. Every mount shows the same top 25, **including the ones they dismissed on Monday.**

That is the multi-day hole. Not the bytes — the missing concept.

It is **paid-for user intent**, so it belongs in the **Store** category (durable, write-through,
never invalidated) — same shape as `Faber.Proposal.Store`, not the cache. It does not need SQLite
until the *query* patterns demand it ("show me everything unreviewed in project X, ranked").

**If you build this, that's the moment to re-ask the SQLite question** — a triage store plus the
proposal store plus real filtering is the first workload with an honest query shape. Deciding on the
engine *before* the feature exists is backwards.

---

## 8. Related decisions and where the real cost sits

- **Realistic proposal count:** each proposal costs an LLM call. Dozens-to-low-hundreds over months,
  not thousands. A glob + 100 JSON reads is ~10ms. Quantify before optimizing.
- **Known accepted gaps** (documented, not oversights): no `fsync` (crash-durable, not
  power-loss-durable); `@max_age_s` prunes only at load, so it doesn't bound a long-uptime `serve`;
  `scorer_modules/0` uses a raw string prefix (`Faber.ScanX` would false-positive);
  `Source.stamp/2`'s bare rescue swallows a broken impl with no trace.

---

## 9. What got fixed today (context — the bug this question found)

Oliver's instinct that "persistence is missing" was **right**, but the cause was not the engine.

`Faber.Scan.Cache` only persisted two ways: a 5s debounce, or `terminate/2` via `trap_exit`. But
`Faber.CLI` ends every one-shot command with `System.halt/1` — an **immediate VM halt**: no
supervisor shutdown, so `terminate/2` never runs. **Verified empirically**, not assumed: a trapping
GenServer under a supervisor + `System.halt(0)` → `terminate/2` does not run.

So **`faber scan` scored all 6,614 sessions and persisted none of it.** Every run cold, forever. The
cache only ever worked for `faber serve`. `Cache.flush/0` existed; nothing in `lib/` called it.

Fixed in **`ab86d3b`** (`Faber.CLI.persist/0` on the halt path, best-effort; `handle_call(:flush,…)`
now no-ops when not dirty so `faber help` doesn't rewrite 2.6 MB).

**This is the honest answer to "would SQLite have been better?": a write-through store would have
made this bug impossible.** That's a genuine point in SQLite's favor and should be weighed — but the
fix was ~20 lines and the design is now correct, so it argues for *care about flush points*, not for
a new engine.

---

## 10. How to attack this (suggested)

1. Read §3 and §5 first. If you disagree with either, everything downstream changes — say so loudly.
2. Do **not** re-measure §4.
3. Start with §6 Q2 (`sqlite3`-CLI-as-format). It's the only option that gets the real benefit
   without paying the NIF/Burrito cost the KB already graded.
4. Before recommending exqlite, produce **evidence** it cross-compiles through Burrito+Zig to all
   four targets. The KB's `verdict: use` on Burrito is explicitly conditional on "no NIFs".
5. Treat §7 as a product question for Oliver, not a storage one.

**Standing rules that apply:** never push to a remote; don't modify the plugin repo
(`elixir-live-claude-engineer`); `mix verify` before every commit; reproduce a flagged problem
before "fixing" it (a plausible finding can be empirically false — this repo has burned that lesson
twice).

---
---

# Part II — Deep research findings (2026-07-15, follow-up session)

**Method:** deep-research workflow (103 agents: scope → 5 parallel search angles → fetch 21
sources → extract 101 claims → 3-vote adversarial verification of top 25 → synthesis), plus local
empirical probes on this host, plus KB prior art. Every claim below survived 2/3+ verification
votes against primary sources unless marked otherwise.

## TL;DR — the handoff verdict survives, materially refined

**The "qualified no" stands: cache stays ETS+snapshot, install markers stay put.** Nothing found
overturns §3 or §5. But the open questions resolved decisively in one direction:

1. **For a future cross-process triage/dismiss + proposal store, SQLite beats every surveyed
   pure-BEAM alternative** — CubDB and Khepri both fail the cross-process requirement *outright*,
   by their own documentation. WAL mode explicitly supports Faber's exact shape (long-lived server
   + one-shot CLI, same host) with a settled settings recipe that OpenCode ships verbatim for
   session/proposal-shaped data.
2. **The lowest-risk path is §6 Q2 — sqlite3-CLI-as-boundary — and it is now empirically
   validated on this host:** batch flush of 1,600 × ~1.6 KB blobs in one transaction through a
   bare `sqlite3` subprocess = **31 ms**; full batch load back = **16 ms**. The subprocess boundary
   costs nothing at batch granularity. Zero NIF risk, pattern already exercised for ccrider ingest.
3. **The exqlite/Burrito question stays empirically open in both directions**: the feared blocker
   has two viable escape paths on paper, but no public success *or* failure exists for the modern
   pipeline. Only a spike build settles it — and it is *not needed* for the two-step path below.

**Decision remains deferred until the triage feature exists (§7 stands).** When it does: start
with the CLI boundary; upgrade to exqlite-with-prebuilt-NIFs only if in-process access becomes
necessary, and only after a spike build.

## Q1 — exqlite under Burrito+Zig: untested in public, two escape paths (verified)

- **Burrito 1.5.0 officially recompiles elixir_make NIFs during cross-compilation** (README:
  build artifacts include "compilation artifacts for any elixir-make based NIFs"; `nif_cflags` /
  `nif_env` qualifiers exist for it). `skip_nifs` (default false) is the documented escape hatch:
  "use this if you want to copy in NIFs that you recompiled yourself." exqlite builds via
  elixir_make, so it falls inside this mechanism. [3-0; burrito.hexdocs.pm/readme.html]
- **The only concrete exqlite-under-Burrito record is a 2021 failure**: burrito-elixir/burrito#6
  — exqlite 0.7.9 under Burrito 0.5.0, macOS → x86_64-windows-gnu; the recompile step invoked
  exqlite's Makefile which tried `mkdir -p /priv` and aborted the whole release. Closed 16 months
  later in an issue-tab cleanup with a hedged "things may be fixed for you!" — no linked fix, no
  reproduction. The recompile machinery was rewritten by Burrito 1.4.0
  (`Burrito.Steps.Patch.RecompileNIFs`), so this is evidence of a *fragility class*, not of current
  behavior. **No confirmed success or failure exists for any modern Burrito.** [3-0]
- **exqlite ships official precompiled NIF tarballs covering all four Faber targets**
  (`exqlite-nif-{2.16,2.17}-{aarch64,x86_64}-{apple-darwin,linux-gnu}-*.tar.gz`, confirmed in
  v0.36.0–v0.38.0 releases; prebuilt fetch is exqlite's *default* install path). So the sqlite3
  NIF never needs Zig at all: `skip_nifs` + forcing cc_precompiler's target per release. **Feasible
  on paper, zero public prior art** — the wiring is inferred, not demonstrated. [2-1 — the split
  vote is exactly the missing-prior-art caveat]
- Refuted (1-2): "Burrito has no prebuilt-NIF substitution path for exqlite." The `skip_nifs`
  route exists; don't carry the pessimistic version forward.
- KB cross-check: `burrito-single-binary-distribution.md`'s "NIFs are where the pain is" is about
  the *recompile* path. The prebuilt route sidesteps recompilation — but the Zig-vs-macOS-SDK
  wrapper-link failure (§2) is NIF-independent and still forces CI builds regardless.

## Q2 — sqlite3-CLI-as-boundary: established pattern + validated locally (verified + probed)

Web-verified:

- **Established prior art**: sqlite-utils (Simon Willison, actively maintained, v4.1 July 2026)
  drives exactly this boundary — stdin JSON/NDJSON ingest with upsert-by-primary-key over a CLI
  process. [3-0]
- **`.import --csv` is a well-specified bulk text channel**: RFC 4180-compliant (quote removal,
  embedded newlines in quoted fields), reproduced empirically on 3.51.0 by the verifiers. Caveats:
  values land as TEXT, empty field → `''` not NULL, **no blob channel**. [3-0]
- **`.parameter set` is NOT an escaping mechanism** — the bound value is itself parsed as a SQL
  literal/expression (a phone-number string evaluates as arithmetic). Escaping = generate
  literal-quoted SQL (`''` doubling) or CSV. Never `.parameter`. [3-0]
- **Batch error handling — resolved empirically 2026-07-16** (the web claim was refuted 0-3, so
  this was probed directly on sqlite3 3.51.0). Without `-bail` the shell *does* continue after a
  SQL error — and crucially, inside `BEGIN…COMMIT` the trailing `COMMIT` still executes,
  committing the successful statements (partial write). The exit code is 1 either way, so failure
  is always *detectable*, but only `-bail` makes it *atomic*: the shell stops at the first error
  and exits before `COMMIT`, and the open transaction rolls back automatically on connection
  close. Verified for both parse errors (missing table) and runtime errors (UNIQUE violation).
  **Write-boundary recipe: `sqlite3 -bail` + `BEGIN IMMEDIATE…COMMIT` + nonzero exit ⇒ nothing
  was written.**

Local probes (this host, sqlite3 **3.51.0** 2025-06-12):

| Probe | Result |
|---|---|
| WAL, upsert (`ON CONFLICT`), `busy_timeout` via CLI | all work |
| Blob round-trip via hex literals (`x'DEADBEEF'`, `hex(v)` out) | works — sidesteps the no-blob-channel `.import` limit entirely |
| Batch flush: 1,600 upserts × ~1.6 KB blobs, one `BEGIN IMMEDIATE` txn, 5.2 MB SQL text via subprocess | **31 ms** |
| Batch load: all 1,603 rows, hex mode | **16 ms** |

That is Faber's real scale (≈ the 2.6 MB / 1,591-entry snapshot; hex doubles bytes — fine). The
design in §6 Q2 (batch-load at boot → ETS, batch-upsert at flush) is *empirically* cheap.

KB prior art confirms the batching lesson transfers:
`scriptorium/solutions/sqlite-bulk-insert-elixir-exqlite.md` — 52,980 rows: ~25 s → 0.34 s from
single transaction + prepared-statement reuse + PRAGMAs. Per-row autocommit is the killer; one
transaction per flush is the whole game.

## Q3 — multi-process WAL: exactly Faber's shape, with a settled recipe (verified)

- **WAL explicitly supports same-host multi-process concurrency** — readers and writers proceed
  concurrently; the only hard restriction is *no network filesystems* (mmapped shm wal-index).
  WAL mode is a persistent property of the DB file — server and CLI need no coordination. [3-0 ×4;
  sqlite.org/wal.html]
- **Writes still serialize through one global write lock**; a concurrent writer gets SQLITE_BUSY
  immediately unless `busy_timeout` is set (verifiers reproduced across two OS processes). [3-0]
- **`busy_timeout` is not a complete fix**: a DEFERRED transaction that reads then upgrades to a
  write fails *instantly* with SQLITE_BUSY_SNAPSHOT if another connection wrote in between — the
  busy handler is deliberately bypassed (waiting can never succeed on a stale snapshot).
  **Mitigation: `BEGIN IMMEDIATE` for any transaction that will write.** Directly load-bearing for
  any read-then-write flow in serve or CLI. [3-0; sqlite.org/lang_transaction.html]
- **The standard recipe** (converges across sqlite.org, practitioner sources, Rails 8 defaults —
  and OpenCode ships it verbatim in `packages/core/src/database/database.ts:27-32`):

  ```
  PRAGMA journal_mode=WAL;
  PRAGMA busy_timeout=5000;        -- or higher
  PRAGMA synchronous=NORMAL;
  PRAGMA foreign_keys=ON;
  -- small (ideally single-statement) write transactions; BEGIN IMMEDIATE for write-after-read
  ```
- **Version gate that matters here:** the two-process WAL-reset corruption bug
  (howtocorrupt.html; write/checkpoint race, affects 3.7.0–3.51.2) was fixed in **SQLite 3.52.0
  (2026-03-03)**. **This host's CLI is 3.51.0 — inside the affected range.** If Faber leans on the
  system `sqlite3` for a multi-process store, it must detect/require ≥ 3.52.0 (macOS system builds
  lag). For the *single-writer-at-a-time* usage Faber would actually have (CLI flush vs serve
  flush), exposure is narrow, but the check is cheap — `sqlite3 --version` at boot.
- Operational caveat: long-held read transactions in serve starve checkpoints → unbounded WAL
  growth. Keep reads short. [3-0]

## Q4 — pure-BEAM alternatives: both candidates disqualify themselves (verified)

- **CubDB** solves cross-compilation but not cross-process: pure Elixir, zero native code, immune
  to the Burrito problem — but its stated use case is single-instance apps/Nerves, and the module
  docs *explicitly* warn: "avoid starting multiple CubDB processes on the same data directory,"
  with no file-locking enforcement. A shared store would force serve to own it exclusively with
  the CLI going through RPC — no direct-file fallback when serve is down. Last release v2.0.2,
  Jan 2023. [3-0; hexdocs.pm/cubdb/faq.html] (Its NIF-risk framing comes from a competing
  maintainer; the underlying facts verified independently against erlang.org.)
- **Khepri** is Raft-cluster machinery mismatched to a single machine: entire dataset in memory as
  record trees, fsync-per-batch Ra log + snapshots, quorum semantics, store owned by one BEAM node
  — a one-shot CLI in a separate OS process can't reach it without distributed Erlang. Built as
  RabbitMQ's clustered-metadata Mnesia replacement. Disqualified. [3-0 ×4; github.com/rabbitmq/khepri]
- **Coverage gap (nothing survived verification):** DETS 2 GB limit / repair times (only a 2009
  erlang-questions post: mnesia "has no way of dealing with dets refusing to insert more records"),
  mnesia for this shape, term_to_binary snapshots, flock'd-snapshot patterns. The current
  JSON-files proposal store already *is* the lightweight member of this family and needs no
  further defense at current scale (§8).

## Q5 — peer tools (verified where it matters)

- **OpenCode** (sst/opencode, TS/Bun) persists sessions, messages, parts, projects, todos in a
  single SQLite file (`data/opencode.db`, Drizzle, migrated v1.2.0) — **with large unstructured
  blobs (diffs, summaries) kept as JSON files alongside**. Verified in the primary repo, and
  independently corroborated by Faber's own OpenCode ingest reader. That schema split —
  *relational rows in SQLite, big blobs on the filesystem* — is the directly applicable pattern
  for a triage store (rows) + proposals (files). [3-0]
- **No evidence surfaced of any BEAM-shipped CLI bundling SQLite** — in either direction. The
  closest thread (ElixirForum t/61908, Burrito+sqlite3+Nx for Windows) documents pain, not a
  shipped success. atuin/zoxide/gh-CLI went unanswered (coverage gap; low stakes).

## Refined verdict (supersedes nothing — sharpens §12 of Part I / TL;DR)

| Mechanism | Verdict | Changed by research? |
|---|---|---|
| Scan cache | **ETS + snapshot, stays** | No — §3 untouched; SQLite does nothing for `discover/1` either |
| Install markers | **Stay beside artifacts** | No — §5 decisive |
| Proposal store | **JSON files, stays** for now | No — scale argument (§8) holds; OpenCode splits blobs out of SQLite too |
| Future triage/dismiss store (+ proposals if queries demand) | **SQLite, two-step path** | **Yes — this resolved.** Pure-BEAM candidates self-disqualify; WAL recipe is settled; CLI boundary is empirically ~free at Faber scale |

Two-step path when the triage feature happens:
1. **`sqlite3`-CLI-as-boundary** (§6 Q2): batch-load at boot, batch-upsert per flush, `BEGIN
   IMMEDIATE`, hex literals for any binary, literal-quoted SQL for strings, recipe PRAGMAs, version
   check ≥ 3.52.0. Zero new deps, zero NIF risk. This *also* fixes last-writer-wins for the scan
   cache snapshot if §6 Q1 instrumentation ever shows it biting — without moving the cache.
2. **exqlite with prebuilt NIFs** (`skip_nifs` + cc_precompiler target-forcing) only if in-process
   access becomes necessary — after a half-day spike build proves it through Burrito 1.5.0 on all
   four targets. Not before.

## Open questions carried forward

1. **exqlite spike build** under Burrito 1.5.0 for all four targets (no public record either way).
   Only needed if/when step 2 is wanted.
2. ~~sqlite3 CLI batch error-handling default~~ — **resolved 2026-07-16**, see Q2 above: exit
   code reports failure with or without `-bail`, but only `-bail` prevents a mid-error `COMMIT`
   from landing a partial batch. Use `-bail` on every write invocation.
3. **Blob channel**: hex literals proven locally at Faber scale; base64/`readfile()` alternatives
   uncharacterized — probably moot given (2.6 MB × 2) = 31 ms.
4. **DETS/flock middle ground** — unanswered by the research; only worth revisiting if SQLite is
   rejected for some new reason.
5. **§6 Q1 (instrument last-writer-wins frequency) and §7 (triage feature — product question for
   Oliver)** — both still open, both prerequisites to acting on any of this.

## Sources (verified findings only)

- https://burrito.hexdocs.pm/readme.html (NIF recompile mechanism, `skip_nifs`)
- https://github.com/burrito-elixir/burrito/issues/6 (the 2021 exqlite failure)
- https://github.com/elixir-sqlite/exqlite/releases (prebuilt NIF target coverage)
- https://sqlite.org/cli.html · https://sqlite-utils.datasette.io/en/stable/cli.html (CLI boundary)
- https://sqlite.org/wal.html · https://sqlite.org/lang_transaction.html ·
  https://sqlite.org/c3ref/busy_handler.html · https://sqlite.org/rescode.html (WAL/BUSY semantics)
- https://tenthousandmeters.com/blog/sqlite-concurrent-writes-and-database-is-locked-errors/
  (recipe; every element re-verified against sqlite.org or reproduced empirically)
- https://hexdocs.pm/cubdb/faq.html · https://github.com/lucaong/cubdb (CubDB limits)
- https://github.com/rabbitmq/khepri · https://erlangforums.com/t/438 (Khepri design center)
- https://github.com/sst/opencode — `packages/core/src/database/database.ts:27-32` @ 4394b32
  (OpenCode PRAGMAs + schema split)
- Local: sqlite3 3.51.0 probes in session scratchpad; KB:
  `scriptorium/solutions/sqlite-bulk-insert-elixir-exqlite.md`,
  `scriptorium/wiki/burrito-single-binary-distribution.md`,
  `scriptorium/solutions/postgres-to-sqlite-migration-compat.md`
