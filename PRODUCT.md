# Product

## Register

product

## Users

A developer who works with AI coding agents (Claude Code, Codex, Cline, Gemini,
OpenCode) every day and wants to know where those agents keep getting stuck.

Context of use: at their own machine, reviewing their **local** session history —
Faber reads `~/.claude` (and peers) read-only and never leaves loopback. Single
user, no auth, no team, no cloud, no telemetry. The person looking at the
dashboard owns the sessions on screen.

The job to be done: find the highest-friction sessions, understand *why* they were
rough (corrections, retry loops, context compactions…), and turn the recurring
pain into a reusable, eval-gated skill — without leaving the terminal/browser.

## Product Purpose

Faber mines real coding-agent transcripts for friction, ranks sessions by it, and
proposes stack-specific skills gated by an eval step. The dashboard is the
read-only human surface of that engine: **scan → read the ranked friction → propose
a skill for a session → copy/act, inline.**

Success is when the user can glance at the table and immediately see which sessions
were roughest and what would have helped, then act on the worst ones in place —
the dashboard as an accurate mirror of their own agent sessions, not a metrics
console to admire.

## Brand Personality

Precise, calm, considered. A quiet diagnostic **report**, not a dashboard that
shouts — the data does the talking and the chrome recedes. Confident restraint:
dark, legible, unhurried. Three words: **precise, calm, honest.**

## Anti-references

- **Generic SaaS dashboard** — identical card grids, gradient hero-metric tiles,
  purple/indigo gradients, rounded-everything, "engagement" theatrics.
- **Enterprise/corporate admin panel** — heavy toolbars, dense grey chrome, the
  2010s admin-panel look.
- **Consumer-app playful** — pastel/bubbly surfaces, big friendly illustrations,
  emoji-forward chrome.
- Stays **dark**: no cream/paper "editorial-light" background. Editorial here means
  restraint and hierarchy, not a bright magazine page.

## Design Principles

1. **The data is the interface.** Rank, friction, and signal carry the meaning;
   everything that isn't signal earns its place or goes. No decoration for its own
   sake.
2. **Calm over dense.** It's a report you read, not a terminal you scan under
   pressure. Breathing room, rhythm, and hierarchy beat maximal information
   density — even though the content is tabular.
3. **Obvious at a glance, honest on inspection.** The worst sessions and why should
   land in one look; detail (tooltips, inline expansion, the generated skill)
   rewards a closer read without cluttering the default view.
4. **Act in place.** Proposing and copying happen inline, where the session lives —
   not in a modal or a separate route. The surface is for deciding and acting, not
   navigating.
5. **Local-first candor.** Single-user, no auth, no persuasion, no growth metrics.
   The tool's only job is to tell you the truth about your own sessions.

## Accessibility & Inclusion

WCAG AA, pragmatic. Body text ≥4.5:1 against its background; large/bold text ≥3:1;
placeholders and muted labels held to the same bar (no light-gray-for-elegance).
Every animation (spinner, indeterminate progress, reveals) ships a
`prefers-reduced-motion` alternative. Controls are keyboard-usable. Signals are
never encoded by color alone — badges carry text (`PASS` / `below threshold`),
tier-2 uses a glyph, hot context is labelled by its value as well as its hue.
