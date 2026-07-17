---
module: "Faber.Scan"
date: "2026-07-17"
problem_type: logic_error
component: ranking_pipeline
symptoms:
  - "`faber scan --format codex --limit N` returned a different top-N on repeated runs over identical input — the ranking depended on which sessions finished scoring first"
  - "the reproduction failed only ~2 runs in 6; pinning `max_concurrency: 1` made it fail every time"
  - "a `--limit 2` that should have returned the two highest-friction sessions returned one high and one arbitrary"
root_cause: "the post-filter `:limit` was applied before `dedupe/2` and `Enum.sort_by/3`, so it truncated an UNRANKED list and only then ranked the survivors. With `Task.async_stream(ordered: false)`, the survivors were whichever sessions completed scoring first — making the ranking a function of scheduler timing."
severity: high
tags: [elixir, task-async-stream, ordered-false, ranking, flaky-test, reproduction, concurrency, code-review]
related_solutions:
  - ".claude/solutions/2026-07-17-stride-is-not-a-ratio-sampler-drops-the-tail.md"
---

# A cap on a ranking cannot run before the ranking exists

## Symptoms

When a project scope cannot narrow discovery (`base: nil` — the Codex/Gemini/OpenCode
layout, where transcripts aren't partitioned by project), `:limit` stops being a speed knob
and becomes a cap on *results* (`split_limit/2`). It was applied in the wrong place:

```elixir
|> Task.async_stream(&score_maybe_cached/4, ordered: false)   # completion order!
|> Stream.filter(...)
|> Enum.to_list()
|> maybe_take(post_limit)    # <- cap, on an UNRANKED list
|> dedupe(dedupe)
|> Enum.sort_by(&sort_key(&1, rank_by), :desc)
```

So `--limit N` took N sessions off an unranked list and ranked them afterwards. Since the
scoring stream runs `ordered: false`, those N were whichever sessions happened to finish
first — **a ranking decided by scheduler timing, in a tool whose entire product is the
ranking.**

## Investigation

1. **Wrote the reproduction unpinned** — two sessions, one frictionless (`aa_quiet`), one
   with a retry loop (`zz_noisy`), `--limit 1`, asserting `["noisy"]`. It **passed**. Ran it
   six more times: failed 2 of 6.
2. **The flakiness *is* the finding, not an obstacle to it.** A ranking that is wrong only
   sometimes doesn't read as a bug — it reads as "the scan found something else this time."
   That is why it survived review.
3. **Pinned `max_concurrency: 1`** so scoring order equals discovery order. Now it fails
   deterministically, on the defect rather than on the scheduler. 4/4 runs.
4. **Moving the cap surfaced a second bug**: `maybe_take/2` is not a prefix take. See Related.

## Root Cause

A cap that means "the top N" cannot be evaluated until a ranking exists. Applying it earlier
doesn't cap the ranking — it *samples the input* and then ranks the sample, which is a
different operation wearing the same flag name.

Arbitrary twice over: `ordered: false` decided which items survived, and `dedupe/2` had not
yet collapsed the sidechain rows competing for those N slots.

## Solution

```elixir
|> Enum.to_list()
|> dedupe(dedupe)
|> Enum.sort_by(&sort_key(&1, rank_by), :desc)
# LAST, and it has to be: `post_limit` caps the RANKING's top, so it cannot run
# until the ranking exists.
|> take_top(post_limit)
```

**`take_top/2`, not `maybe_take/2`** — and this is the load-bearing detail. `maybe_take/2` is
a *spread sampler*, correct for choosing which sessions to score (a prefix would skew to
whatever sorts first) and catastrophic on a finished ranking, where it returns ranks 1, 4
and 7 of ten and calls them the top three. **Two meanings of "limit" are two functions:**

```elixir
defp take_top(results, nil), do: results
defp take_top(results, limit) when is_integer(limit) and limit > 0, do: Enum.take(results, limit)
defp take_top(results, _limit), do: results
```

### Files Changed

- `lib/faber/scan.ex:205` — cap moved after `dedupe` + `sort_by`
- `lib/faber/scan.ex:395` — new `take_top/2` (a prefix, deliberately not the spread sampler)
- `test/faber/scan_scope_test.exs` — "keeps the HIGHEST-friction session, not whichever was
  scored first" (`max_concurrency: 1`); "caps the ranking with a PREFIX, not an even spread"
- `docs/GUIDE.md` §7 — `--limit`'s two meanings
- Commit: `a44e764`

## Prevention

- **When a flaky test reproduces a bug, pin the source of nondeterminism rather than
  retrying.** `max_concurrency: 1` here. The test then fails on the defect, and the comment
  records that the flakiness was the bug's real shape.
- **`ordered: false` is a promise that downstream must not read order as meaning.** Audit
  every `Enum.take`/`Stream.take`/pattern-match on position downstream of one.
- **Before relocating a call in a pipeline, read the callee.** A helper named
  `take`/`limit`/`sample` may encode a policy that was only correct at its original position.
- **One flag name, two meanings, is a design smell.** `split_limit/2` already knew `:limit`
  meant two different things; the two meanings needed two functions, not one call site.
- [x] Add to test patterns — pin concurrency in ordering assertions.
- [ ] Iron Law? No — but a reviewer heuristic on `ordered: false` + downstream `take` is apt.

## Related

- `.claude/solutions/2026-07-17-stride-is-not-a-ratio-sampler-drops-the-tail.md` — the bug
  found *underneath* this one while fixing it
- `.claude/scriptorium/2026-07-17-cap-after-sort-and-the-sampler-that-isnt-a-prefix.md` —
  cross-project drop file
