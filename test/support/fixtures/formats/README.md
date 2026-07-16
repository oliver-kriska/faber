# Golden format fixtures

Frozen on-disk artifacts in formats Faber **no longer writes** but must still **read**.

## Why these are files, not `assert`s

A hand-written assertion that "v1 parses" tests the parser against the test author's memory of v1.
A frozen v1 *file* tests the contract. The difference is not academic: `Faber.Proposal.Store`
shipped a reader that matched `%{"format" => @format}` exactly, which silently ate every v1 record
the moment v2 shipped — in the one module whose entire purpose is that paid work survives
(fixed in `e223c8b`; the class is now prevented at compile time by `Faber.Store.Format`).

**Never regenerate these to make a test pass.** They are the historical record. If a change makes
one of them fail to read, the change is wrong — or the records are genuinely gone from every real
disk, which is a deliberate decision made in public, not a fixture edit.

## `proposal-v1.json`

A format-1 `Faber.Proposal.Store` record. **Captured by executing the real format-1 encoder** —
`lib/faber/proposal/store.ex` as it shipped at `eec06b7`, checked out of git, renamed, and run —
not written by hand. Writing it by hand to match the format-2 reader's expectations would have
tested the reader against itself.

That matters here, and the file shows why: a v1 record has **no `outcome` and no `source_sessions`
keys at all** (both arrived with format 2), and it carries `"session_path": null` /
`"session_stamp": null` rather than omitting them. A hand-written fixture would plausibly have
included the v2 keys or dropped the nulls, and would have proved nothing about v1.

`Faber.Proposal.Store` declares `unstamped: :unreadable` precisely because this file exists:
format 1 stamped `"format": 1` from its very first record, so a proposal file with no version did
not come from Faber.

## `marker-v0.json`

A `.faber.json` provenance marker from **before the marker declared a format at all** — the shape
`Faber.Install.write_marker/3` wrote at `1e18f2a` and earlier. Its key set was read back out of git
rather than recalled; its defining property is the **absence** of `format`.

Unlike the proposal store, markers like this are on real disks (Oliver's `~/.claude` included) with
no version key, because they predate it. That is why `Faber.Install` declares `unstamped: 1`: a
reader that demanded `format` would return `%{}` for every one of them and disown every skill Faber
ever installed — dropping them from the cross-agent pointer, the MCP listing, and the dashboard's
already-installed badge, in a single release.

The same rule applies to `Faber.Loop.Journal` (`unstamped: 1`), whose pre-versioning lines are
covered inline in `test/faber/loop/journal_test.exs` rather than by a file — a journal line is one
JSON object with no non-obvious historical shape to freeze.
