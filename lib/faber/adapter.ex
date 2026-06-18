defmodule Faber.Adapter do
  @moduledoc """
  **The adapter abstraction.** Load and validate a declarative adapter pack; the engine
  itself stays domain-free.

  An adapter supplies BOTH the *generation knowledge* (Iron Laws, investigation
  playbooks) AND the *stack-specific eval criteria* — the part a generic skill-creator
  cannot commoditize, because correct-for-Elixir ≠ correct-for-Rails (see `HANDOFF.md`
  §3). Adapters are purely declarative (yaml + markdown + prompt templates), so community
  authors write no host-language code.

  The pack layout and manifest schema are specified in `docs/ADAPTER_CONTRACT.md`. The
  reference adapter lives at `adapters/faber-elixir/`.

  Implemented in M1.
  """
end
