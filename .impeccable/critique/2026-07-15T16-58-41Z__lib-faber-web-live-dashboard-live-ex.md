---
target: the dashboard (dashboard_live.ex)
total_score: 30
p0_count: 0
p1_count: 2
timestamp: 2026-07-15T16-58-41Z
slug: lib-faber-web-live-dashboard-live-ex
---
## Design Health Score

| # | Heuristic | Score | Key Issue |
|---|-----------|-------|-----------|
| 1 | Visibility of System Status | 3 | First scan shows only "scanning sessions…" over a blank region (fan-out over hundreds of transcripts) — no skeleton/progress. |
| 2 | Match System / Real World | 3 | `Errs` and `Ctx` headers carry no `data-tip` while `Events`/`Turns`/`T2` do — two unexplained abbreviations. |
| 3 | User Control and Freedom | 3 | No cancel for an in-flight ~1-min paid Propose; no undo on install (pre-confirm only). |
| 4 | Consistency and Standards | 3 | Internally consistent, but interactive `<tr>` rows and non-listbox combos are non-standard controls for standard tasks. |
| 5 | Error Prevention | 4 | Server-side gating beyond the hidden button, `data-confirm`, never-clobber install, explicit Reinstall, bounds-checked indices, debounce. |
| 6 | Recognition Rather Than Recall | 3 | Keyboard nav (j/k/↑↓/Esc) is entirely unadvertised; tooltip help is hover-only (invisible to keyboard/SR). |
| 7 | Flexibility and Efficiency | 2 | Hard 25-row cap with no "show more"; no bulk propose/install; no hotkey to act; window-keydown collides with the filter search. |
| 8 | Aesthetic and Minimalist | 4 | Hairlines not shadows, one reserved accent, tabular mono numbers, generous air, data-driven heat wash. Almost nothing decorative. |
| 9 | Error Recovery | 2 | Install errors are excellent/actionable, but scan + propose (the paid paths) punt to "see server logs" and render raw `inspect(reason)`. |
| 10 | Help and Documentation | 3 | Good in-context tooltip system + `?` affordance, but no onboarding and the primary empty state teaches nothing. |
| **Total** | | **30/40** | **Good (28–35)** |

## Anti-Patterns Verdict

**Does this look AI-generated? No.** It reads as a confident, category-fluent tool, not boilerplate.

**LLM assessment:** The slop tells are absent — no card grid, no gradient hero tiles, no purple, no rounded-everything, no emoji chrome. A disciplined token layer (real 4pt scale, semantic z-index, sans/mono split with tabular-nums), an accent genuinely reserved to one job (friction + active), and the `explain/1` prose sentence that narrates a session back to you. A developer fluent in Linear/Raycast/Stripe would sit down and trust it. The two places the fluent eye pauses: the primary action is a clickable `<tr>` with no button semantics/focus ring (a non-standard affordance for a standard task), and the async failure paths leak raw `inspect(reason)` + "see server logs" (developer-chrome on a finished surface). Biggest *personality* gap (staying within the calm brand): the landing view is a 12-column spreadsheet when the thesis is "one worst session begging for a skill" — it never leads with the opinion it already holds.

**Deterministic scan:** `detect.mjs` on the markup (`dashboard_live.ex`) returned **0 findings, exit 0** — no side-stripe borders, gradient text, glassmorphism, eyebrows, or numbered-section scaffolding. The detector *agrees* with the not-slop verdict and found no false positives. Note its blind spot: it scores the visual layer, so it cannot catch the issues that actually dominate this critique (keyboard operability, ARIA state, async error recovery, empty-state teaching) — those came entirely from the design review.

**Visual overlays:** Unavailable. The MCP browser has been disconnected throughout the session, so no live server was started and no overlay was injected into the page. This critique is source-based; no user-visible overlay exists in your browser. A browser pass (focus order, real contrast render, the StageMorph animation, <720px) remains the one unverified layer.

## Overall Impression

