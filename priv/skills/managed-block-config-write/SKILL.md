---
name: managed-block-config-write
description: "Idempotently inject tool-owned content into a USER-OWNED shared config file (CLAUDE.md / AGENTS.md / dotfiles / rc files) without ever clobbering the user's own text. Use when a tool must write into a file it doesn't exclusively own — a self-delimiting digest-guarded managed block that upserts in place, detects hand-edits, and refuses to overwrite them without force. Pairs with a per-artifact provenance marker so the tool can tell its own writes from the user's."
effort: low
argument-hint: ""
allowed-tools:
---

# Managed-Block Config Write

When a tool must write into a file the **user owns and also edits** (`CLAUDE.md`,
`AGENTS.md`, a dotfile), appending blindly corrupts it and rewriting it destroys the user's
text. The fix is a **self-delimiting, digest-guarded managed block**: the tool owns the
bytes *between its markers* and nothing else.

```
<!-- FABER:BEGIN sha256:<digest> -->
<body>
<!-- FABER:END -->
```

## Iron Laws - Never Violate These

1. **Own only the bytes between your markers.** Replace the block **in place** (preserving
   surrounding text); append after a blank line only when no block exists. Never rewrite the
   whole file.

2. **Be idempotent.** Upserting the same body must yield byte-identical output, so re-running
   is a no-op and diffs stay clean.

3. **Record a digest of the body in the marker; never clobber a hand-edited block without
   `force`.** Compute the digest at write time. If the current body no longer matches its
   recorded digest, the user edited it — `tampered?/1` is true → refuse to overwrite (return
   `{:error, :block_modified}`) unless explicitly forced.

4. **Keep the mechanism pure (no I/O).** All the marker/digest/upsert logic is string→string,
   so it's fully unit-testable; do file reads/writes only in a thin outer layer.

5. **Distinguish your writes from the user's with a separate provenance marker.** A shared dir
   (e.g. `~/.claude/skills`) holds the user's own artifacts too — stamp each tool-created one
   (a hidden `.faber.json` sidecar) and filter on it, so you never enumerate-and-claim the
   user's content as your own.

## Usage

```
# Upsert is the entry point; states map to: in_sync (no-op), drift (rewrite),
# modified (refuse without force), absent (append).
```

## Workflow

```elixir
# Pure core (string -> string). digest over the TRIMMED body.
def digest(body) do
  :sha256 |> :crypto.hash(String.trim(body)) |> Base.encode16(case: :lower) |> binary_part(0, 12)
end

def render(body) do
  b = String.trim(body)
  "<!-- FABER:BEGIN sha256:#{digest(b)} -->\n#{b}\n<!-- FABER:END -->"
end

# Replace in place (Law 1) — function replacement, NOT a pattern string, so body text
# containing \0/\1 isn't treated as a backreference. Append only when absent.
def upsert(content, body) do
  block = render(body)
  if has_block?(content),
    do: Regex.replace(@block_re, content, fn _ -> block end),
    else: append(content, block)
end

# in_sync? compares the ACTUAL body to the new body (not the marker digest), so a hand-edited
# block reads as out-of-sync rather than falsely in-sync.
def in_sync?(content, body) do
  case extract(content) do
    {:ok, %{body: cur}} -> digest(cur) == digest(body)
    :none -> false
  end
end

# tampered? = body no longer matches the digest recorded in its own marker (user hand-edited).
def tampered?(content) do
  case extract(content) do
    {:ok, %{body: body, digest: recorded}} -> digest(body) != recorded
    :none -> false
  end
end
```

```elixir
# Thin I/O layer: the four states drive the decision.
def install_pointer(file, body, opts) do
  existing = if File.exists?(file), do: File.read!(file), else: ""
  cond do
    in_sync?(existing, body) -> {:ok, :unchanged}                                    # no-op
    tampered?(existing) and not opts[:force] -> {:error, :block_modified}            # refuse (Law 3)
    true -> File.write(file, upsert(existing, body)); {:ok, :written}                # write/rewrite
  end
end
```

## Patterns

- **A read-only `check` counterpart** returns `:in_sync | :drift | :modified | :absent` and
  never writes — useful for a status/doctor command.
- **The digest is short** (12 hex chars of sha256) — enough to detect edits, compact in the
  marker. Always digest the *trimmed* body on both sides so whitespace noise doesn't cause
  false drift.
- The same shape extends to any rc/config file: `.gitconfig` include blocks, shell rc snippets,
  editor settings — anywhere a tool co-edits a user-owned file.

## References

- Faber: `lib/faber/install/managed_block.ex` (pure core) + `lib/faber/install.ex`
  (`sync_pointer/2`, `check_pointer/2`, `.faber.json` provenance marker).
- Provenance principle: `.claude/solutions/2026-06-25-sync-pointer-over-claim-provenance.md`.
