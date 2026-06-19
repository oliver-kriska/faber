defmodule Faber do
  @moduledoc """
  Faber — a local-first, cross-agent, stack-aware improvement engine for AI coding agents.

  Faber mines your real coding-agent sessions for repetitive, painful workflows, then
  generates **skills** that automate them — but only skills that a stack-specific
  **adapter** vouches for and that pass an **evaluation gate**. Over time it runs a
  self-improving loop to make those skills better.

  > *"It mines your sessions for pain and emits skills your stack's expert adapter vouches for."*

  This module is the public entry point. The pipeline is split across contexts that map
  one-to-one onto the loop stages (see `HANDOFF.md` §7):

    * `Faber.Ingest`  — parse coding-agent session transcripts into a normalized form.
    * `Faber.Detect`  — score friction / repetition (generic + adapter signatures).
    * `Faber.Adapter` — load the declarative adapter pack (laws, eval criteria, templates).
    * `Faber.Eval`    — gate proposed skills via the Python eval sidecar.
    * `Faber.Loop`    — the autoresearch loop: generate → eval → keep-winner, until plateau.

  See `HANDOFF.md` for the full product thesis, architecture decision, and milestones.
  """

  @default_adapter "faber-elixir"

  @doc """
  Resolve the reference adapter directory, working both from the repo and from a packaged release.

  Order: explicit `config :faber, :adapter_dir` → the release root (`RELEASE_ROOT`, where the
  single binary unpacks the bundled `adapters/`) → the repo-relative `adapters/<name>` for dev/test.
  """
  @spec adapter_dir(String.t()) :: Path.t()
  def adapter_dir(name \\ @default_adapter) do
    cond do
      dir = Application.get_env(:faber, :adapter_dir) -> dir
      root = System.get_env("RELEASE_ROOT") -> Path.join([root, "adapters", name])
      true -> Path.join("adapters", name)
    end
  end
end
