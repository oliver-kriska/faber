# `laws/` — the stack's non-negotiables (Iron Laws)

What goes here: the stack's hard rules, in a form that serves **two** roles — injected
into skill *generation* as constraints, and compiled into eval *checks* the eval gate
enforces.

For `faber-elixir`, these are the plugin's **Iron Laws** (26 of them: LiveView, Ecto,
Oban, Security, OTP, Verification, Code Style). Source: the "Iron Laws Enforcement"
section of the plugin's `CLAUDE.md`, also injected at runtime via the plugin's
`SubagentStart` hook.

Format: one law per file (markdown + yaml frontmatter): `id`, `category`, `severity`, a
human statement, and — where mechanizable — a `check` (pattern or matcher reference the
eval can run). Filled in M1.
