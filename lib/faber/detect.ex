defmodule Faber.Detect do
  @moduledoc """
  **Stage 2 — Detect.** Score friction and repetition over ingested sessions to surface
  candidate workflows worth automating.

  Detection combines **generic** signatures (repeated tool sequences, retry loops,
  failure clusters) with **adapter-supplied** signatures specific to a stack (see an
  adapter's `detect/` directory). The output is a ranked set of friction findings that
  feed the skill proposer.

  Workload is I/O-bound concurrent fan-out — `Task.async_stream` territory.

  Implemented in M2.
  """
end
