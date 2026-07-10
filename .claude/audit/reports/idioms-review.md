# Faber — Elixir Idioms/Correctness Follow-up Review (2026-07-10)

Scope: whole `lib/` tree (57 files, ~9,000 LOC), with extra scrutiny on modules changed since the
2026-06-26 review (`.claude/plans/review/reviews/elixir-idioms.md`). That review's 9 findings are
verified below (still-open vs fixed), followed by newly found issues.

## Status of the 2026-06-26 findings

- **#1 BLOCKER** `Adapter.validate_entries/3` `acc ++ fun.(entry)` O(n²) — **still open**
  (`lib/faber/adapter.ex:346`, unchanged).
- **#2 WARNING** Elixir-stack defaults hardcoded in `Faber.Detect` (`@default_fingerprint_rules`,
  `@default_skill_namespaces`) — **still open** (`lib/faber/detect.ex:85-107`, unchanged).
- **#3 WARNING** bare `spawn/1` in `Faber.CLI.dispatch/1` — **still open** (`lib/faber/cli.ex:173`,
  unchanged; accepted tradeoff per moduledoc, still worth a `Task.start/1` swap for OTP-idiom clarity).
- **#4 WARNING** `Eval.run_eval/2` calls `adapter_eval(opts)` twice — **still open**
  (`lib/faber/eval.ex:91-92`, unchanged).
- **#5–9 SUGGESTIONS** (detect.ex cohesion, `glob_compiles?/1` rescue-for-control-flow, `true|false`
  case match, bare `[]` in `with`, missing `@spec`) — all **still open**, unchanged locations.

None of the prior findings have regressed further or been fixed; none are re-detailed here per
instructions.

## New findings

### WARNING — `Faber.Loop.keep/5` ignores `Git.commit/3` failure, letting in-memory best diverge from HEAD — `lib/faber/loop.ex:208-209`

```elixir
defp keep(state, iteration, %{content: content} = candidate, composite, desc) do
  if state.git, do: Git.commit(state.dir, state.git_paths, keep_message(state, composite))
  ...
```

`Git.commit/3` returns `:ok | {:error, term()}` (`lib/faber/loop/git.ex:16-20`) but the return value
is discarded. The git-mode invariant the moduledoc states is "HEAD always holds the current best
skill." If the commit fails — e.g. `git commit` exits non-zero because the candidate's content is
byte-identical to HEAD ("nothing to commit"), which is a real scenario in `:reflect`/`trigger` mode
where the LLM re-emits the same draft but eval noise reports a higher composite — the working tree
still holds the new content (written by `write_candidate/2` before `keep/5` runs) and `state`
records it as kept, but HEAD does **not** advance. The very next `reject/5` restores via
`Git.revert(dir, paths)` = `git checkout -- paths`, which silently discards the on-disk "kept"
content back to the stale HEAD — while `state.best_content`/`state.best_composite` in memory still
claim the newer content is current. The loop's final `state.best_content` and the actual working
tree (and any later `render_best`/install step reading from `state`, not disk) go out of sync with
no error surfaced anywhere.

```elixir
# Suggested — treat a failed commit as a failed keep, not a silent no-op
defp keep(state, iteration, %{content: content} = candidate, composite, desc) do
  case commit_if_git(state, composite) do
    :ok ->
      entry = entry(state, iteration, composite, true, desc, nil)
      log(state, entry)
      %{state | iteration: iteration, best_content: content,
        best_proposal: Map.get(candidate, :proposal) || state.best_proposal,
        best_composite: composite, consecutive_discards: 0,
        history: [entry | state.history]}

    {:error, reason} ->
      reject(state, iteration, state.best_composite, desc, "commit failed: #{inspect(reason)}")
  end
end

defp commit_if_git(%{git: true} = state, composite),
  do: Git.commit(state.dir, state.git_paths, keep_message(state, composite))

defp commit_if_git(_state, _composite), do: :ok
```

### WARNING — `Faber.Consolidate.cluster/2` — O(n²) list rebuilding via `++` inside `Enum.reduce`, same anti-pattern as the still-open `Adapter.validate_entries/3` blocker — `lib/faber/consolidate.ex:51-58`

```elixir
case Enum.split_while(clusters, fn members -> ... end) do
  {_all, []} -> clusters ++ [[{p, toks}]]
  {before, [hit | rest]} -> before ++ [hit ++ [{p, toks}] | rest]
end
```

Both branches rebuild the whole `clusters` list (`clusters ++ …` copies every existing cluster;
`before ++ […| rest]` copies the prefix) on every proposal processed, and `Enum.split_while` itself
is already O(n) per iteration — so `cluster/2` is O(n²) (or worse, O(n²) list-copy on top of an O(n²)
scan) in the number of input proposals. Proposal batches are small today, but this is new code (not
present at the 2026-06-26 review) reintroducing the exact class of bug already flagged as a BLOCKER
elsewhere in this codebase — worth fixing now before it's copied again. A single accumulator pass
that finds-or-appends without rebuilding the prefix avoids the double O(n) cost:

```elixir
defp place(clusters, p, toks, threshold) do
  case Enum.find_index(clusters, fn members ->
         Enum.any?(members, fn {_mp, mtoks} -> jaccard(toks, mtoks) >= threshold end)
       end) do
    nil -> clusters ++ [[{p, toks}]]
    idx -> List.update_at(clusters, idx, &(&1 ++ [{p, toks}]))
  end
end
```

(This doesn't eliminate the O(n) `List.update_at`/`++` per placement, but removes the redundant
`before`/`clusters` full-list rebuild your `split_while`-based version does on top of the scan; for a
real fix at scale, accumulate into a `%{index => [members]}` map and materialize the list once at the
end.)

## Clean areas (spot-checked, no new issues)

- `lib/faber/subprocess.ex`, `lib/faber/schedule.ex` — the `Task.yield`/`Task.shutdown`/`brutal_kill`
  timeout and wedge-guard logic is correct, including the completed-vs-stale-ref race in
  `handle_info({:run_deadline, ref}, ...)`; `Task.Supervisor` is properly supervised in
  `lib/faber/application.ex:25`.
- `lib/faber/feedback.ex`, `lib/faber/ingest/source/ccrider.ex`, `lib/faber/ingest/format/opencode.ex`,
  `lib/faber_web/live/dashboard_live.ex`, `lib/mix/tasks/faber.refine.ex` — no correctness or idiom
  issues found; error handling, rescue scoping, and LiveView event authorization (the `--i` parse +
  `allow_propose?` server-side gate) are all sound.
- `lib/faber/loop/git.ex`, `lib/faber/loop/journal.ex` — path-escape guarding (`safe_paths/2`) and
  corrupt-line-skipping JSONL read are both correct.
- Whole-tree sweep for `Enum.reduce` + `++` (O(n²) risk), bare/broad `rescue`, and `String.to_atom` on
  untrusted input turned up nothing beyond the two items above and the still-open prior BLOCKER —
  `lib/faber/eval.ex`, `lib/faber/eval/matchers.ex`, `lib/faber/propose.ex`, `lib/faber/install.ex`,
  `lib/faber/cli.ex` are otherwise idiomatic (consistent `with`/tagged-tuple style, narrow rescues at
  documented I/O boundaries, `to_existing_atom` guarded by `Code.ensure_loaded/1` in
  `Faber.Eval.atomize_params/1`).