A genuinely well-crafted, restrained product surface — the aesthetic, contrast honesty, and error *prevention* are top-tier and on-brand. The gap is concentrated and consistent: **everything the mouse-and-eyes user gets is excellent; everything the keyboard, screen-reader, and failure-path user gets is unfinished.** The single biggest opportunity is to make the core action (open a session) a real, focusable, announced control — that one change lifts three heuristics and unlocks a whole persona.

## What's Working

1. **Contrast honesty enforced at the token layer.** Computed dark ratios: `--muted #9aa2b1` on `--bg #101216` ≈ 7.3:1, `--fg-dim` ≈ 11.2:1, `--accent #d8a34a` ≈ 8.3:1, green install badges ≈ 5.3:1. The code comments' AA claims are *accurate*, and there's no light-gray-for-elegance — the "honest" principle is mechanical, not aspirational.
2. **The one-stage overview⇄detail collapse.** `data-mode` end-states stand alone in CSS, a container query drops the metric columns to make the table a sidebar, and the `StageMorph` FLIP hook tweens only the un-interpolatable `fr` tracks — while checking `prefers-reduced-motion` and the 720px query itself before animating. Single-focus + progressive disclosure + act-in-place in one purposeful move with a real fallback.
3. **Layered prevention on irreversible actions.** Server-side gate (not just the hidden button) + `data-confirm` + never-clobber + explicit Reinstall + proposal persisted to `Store` before assigns (no double-charge on a post-success refresh). "Local-first candor" made mechanical.

## Priority Issues

**[P1] Clickable rows are invisible to keyboard and assistive tech.**
- **What:** `tbody tr.srow` has `phx-click="select"` and `cursor:pointer` but no `tabindex`, no `role`, no `:focus-visible` (buttons + the combo search have one; the row doesn't), and no key handler. The only keyboard path is the undiscoverable window-level `nav` (j/k/↑↓).
- **Why it matters:** a keyboard-only or screen-reader user can read the table but cannot discover or operate the product's core action. A whole persona is locked out of the primary flow.
- **Fix:** make the actionable target a real control — `tabindex="0"` + `role="button"` + `keydown(Enter/Space)=select` on `.srow` with a `:focus-visible` outline (or a focusable button in the rank/project cell); advertise j/k in a `<caption>`/legend.
- **Suggested command:** `/impeccable harden`

**[P1] Custom combos/menu are ARIA-incomplete, and `phx-window-keydown` fights the filter search.**
- **What:** `.combo-trigger` sets `aria-haspopup="listbox"` but JS toggles only a `.open` class — `aria-expanded` is never set; the menu is `role="listbox"` while its children are `<button>` (not `role="option"`); on close, focus drops to `<body>` (no focus return). Worse, `phx-window-keydown="nav"` fires on every keystroke with no input-focus guard — typing `j`/`k`/↑/↓/`Escape` in the searchable Project filter simultaneously moves the table selection / deselects.
- **Why it matters:** screen readers mis-announce combo state, keyboard focus is lost on close, and the search box is actively hostile — half the alphabet and the arrows fight the field.
- **Fix:** set `aria-expanded` on toggle; use `role="option"` + `aria-selected` (or a native `<select>` for the two non-searchable facets); return focus to the trigger on close; in `handle_event("nav", …)` ignore the event when the target is an input/textarea.
- **Suggested command:** `/impeccable harden`

**[P2] Both async failure paths punt to logs and leak raw `inspect`.**
- **What:** `handle_async(:scan/:propose, {:exit, _})` → "Scan/Proposal failed — see server logs."; the proposal card renders `Proposal failed: {inspect(reason)}`.
- **Why it matters:** these are the *most likely* failures (a paid, minute-long LLM call), and the recovery guidance is "read logs" + an Elixir tuple. That's exactly where trust is spent. (This is also the dashboard side of the CLI plan's `humanize_error/1` — build it shared.)
- **Fix:** map common reasons (no adapter, LLM unreachable, timeout, missing key) to a plain sentence + a Retry button; log the raw `inspect`, never render it.
- **Suggested command:** `/impeccable clarify`

