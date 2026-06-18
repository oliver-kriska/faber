defmodule Faber.Loop do
  @moduledoc """
  **Stage 5 — The loop.** Orchestrate the self-improving autoresearch cycle:
  generate → eval → keep-winner, with git-rollback, until the score plateaus.

  This is the optional improvement loop that runs *after* a skill clears the eval gate.
  It is OTP's home turf: a `Supervisor`/`GenServer` holds loop state, Oban schedules the
  "overnight ≠ interactive" runs, and the proven pattern is ported from the plugin's
  `lab/autoresearch/` (program + run-iteration + checks + JSONL journal).

  Implemented in M5.
  """
end
