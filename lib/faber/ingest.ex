defmodule Faber.Ingest do
  @moduledoc """
  **Stage 1 — Ingest.** Parse coding-agent session transcripts into a normalized,
  engine-internal representation.

  The v1 target is Claude Code (`~/.claude/projects/**/*.jsonl`); Codex / OpenCode / Pi
  follow later behind the same normalized shape. Ingest reads the *real* transcript —
  tool calls, failures, repetition — not a shallow `/insights` report. That depth is one
  of the two ends Faber owns (see `HANDOFF.md` §3).

  Implemented in M2.
  """
end