**[P2] The primary empty state teaches nothing and is reused for scan failure.**
- **What:** `<p class="empty">No sessions matched.</p>` when `all_results == []` — names no scanned path, no `min_messages` threshold, no next step; and a scan crash also sets `all_results: []`, so a *failure* renders the same body under a separate error flash.
- **Why it matters:** first-run and failure both dead-end. (The *filtered*-empty state, by contrast, teaches and offers Clear — that's the bar to match.)
- **Fix:** "Faber scanned `~/.claude` and found no sessions with ≥N messages. Run an agent session, or lower `min_messages`." Give the crash state its own copy.
- **Suggested command:** `/impeccable onboard`

**[P3] Light-theme accent numbers fall just under AA.**
- **What:** light `--accent #9a6a0d` on `--bg #f6f7f9` ≈ 4.4:1; `.flash-info` accent text on its 0.1 tint ≈ 3.9:1. The 14px/600 `.col-friction` table number is normal size/weight, so 4.4:1 misses the 4.5 floor (the 1.45rem/700 detail friction clears the 3:1 large bar).
- **Why it matters:** the opt-in light theme fails the stated "signals held to AA" bar for its most important number.
- **Fix:** darken the light accent one notch (≈ `#8a5e0b`) or render the table friction number large/bold; darken `flash-info` text off the accent.
- **Suggested command:** `/impeccable colorize`

## Persona Red Flags

**Alex (impatient power user):** j/k/↑↓ nav is never advertised; a hard top-25 cap with no "show more" makes sessions 26+ unreachable though the full scan is in memory; no bulk propose/install; after arrow-selecting, focus is on `<body>` so acting needs the mouse (no hotkey); Rescan wipes filters + selection every time; typing in the Project search moves the table selection.

**Sam (accessibility):** cannot reach or operate row selection discoverably; combos never announce expanded state and lose focus to `<body>` on close; *all* in-context help is invisible to AT (tooltips are hover-only `::after` on non-focusable spans, the `?` is `aria-hidden`), so every definition — friction, events vs turns, T2, hot context — is unreachable by keyboard/SR. Wins to keep: dark contrast genuinely clears AA; buttons + search have `:focus-visible`; badges carry text, not color alone.

**Riley (stress tester):** refresh *during* a propose (before `Store.put`) loses the in-flight async — reopening shows the Propose button again, so a mid-flight refresh can **double-spend** the paid call (post-completion refresh is safe); 500 sessions → 25 shown, rest unreachable; "No sessions matched." dead-ends. Robust where it counts: overwrite is guarded, indices are parsed + bounds-checked, malformed input is ignored, the filtered-empty state teaches + offers Clear.

## Minor Observations

- `Errs`/`Ctx` headers lack the `data-tip` their neighbors carry.
- Native `confirm()` for propose/install is the one off-theme, OS-chrome jolt on an otherwise seamless dark surface.
- Under `prefers-reduced-motion`, the indeterminate progress bar gets `animation:none` and freezes as a static bar — decoration that no longer earns its place (the "~a minute" text still carries status).
- Selected-row background (`--panel` vs `--bg`, ΔL ≈ 0.004) is near-imperceptible; selection leans entirely on the gold `.proj-name` — weak in the full table.
- The `--heat` wash (`rgba(216,163,74,0.11)`) is so faint the "legible because it spans the row" claim is optimistic; rank # and friction number already encode magnitude, so it's subtle-redundant.
- `.detail-inner { min-width: 360px }` inside the morphing grid risks horizontal overflow during the tween on a narrow-but-≥720px viewport.
- On 461–719px, selecting a session hides the table entirely until "← All sessions."

## Questions to Consider

1. The thesis is "one worst session begging for a skill," but the landing view is a 12-column table. Should the tool be **opinionated by default** — lead with the single highest-friction session and its proposed skill, table as the "show me everything" drill-down?
2. j/k nav exists but rows aren't focusable and the keydown fights the search. Should the model **invert** — rows as first-class focusable list items (Linear/email register), table styling as progressive enhancement?
3. The guards are strong but ride on a blocking native `confirm()`. Is an OS dialog right for "a quiet diagnostic report," or does the brand call for an **inline commit with a 5-second undo**?
4. "Honest on inspection" is a stated principle, yet every definition lives in hover-only tooltips invisible to keyboard/SR. Should help be **inline expandable prose** instead of `::after` content?
