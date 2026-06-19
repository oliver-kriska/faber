# Plan: v1 Completion — close the gap to the original HANDOFF vision

**Source:** gap analysis vs `HANDOFF.md` §1/§5/§7/§9. Goal: implement the remaining
original-scope items. `mix format` / `compile --warnings-as-errors` / `mix test` green after each.

**STATUS: COMPLETE.** All phases implemented + reviewed (4 parallel specialists) + 3 blockers
fixed. 122 hermetic tests (123 with `--include sidecar`) + 16 Python tests green.

**Scope decision (from DISCOVERING):**
- F1, F2, F5, F7, F4 — keyless, pure-Elixir, verifiable → **implemented**.
- F3 (GEPA) — needs `dspy` + provider key → **seam shipped**, reports `:not_implemented`.
- F6 (Codex/OpenCode/Pi ingest) — needs each agent's real transcript format → **seam shipped**,
  ships only the verified Claude format.

---

## Phase 1 — F1: Adapter-aware eval gate (the moat)  ✅ (commit cef61cc)

- [x] [P1-T1][elixir] `Faber.Eval.Native.score/2` honors a passed eval definition; `default_eval/0`
  exposed; nil/[] → default.
- [x] [P1-T2][elixir] `Faber.Eval` resolves the def: `:eval` > vendored adapter dims > exec-in-place
  (logged graceful fallback to native default) > default.
- [x] [P1-T3][elixir] `:adapter` threaded from `Loop.refine/3` and `mix faber.propose` into `Eval.score`.
- [x] [P1-T4][test] vendored-dims drive scoring; exec-in-place fallback; explicit `:eval` override.

## Phase 2 — F2: Keyless trigger-accuracy eval  ✅ (commit 1a8874a)

- [x] [P2-T1][elixir] `Faber.Eval.Trigger` — keyless per-phrasing routing accuracy via injected LLM.
- [x] [P2-T2][elixir] Folded in as optional `trigger: true` report; never required for structural pass.
- [x] [P2-T3][test] perfect → 1.0; mixed → partial; no fixtures → skipped.

## Phase 3 — F5: present / install pipeline tail  ✅ (commits db38e11, review fix)

- [x] [P3-T1][elixir] `Faber.Install` — writes `<dir>/<name>/SKILL.md`, refuses overwrite w/o force.
  **Hardened:** validates name as a safe path segment (LLM-derived → path-traversal defense).
- [x] [P3-T2][liveview] Dashboard per-row "Propose" → async propose+eval, panel render. **Hardened:**
  `Integer.parse` on the client param (no crash on bad input).
- [x] [P3-T3][test] install write/refuse/traversal-reject + dashboard propose-panel render.

## Phase 4 — F7: proposer uses adapter `templates/`  ✅ (commit eafd2d9)

- [x] [P4-T1][elixir] `Faber.Template` ({{token}} + {{#section}}); `Propose.render_skill_md/2` renders
  via adapter template when present, else built-in. Eval/Loop/task/dashboard/install all consistent.
- [x] [P4-T2][test] renders via template; falls back; real faber-elixir template complete.

## Phase 5 — F4: scheduled / overnight runs (no DB)  ✅ (commits 9d2bd75, review fix)

- [x] [P5-T1][otp] `Faber.Schedule` — `Process.send_after` GenServer, DB-less, started inert.
  **Hardened:** runs jobs via `Task.Supervisor.async_nolink` (crash-isolated from the permanent
  server), DOWN handling, `:notify` hook.
- [x] [P5-T2][test] fires on initial delay; inert when disabled; run_now; deterministic via `:notify`.

## BLOCKED — seam + scaffold shipped

- [x] [B-F3][python/elixir] `Faber.Optimize.run/2` → sidecar `optimize`; surfaces
  `{:error, {:not_implemented, _}}`. Python stub kept. Seam complete (wiring GEPA = Python-only later).
- [x] [B-F6][elixir] `Faber.Ingest.Format` behaviour + `Faber.Ingest.Format.Claude`; `Faber.Ingest`
  is now a format-agnostic façade (opts → config → Claude). Unknown alias raises loudly.

## Verification & sequencing
Per-phase: `mix format` + `mix compile --warnings-as-errors` + `mix test` (+ `mix test.full` for
sidecar/eval boundary). One commit per feature. Co-author trailer. Never push. ✅ all satisfied.
