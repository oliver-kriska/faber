# Handoff: should Faber's persistence move to SQLite?

**Date:** 2026-07-15
**Status:** analysis + verdict from the implementing session; **research delegated to a follow-up session**
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
