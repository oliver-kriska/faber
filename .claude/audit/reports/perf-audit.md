# Faber performance/efficiency audit

Scope: `lib/` ingest → detect → eval → loop pipeline (file-and-subprocess, no DB). Only issues with
plausible impact at realistic session-log scale (tens of MB) are listed. Findings ordered by impact.

---

## WARNING — OpenCode ingest reads the ENTIRE DB into memory with no size cap and no session scoping

**Where:** `lib/faber/ingest/format/opencode.ex:54` (`@query`), `:69` (`discover/1`), `:86-120`
(`stream_file!/1` → `run_query/1` → `decode_rows/2`).

**What:** `discover/1` returns a single handle — the DB path `[db]`. `@query` is a
`message ⋈ part` LEFT JOIN across **all sessions, all messages, all parts** with no `LIMIT` and no
`session_id` filter. `run_query/1` calls `Faber.Subprocess.run(sqlite3, ["-json", …])`, which is
`System.cmd/3` (`lib/faber/subprocess.ex:23`) — it **buffers the whole stdout into one binary**.
`decode_rows/2` then `Jason.decode`s that entire blob into a full list before `Enum.chunk_by`.

**Why it matters:** This is the highest-volume read of the five formats — the complete OpenCode
history, not one file. `sqlite3 -json` inflates the payload substantially (JSON syntax overhead +
the `m.id/session_id/role` columns are repeated on every joined `part` row). A heavy multi-project
`opencode.db` (hundreds of MB on disk) can expand to a multi-GB JSON string held in memory at once,
plus the decoded term — a realistic OOM. The two other whole-file formats (`cline.ex:76-99`,
`gemini.ex:83-96`) each guard with a **50 MB `File.stat` cap**, and `ccrider.ex:66` scopes its read
`WHERE session_id = …` (one session at a time). OpenCode has **neither** — the size-cap coverage
that commit 282a497 added is 4/5 formats; OpenCode is the gap.

**Secondary (correctness-adjacent, same root cause):** because `discover/1` yields one handle for
the whole DB, `Scan.score_session` scores the entire OpenCode history as a **single session**
(one `Result`), and the fan-out has nothing to parallelize.

**Fix (addresses memory, parallelism, and the single-session collapse together):** make
`discover/1` return **one handle per session** (`SELECT id FROM session`), and have `stream_file!`/
`parse` filter `WHERE m.session_id = …` like `Source.Ccrider` already does. That bounds memory to
one session, restores per-session `Task.async_stream` fan-out, and makes each `Result` a real
session. Minimum stopgap if the handle shape can't change now: add a byte guard before decoding
(e.g. reject when `page_count * page_size` exceeds a cap, or cap the returned `out` length) so a
pathological DB fails closed like cline/gemini instead of ballooning.

---

## WARNING — Loop `:reflect` + `trigger:true` re-scores the unchanged best every iteration (redundant LLM calls)

**Where:** `lib/faber/loop.ex:477-500` (`build_propose_fn(:reflect, …)`) → `:547-557`
(`reflection_feedback/3`), which calls `Eval.score/2` on the current best.

**What:** In `:reflect` strategy, each iteration derives feedback by scoring the *current best*:
`reflection_feedback(subject = best, …)` → `Eval.score(subject, eval_opts)`. The candidate is then
scored a second time in `eval_candidate`. The best only changes on a **keep**, but its full eval
(needed for the weakest-dimension + failed-assertion feedback, which isn't stored in `State`) is
recomputed on **every** iteration — including long plateaus, up to `patience = 50` consecutive
rejects.

**Why it matters:** With `trigger: true`, every `Eval.score` runs `trigger_samples` (defaults to
**3** in the loop, `loop.ex:369-371`) × N fixtures **real LLM routing calls** (`Faber.Eval.Trigger`).
Re-scoring the fixed best each iteration roughly **doubles** the loop's routing-call spend (best +
candidate per iteration), and LLM calls are the loop's dominant cost/latency. Over a 50-iteration
run that is dozens–hundreds of avoidable model calls. (In structural-only mode the re-score is
native and sub-ms, so this is specifically a `reflect` + `trigger` cost.)

**Fix:** cache the best's full eval result (its `dimensions`) on `State`, populated in `keep/5` and
`init/1`, and have `reflection_feedback` read the cached `dimensions` instead of re-scoring. Note
this intentionally drops the per-iteration *resampling* of the fixed best — acceptable, since the
best is unchanged and the candidate is still scored fresh each iteration.

---

## SUGGESTION — Detect rebuilds `tool_uses` (×4) and `bash_commands` (×2) per session

**Where:** `lib/faber/detect.ex:160` (`friction`), `:256` (`fingerprint`), `:330` (`opportunity`),
`lib/faber/scan.ex:185` (`referenced_paths`); `bash_commands/1` (`detect.ex:614`) recomputed in
both `fingerprint` and `opportunity`.

**What:** `Scan.score_session` (`scan.ex:150-177`) calls `friction`, `fingerprint`, `opportunity`,
`context`, and `referenced_paths` on the same event list. Four of them independently do
`Enum.flat_map(events, & &1.tool_uses)` (four full rebuilds of the tool-use list) and `fingerprint`
+ `opportunity` each independently build `bash_commands`.

**Why it matters:** Each pass is O(n), so total is still O(n) — but on a tens-of-MB session
(thousands of events / tool-uses) it is ~4× redundant traversal + list allocation of a large list,
per session. Bounded and parallelized by the `Task.async_stream` fan-out, so low urgency; worth
doing if the corpus is large. (`Enum.to_list(events)` at the top of each function is a no-op on an
already-materialized list, so that part is fine.)

**Fix:** compute `tool_uses`, `names`, and `bash_commands` once in `score_session` and thread them
into the Detect functions (add arities that accept precomputed intermediates), or expose a single
`Detect.analyze/2` that computes the shared intermediates once and returns friction/fingerprint/
opportunity/context together.

---

## Checked and NOT flagged

- **Size caps across the 5 formats:** claude/codex are line-streamed via `File.stream!` (constant
  memory, per-line decode) — no cap needed; cline/gemini have the 50 MB `File.stat` cap. Consistent
  except OpenCode (finding 1).
- **`Faber.Eval.Native` / `Matchers`:** each matcher re-runs `split_frontmatter` (~15×) and
  `sections` (~8×) per `score`, re-splitting `content`. But artifacts are rendered SKILL.md capped
  at ≤535 lines (`loop.ex:290`) — sub-ms per score, a tiny-input micro-op, not worth restructuring.
- **`Consolidate.cluster`:** greedy single-linkage is O(clusters·members) but proposal sets are
  dozens at most — not a scale concern.
- **`Scan.dedupe` `deduped ++ without_id`:** single terminal concat, O(len deduped); fine.
- **`Event.raw` retention:** every event holds its full decoded record, but scan processes one
  session per task and discards events after producing the scalar `Result`, so peak ≈ one session.
  Inherent to Detect's model/usage extraction; acceptable.
- **`ccrider.parse`:** already scoped `WHERE session_id = …` (bounded per session) — good.
- **Prior architecture-review O(n²) `validate_entries` in adapter.ex:** not re-litigated per brief.
