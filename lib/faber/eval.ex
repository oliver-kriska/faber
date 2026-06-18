defmodule Faber.Eval do
  @moduledoc """
  **Stage 4 — Eval gate.** Judge a proposed skill before it is presented or installed.

  Evaluation has three layers: structural checks, trigger-accuracy scoring, and the
  **adapter's stack-specific criteria**. The optimizer/eval ecosystem is Python, so this
  stage composes rather than rebuilds: the v1 boundary shells out to the Python sidecar
  (`python -m faber_eval`, JSON in / JSON out) which ports the plugin's `lab/eval`
  matchers and wraps GEPA. Embedded CPython (Pythonx) is evaluated later.

  Implemented in M4.
  """
end
