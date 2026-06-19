# Faber M3–M6 Review-Fixes — Re-Review

> **FOLLOW-UP (applied).** Quick wins **TW1, S-a, S-b, S-e** were fixed after this review
> (bounded `await` timeout in tests; `length/1` bound once; `put_flash` on scan `{:exit}` via a
> fully-qualified `flash_group`; `SeqSidecar` opts-contract comment). 83 hermetic / 84 full green.
> **Deferred** (optional, no correctness impact): **TW2** (`@describetag` footgun), **S-c** (0700
> temp subdir umask window), **S-d** (CI to run `test.full` — no CI config exists yet), and the
> pre-existing cosmetic `faber.propose` shell message.


**Scope:** the fix work for the prior M3–M6 review (`diff f9ded78..HEAD` — 6 fix commits + docs).
This is a re-review verifying that the 5 blockers / 9 warnings / 4 suggestion groups from
`.claude/plans/m3-m6/reviews/faber-m3-m6-review.md` were resolved *correctly* (not just present).

**Agents (8/8):** elixir-reviewer · otp-advisor · liveview-architect · security-analyzer ·
testing-reviewer · iron-law-judge · verification-runner · requirements-verifier.

---

## Verdict: ✅ PASS WITH WARNINGS

Every prior blocker and warning is **confirmed resolved and behaviorally correct** — not merely
checked off. Six of eight specialists found the fixes clean with zero blockers; the only new items
are polish-tier (test-defensive and one umask micro-window). No regressions. Suite green.

| Dimension | Result |
|-----------|--------|
| Verification | ✅ compile (WAE) clean · format clean · `mix test` 83 pass / 1 excluded · `mix test.full` 84 pass · Python 16 pass |
| Requirements (vs the fix-plan) | ✅ **17 MET · 0 UNMET** (verifier's lone S4 PARTIAL was a false negative — empty-file test exists at `scan_test.exs:96`) |
| OTP / Elixir / LiveView / Security / Iron-laws | ✅ all prior findings closed; **0 new blockers** |

---

## Verification of prior findings (all closed)

- **BL1** (Loop.Server sync loop) — Task.async + `handle_info({ref, result}, %Task{ref: ref})` +
  `demonitor([:flush])` is the canonical pattern; waiters replied atomically; crash propagation via
  the link is intentional and documented. *(otp, elixir, iron-laws)*
- **BL2** (Dashboard sync scan) — `start_async`/`handle_async` correct (not `assign_async`); all
  template assigns seeded on both mount branches (no KeyError); `:scanning` debounce + disabled
  button cannot get stuck. *(liveview, elixir)*
- **BL3** (`refine/3` MatchError) — tagged-tuple `case`, returns `{:error, _}`. *(elixir)*
- **BL4** (vacuous refine test) — sequencing `SeqSidecar` traces `[0.5,0.6,0.55×3]` → best 0.6 /
  1 keep / 3 reverts; exercises real keep/revert. *(testing)*
- **BL5** (parity never ran) — `exclude: [:sidecar]` + `test.full` alias + `def cli`; parity now on
  good **and** bad inputs. *(testing)*
- **W1–W9** — sidecar exit code, git path-scope (`Path.safe_relative` rejects abs/`..`/`-flag`,
  `--` separator, empty-list short-circuit), `app.config`, safe Journal decode, `File.write/2`,
  adapter-in-prompt, O_EXCL+0600 temp, loop error-path tests, flash group — all confirmed.
  *(security, elixir, iron-laws, testing)*

---

## New findings (all non-blocking)

### WARNINGS (test-defensive)
- **TW1** `Server.await(pid)` in the new multi-iteration test passes no finite timeout; on a broken
  loop the caller hangs rather than failing. Deterministic today (loop completes), but a bounded
  timeout would fail-fast. *(testing)* `test/faber/loop_test.exs`
- **TW2** the parity test uses `@describetag :sidecar` on the *describe block* — any future test
  added to that block is silently excluded. Intentional for the current sole test, but a footgun.
  *(testing)* `test/faber/eval_test.exs`

### SUGGESTIONS
- **S-a** `handle_async(:scan, {:ok, results})` calls `length(results)` twice (`:total` + `:shown`);
  bind once. *(elixir)* `dashboard_live.ex`
- **S-b** the `{:exit, _}` scan branch silently resets to empty state; a flash would tell the user
  the scan crashed vs. showing an empty table. (Now that `flash_group` exists, this is cheap.) *(liveview)*
- **S-c** sidecar temp file has a brief umask window between `O_EXCL` open and `chmod 0600`; a
  `0700` per-run subdir would close it. Negligible for the single-user threat model. *(security)*
- **S-d** no CI enforces `mix test.full`; parity relies on developer discipline per CLAUDE.md.
  (No CI config exists in the repo yet.) *(testing)*
- **S-e** `SeqSidecar`'s `Keyword.fetch!(:seq_agent)` would crash if `Eval.score` ever filtered opts
  before forwarding; worth a one-line comment pinning that contract. *(testing)*

### PRE-EXISTING (not introduced by the fixes)
- `mix faber.propose`'s `propose/2` prints "Proposing for…" before the LLM call, so the line shows
  even on an immediate failure. The `with/else` handles the error (no crash); cosmetic only. *(elixir)*

---

## Filtered out (anti-noise)
- requirements-verifier **S4 PARTIAL** — false negative; the empty-file `score_session` test is at
  `scan_test.exs:96` and runs (it's part of the 83). Recorded as **MET**.
- Rust meta-cognition hook output — irrelevant (Elixir project), ignored throughout.
