---
target: the dashboard (dashboard_live.ex)
total_score: 37
p0_count: 0
p1_count: 0
timestamp: 2026-07-16T04-44-43Z
slug: lib-faber-web-live-dashboard-live-ex
prior: 2026-07-15T16-58-41Z (30/40)
---
## Design Health Score

| # | Heuristic | Score | Δ | Key Issue |
|---|-----------|-------|---|-----------|
| 1 | Visibility of System Status | 3 | — | First scan still shows "scanning sessions…" over a blank region — no skeleton/progress. |
| 2 | Match System / Real World | 4 | +1 | `Tools`/`Errs`/`Ctx` headers now carry `data-tip`; no bare abbreviations remain. |
| 3 | User Control and Freedom | 3 | — | Rows now operable by keyboard, but still no cancel for an in-flight paid Propose, no undo on install. |
| 4 | Consistency and Standards | 4 | +1 | Rows are real controls now (`role="button"` + `tabindex` + `:focus-visible` + Enter/Space); combos advertise `aria-expanded`. |
| 5 | Error Prevention | 4 | — | Server-side gating, `data-confirm`, never-clobber install, explicit Reinstall, bounds-checked indices, debounce. |
| 6 | Recognition Rather Than Recall | 4 | +1 | Keyboard model advertised in the table `<caption>`; rows focusable. Definition tooltips are still hover-only (SR/keyboard gap remains). |
| 7 | Flexibility and Efficiency | 3 | +1 | `phx-window-keydown` no longer fights the filter search; hero gives a lead action. Hard 25-row cap with no "show more" persists. |
| 8 | Aesthetic and Minimalist | 4 | — | Hairlines not shadows, one reserved accent, tabular mono numbers. Heat wash now actually reads; selected row legible on its own. |
| 9 | Error Recovery | 4 | +2 | Scan + propose failures now humanize to a plain sentence, log the raw term, and offer Retry; crash state is distinct from empty. |
| 10 | Help and Documentation | 4 | +1 | Empty state teaches (scanned path + `min_messages` + next step); the hero orients a first-run user. |
| **Total** | | **37/40** | **+7** | **Excellent (36–40)** |

## Anti-Patterns Verdict

**Does this look AI-generated? No.** Unchanged from the prior pass — a confident, category-fluent tool.

**Deterministic scan:** `detect.mjs` on `dashboard_live.ex` + `app.css` + `app.js` returned **0 findings, exit 0** — no side-stripe borders, gradient text, glassmorphism, eyebrows, or numbered scaffolding. The `color-mix` accent wash on the selected row and the hero panel introduced no new tells.

**Visual overlays:** Still unavailable — the MCP browser was disconnected for the whole run, so this remains a source-based critique. The unverified layer is the same: live focus order, real contrast render, the StageMorph tween, and the <720px / 461–719px breakpoints.

## What Changed Since 30/40

The prior critique's concentrated gap — "everything the mouse-and-eyes user gets is excellent; everything the keyboard, screen-reader, and failure-path user gets is unfinished" — is largely closed:

1. **[P1 → resolved] Rows are a real control.** `tbody tr.srow` now has `tabindex="0"`, `role="button"`, `aria-label`, an Enter (`phx-keydown`) + Space (client) handler, and a `:focus-visible` inset ring; a `<caption>` advertises the arrows / j-k / Enter model. Lifts heuristics 4 and 6 as predicted.
2. **[P1 → downgraded to P2] The combo/search collision is gone; ARIA partially done.** `phx-window-keydown="nav"` is now stopped at `document` when the target is a field, so typing a filter no longer moves the ranking; triggers sync `aria-expanded`. Still open: `role="option"` + `aria-selected` on combo items and focus-return-to-trigger on close.
3. **[P2 → resolved] Async failure paths.** `humanize_error/1` maps exits/exceptions/timeouts to one plain sentence, logs the raw term (never renders it), and the proposal-card error state carries a token-spend-confirmed Retry.
4. **[P2 → resolved] Empty state teaches.** A genuinely empty scan names where Faber looked and the message floor and points at the next step; a crashed scan gets its own copy via a `scan_error?` flag.
5. **[P3 → resolved] Light-theme accent clears AA.** `--accent` darkened to `#8a5e0b` (white 5.7, canvas 5.31, hover 4.95 — all ≥4.5).
6. **Landing leads with the opinion.** The hero features the single highest-friction session + a Propose CTA (never auto-proposing) — the prior "12-column spreadsheet when the thesis is one worst session" personality gap.
7. **Minors cleared.** Header tooltips, a legible selected-row wash (was ΔL ≈ 0.004), a stronger heat wash, `min(360px, 100%)` on `.detail-inner` to prevent mid-morph overflow, and the reduced-motion progress bar now hidden (not frozen).

## Remaining Backlog

- **[P2] Combo ARIA completeness** — `role="option"` + `aria-selected`, and return focus to the trigger on close.
- **[P2] Definition tooltips are hover-only** — the `?`/`data-tip` help is invisible to keyboard/SR; inline expandable prose or `:focus`-triggered tooltips would close the last a11y gap.
- **[P2] No cancel for an in-flight paid Propose; no undo on install** (pre-confirm only). A mid-flight refresh before `Store.put` can still double-spend.
- **[P3] Hard 25-row cap** with no "show more" though the full scan is in memory.
- **[P3] Native `confirm()`** is the one off-theme OS jolt — candidate for an inline commit + short undo.
- **[P3] Visibility of status** — the first scan is still a bare "scanning sessions…" with no skeleton.

## Overall Impression

The surface has moved from "excellent for the mouse, unfinished for everyone else" to a genuinely well-rounded tool: the core action is a real focusable control, the paid failure paths recover gracefully, and the landing states its opinion. What remains is a coherent second tier — deeper ARIA, keyboard-reachable help, in-flight cancel/undo, and pagination — none of which block the primary flow. A live browser pass (focus order, contrast render, the tween, the 461–719px band) is the one layer still unverified.
