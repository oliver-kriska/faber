---
module: "Faber.Install"
date: "2026-06-25"
problem_type: logic_error
component: cross_agent_pointer
symptoms:
  - "sync_pointer would list all 38 of the user's own skills in ~/.claude/skills as Faber-managed"
  - "the managed block injected into global ~/.claude/CLAUDE.md falsely claims Faber installed them"
  - "MCP faber_list_skills / faber_get_skill over-list, contradicting their own moduledocs"
root_cause: "the cross-agent pointer assumed a Faber-dedicated skills dir — it had no notion of provenance, so list_installed/1 (every */SKILL.md) was used where 'skills Faber installed' was meant"
severity: high
tags: [install, cross-agent, provenance, mcp, sync-pointer, shared-dir, privacy]
---

# sync_pointer over-claims the user's own skills in a shared dir

## Symptoms

Dogfooding the install path against the **real** `~/.claude/skills` (38 of the user's own skills,
many symlinked). `Faber.Install.sync_pointer/2` builds its managed block from `list_installed(dir)`,
which returns *every* `*/SKILL.md`. So syncing would inject a `# Faber-managed skills` block into the
user's **global `~/.claude/CLAUDE.md`** (loaded into every session) listing all 38 as Faber-managed.
The MCP `faber_list_skills`/`faber_get_skill` tools over-listed the same way — directly contradicting
their moduledocs ("skills Faber has installed").

## Investigation

1. **"Just sync it; the bug fix made it safe"** — no: verified empirically that
   `list_installed/0` → 38 entries on the real dir. Over-claim confirmed before any write.
2. **"Filter by a frontmatter `faber: true` key"** — pollutes the visible skill content and a copied
   file would carry a false claim. Rejected.
3. **"Install into a Faber-owned subdir"** — breaks Claude Code's `~/.claude/skills/*` auto-discovery.
   Rejected.
4. **Root cause**: the feature assumed a Faber-*dedicated* dir; it had no provenance.

## Root Cause

No way to distinguish skills Faber installed from the user's own when the skills dir is shared (the
default `~/.claude/skills` is *not* Faber-dedicated). `list_installed/1` is a generic "all skills in
dir" primitive, but it was used where "skills Faber installed" was meant.

```elixir
# BEFORE — lists EVERY skill in the (shared) dir
body = render_pointer_body(list_installed(opts[:dir] || default_dir()))
```

## Solution

An **install-provenance marker**: `install/2` drops a `.faber.json` sentinel beside each `SKILL.md`.
`list_faber_installed/1` filters `list_installed/1` to marked dirs; `sync_pointer`, `check_pointer`,
and both MCP tools use it. `list_installed/1` stays the generic primitive.

```elixir
defp write_marker(skill_dir, name, opts) do
  data = Map.merge(%{"installed_by" => "faber", "name" => name}, opts[:provenance] || %{})
  File.write(Path.join(skill_dir, @marker), Jason.encode!(data) <> "\n")
end

def list_faber_installed(dir \\ default_dir()),
  do: dir |> list_installed() |> Enum.filter(&faber_installed?/1)
```

Privacy note: a `%Proposal{}` install records `adapter`/`source_session`/`fingerprint` but **never**
the transcript `path` (the moat keeps internal transcript locations out of any projection). Verified
on the real dir: `list_faber_installed` → `["context-budget"]` while `list_installed` → 39.

### Files Changed

- `lib/faber/install.ex` — `@marker`, `write_marker/3`, `list_faber_installed/1`, `faber_installed?/1`;
  `sync_pointer`/`check_pointer` switched to the filtered list.
- `lib/faber/mcp/tools/list_skills.ex`, `get_skill.ex` — use `list_faber_installed/0`.
- Commit `5d1032d`.

## Prevention

- [x] Add to test patterns — a user-owned (unmarked) skill in the dir must be neither listed nor
      counted as drift.
- [ ] When a feature writes into a directory the user also owns (CLAUDE.md, skills, hooks), assume it
      is **shared**: track provenance for what you created; never enumerate-and-claim the whole dir.
- Specific guidance: "Keep a generic 'list everything' primitive AND a provenance-filtered view;
  point user-facing/foreign-config writers at the filtered one."

## Related

- `.claude/solutions/2026-06-25-eval-clarity-proposer-renderer-gap.md` — the other root cause the same
  dogfooding session surfaced.
- `.claude/research/2026-06-25-dogfood-real-history.md` — full log.
