---
module: "Faber.CLI / FaberWeb.DashboardLive / Faber.Install"
date: "2026-07-17"
problem_type: security_issue
component: install_boundary
symptoms:
  - "`faber install <id>` on a stored HOOK wrote a bash script into `~/.claude/skills/<name>/SKILL.md` — the skill installer, with no eval gate, no script shown, and no confirm"
  - "the dashboard's `handle_event(\"install\", ...)` skill handler did the same: a hook proposal reached the agent install menu and was installed as a skill"
  - "a test artifact proved it in the tree — `tmp/faber_test_skills/no-masked-gate-exit/SKILL.md` was a bash script sitting in a skills directory"
  - "the review named two surfaces; the plan's own risk section demanded a third be ruled out, and there was one"
root_cause: "each install surface re-derived 'is this a skill?' locally instead of dispatching on the record's own `kind`, so every new surface silently re-implemented the assumption that a stored record is a skill. Fixing the two surfaces a review names leaves the class open — the defect is the missing dispatch, not its instances."
severity: critical
tags: [security, install-boundary, hooks, dispatch, class-vs-instance, code-review, audit-method]
related_solutions:
  - ".claude/solutions/2026-06-25-sync-pointer-over-claim-provenance.md"
---

# Enumerate the CLASS of callers, not the instances a review named

## Symptoms

Faber's store keeps hooks (executable bash) alongside skills (markdown). Three surfaces
turn a stored record into a file on disk. Each decided *what the record was* on its own:

- `faber install <id>` → `install_skill(record.name, record.md, opts)` unconditionally. A
  stored hook was written to `~/.claude/skills/<name>/SKILL.md` — a bash script in a skills
  dir, past the eval gate, past the show-the-script step, past the confirm.
- `DashboardLive.handle_event("install", ...)` → the same, from the browser.
- `Faber.Install.install/2` → `Keyword.put_new(:kind, p.kind)`, so an opts key could talk
  the veto out of the proposal's own kind.

The whole hook design rests on *the human is the boundary*: no hook is written without the
full script displayed and explicitly confirmed, because the safety veto is a blocklist over
"dangerous bash" and 7 of 8 hand-written bypass vectors walk straight past it. Every one of
those surfaces bypassed the boundary entirely.

## Investigation

1. **The review named two surfaces** — `faber install <id>` and the dashboard's hook path.
   Fixing exactly those two is what the previous cycle did with a sibling bug, and it shipped
   a blocker anyway.
2. **The plan's own risk section said so**, verbatim:
   > Biggest risk: fixing the instances, not the class — again. […] Before Phase A closes,
   > enumerate **every** caller that turns a stored record into a file and check each reads
   > `kind`. The dashboard and `faber install <id>` are two; **prove there is no third**.
3. **Ran an `Explore` audit against that question** rather than against the named surfaces.
   It found a third: `dashboard_live.ex`'s `handle_event("install", ...)` — the *skill*
   installer, distinct from the hook handler the review had flagged. Reproduced, fixed,
   mutation-tested.
4. **The plan's prose caught a bug the plan's own task list missed.** No task said "audit the
   skill handler"; the risk section's *question* is what found it.

## Root Cause

The record knows what it is — `record.kind` — and every surface re-derived it locally
instead. A local re-derivation is invisible to the next surface, so each new caller
re-implements the same wrong default ("a stored record is a skill") and no single fix can
reach them all. The instances are symptoms of a missing dispatch.

```elixir
# The problematic shape — three copies, one assumption, no dispatch
defp do_run(:install, opts) do
  case resolve_id(opts[:id]) do
    {:ok, record} -> install_skill(record.name, record.md, opts)   # <- always a skill
  end
end
```

## Solution

Dispatch on the record's own kind, at every surface, and make the skill path *refuse* a hook
loudly rather than fall through:

```elixir
defp install_record(%{kind: :hook} = record, opts), do: install_stored_hook(record, opts)
defp install_record(record, opts), do: install_skill(record.name, record.md, opts)

defp install_stored_hook(record, opts) do
  with :ok <- stored_hook_eval_gate(record),      # eval is a NECESSARY condition for a hook
       :ok <- confirm_stored_hook(record, opts) do  # show the script, THEN ask
    install_hook_bytes(record, opts[:force])
  else
    {:error, reason} -> refuse_hook_install("install", record.name, reason)
  end
end
```

Dashboard (the third surface) — a hook reaching the skill handler is now an explicit refusal:

```elixir
with :ok <- install_allowed?(),
     {:ok, idx} <- current_index(i, socket.assigns.proposal_i),
     :skill <- Map.get(proposal, :kind, :skill),   # <- THE THIRD SURFACE FIX
     ...
else
  :hook -> {:noreply, put_flash(socket, :error, install_refusal({:is_a_hook, proposal[:name]}))}
end
```

And the proposal's own kind became the fact, not a default:

```elixir
# Faber.Install — an opts key must not talk the veto out of the proposal's own kind
- Keyword.put_new(:kind, p.kind)
+ Keyword.put(:kind, p.kind)
```

Pre-format-3 records carry no `kind`; rather than defaulting them to `:skill` (which would
preserve the bug for every hook already on disk), `decode_kind/2` infers it from the
artifact's own bytes — the hook renderer guarantees `#!` on line 1, a SKILL.md opens with
`---`. **The artifact says what it is.**

### Files Changed

- `lib/faber/cli.ex:943` — `install_record/2` dispatch, `install_stored_hook/2`, eval gate, confirm
- `lib/faber_web/live/dashboard_live.ex:305` — the third surface; `install_refusal/1` messages
- `lib/faber/install.ex:107` — `put_new(:kind)` → `put(:kind)`
- `lib/faber/proposal/store.ex:415` — format 3 carries `kind`; `decode_kind/2` sniffs pre-3 bytes
- Commit: `c3faa78`

## Prevention

- **Convert the review's findings into a QUESTION about the class, then audit against the
  question.** "Which surfaces install a stored artifact?" found what "fix these two
  surfaces" could not. The previous cycle's audit asked about *the eval's* markdown
  assumptions and never asked this — and a blocker shipped.
- **When a value knows what it is, dispatch on it. Never re-derive per call site.** A local
  re-derivation is a copy of an assumption, and copies drift silently.
- **`put_new/3` on a security-relevant field is a smell.** It lets a caller-supplied default
  win over the subject's own fact.
- **Never default an unknown kind to the permissive branch.** Infer from the artifact, or
  refuse. `nil` read as "not a hook" is how this shipped.
- **A plan's risk section is executable.** Write the self-doubt down, then actually run it —
  here it was worth more than the task list.
- [x] Add to agent checks — a reviewer heuristic: for any `kind`/`type`/`role` field, grep
      every consumer and check each dispatches rather than assumes.
- [ ] Iron Law? Candidate: "dispatch on the subject's own kind; never re-derive it per call site."

## Related

- `.claude/solutions/2026-06-25-sync-pointer-over-claim-provenance.md` — same theme: track
  what Faber actually created rather than assuming ownership of a shared directory
- CLAUDE.md § "Generators & eval gates" — "Treat the user's dirs as shared"
