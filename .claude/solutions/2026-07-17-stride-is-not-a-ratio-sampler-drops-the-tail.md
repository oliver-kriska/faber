---
module: "Faber.Scan"
date: "2026-07-17"
problem_type: logic_error
component: ranking_pipeline
symptoms:
  - "`faber scan --limit 200` over a 507-session corpus silently sampled only indices 0..398 — the 108 last-sorted sessions could not be scored at all, and no output said so"
  - "`--limit 3` over 20 sessions stopped at index 12 of 19: the same hole at a small limit, so it was never a `limit > count/2` corner case"
  - "for `limit > count/2` it degenerated further, returning the literal alphabetical prefix its own comment forbade (`NOT an alphabetical prefix — that would hide high-friction sessions`)"
  - "the existing spread test (3 of 6 sessions) passed throughout — that corpus was too small for the shortfall to show"
root_cause: "`Enum.take_every(step) |> Enum.take(limit)` visits indices 0, step, …, (limit-1)*step, spanning only step*(limit-1)+1 items. `step = div(count, limit)` FLOORS, so the span always falls short of `count` and the remainder is paid out of the tail. A stride is not a ratio: one integer cannot express count/limit unless it divides evenly."
severity: high
tags: [elixir, sampling, integer-division, div, ranking, off-by-domain, dogfooding, code-review]
related_solutions:
  - ".claude/solutions/2026-07-17-a-cap-on-a-ranking-cannot-precede-the-ranking.md"
---

# A stride is not a ratio — `div/2` floors, and the remainder always comes out of the tail

## Symptoms

`Faber.Scan`'s `:limit` promises an even cross-section of the corpus. Its own comment
said so, explicitly:

> Sample an EVEN SPREAD across the discovered paths, **not the alphabetical prefix**:
> `Path.wildcard/1` returns sorted paths, so a prefix skews toward whatever sorts first
> (often tiny stub sessions) and **hides the highest-friction sessions entirely**.

It did not do that. Measured against the real corpus (507 sessions in
`~/.claude/projects/-Users-oliverkriska-Projects-faber`):

| `--limit` | old code reached | of | tail unreachable |
|---|---|---|---|
| 200 | index 398 | 506 | **108 sessions** |
| 150 | index 447 | 506 | 59 sessions |
| 100 | index 495 | 506 | 11 sessions |
| 3 (of 20) | index 12 | 19 | 7 sessions |

The scan silently could not see sessions whose filename sorts late — the exact failure
the function was written to prevent.

## Investigation

1. **Hypothesis: it's a `limit > count/2` corner case.** Probing 1..12 over a 10-item list
   showed `limit >= 6` returning a pure prefix (`step` floors to 1 → `take_every(1)` keeps
   everything → `take(limit)` is a prefix). Fixed it, wrote a test at `limit 6` of 10,
   committed, and described it as "a prefix for half of every limit it accepted."
   **This was true but was not the bug.**
2. **Dogfooded against the real corpus** (the step that actually found it — prompted by
   "do you want to run something like faber scan to confirm stuff?"). At `--limit 200` over
   507 sessions the old code was **not** a prefix (`step = 2`) — and *still* dropped 108
   sessions. The prefix framing was an artifact of the toy corpus I probed with.
3. **Root cause found**: the span, not the prefix. See below.

## Root Cause

```elixir
# The problematic code
defp maybe_take(paths, limit) when is_integer(limit) and limit > 0 do
  step = max(div(length(paths), limit), 1)
  paths |> Enum.take_every(step) |> Enum.take(limit)
end
```

`take_every(step) |> take(limit)` visits indices `0, step, 2*step, … (limit-1)*step`.
So it spans `step*(limit-1) + 1` paths — **not `count`**.

`step = div(count, limit)` uses integer division, which floors. Therefore
`step*limit <= count`, and the shortfall `count - step*limit` (up to `limit-1` items) is
never visited. Because the traversal starts at 0 and marches forward, that shortfall is
always paid **out of the tail**.

Two distinct manifestations, one mistake:

- **Always**: the last `count - 1 - step*(limit-1)` items are unreachable at *every* limit.
- **When `limit > count/2`**: `div` floors `step` to 1, and it degrades into the literal
  alphabetical prefix.

Since `Path.wildcard/1` returns **sorted** paths, the tail is a name range, not noise.
Biasing against it is biasing against a fixed slice of the corpus by filename.

## Solution

A stride cannot express a non-whole ratio. Compute the spread **by index** instead:

```elixir
defp maybe_take(paths, limit) when is_integer(limit) and limit > 0 do
  count = length(paths)

  if limit >= count do
    paths
  else
    keep = MapSet.new(0..(limit - 1), &div(&1 * count, limit))

    paths
    |> Enum.with_index()
    |> Enum.filter(fn {_path, i} -> MapSet.member?(keep, i) end)
    |> Enum.map(&elem(&1, 0))
  end
end
```

`div(i * count, limit)` distributes the rounding error across the whole range instead of
accumulating it at one end. Verified on the real corpus: `--limit 200` now reaches index
504 of 506. O(n), and the `limit >= count` guard keeps the index math from producing
duplicate slots.

### Files Changed

- `lib/faber/scan.ex:372` — `maybe_take/2`, index-based spread replacing the stride
- `lib/faber/scan.ex` (moduledoc) — `:limit`'s two meanings documented
- `test/faber/scan_test.exs` — "the sample reaches the tail of the corpus at every limit"
  (loops `limit` 1..19 over 20 sessions, asserts the furthest index is within one stride
  of the end); "the spread holds for a limit larger than half the corpus"
- `docs/GUIDE.md` §7 — the `--limit` row
- Commits: `1f78927` (fix), `8f7ac25` (the correction this doc records)

## Prevention

- **Probe a sampler across its whole domain, never at one point.** The bug is invisible at
  `limit=3, count=6` and total at `limit=200, count=507`. A single-example test existed and
  passed for months — it just sat on a working point. Loop the range in the test.
- **Any `div(a, b)` used as a step, stride, batch size or chunk width is suspect.** It floors,
  and the remainder lands somewhere. Ask *where* — and whether that place is ordered.
- **A helper's comment is a claim, not a test.** This one stated the precise property it
  violated, and had been read many times, including twice by me during this fix.
- **Dogfood against the real corpus before writing the solution doc.** The unit test proved
  the fix; the real corpus proved my *explanation* wrong. A wrong explanation in a comment
  is a live defect — it is what the next reader will trust.
- [x] Add to test patterns — range-loop the sampler, don't spot-check it.
- [ ] Iron Law? No — too narrow. It belongs as a reviewer heuristic on `div/2` as a stride.

## Related

- `.claude/solutions/2026-07-17-a-cap-on-a-ranking-cannot-precede-the-ranking.md` — the
  sibling bug in the same pipeline; found first, and the reason this code was being read
- `.claude/scriptorium/2026-07-17-cap-after-sort-and-the-sampler-that-isnt-a-prefix.md` —
  cross-project drop file carrying the generalized pattern
