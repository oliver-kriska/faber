defmodule Faber.Proposal do
  @moduledoc """
  A proposed skill — the output of `Faber.Propose` and the input to `Faber.Eval`.

  Carries the skill's content (name, description, body parts) plus its **provenance**: which
  friction finding and adapter produced it. Provenance is what lets the loop (M5) and any future
  audit trail explain *why* a skill was proposed.
  """

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          effort: String.t(),
          rationale: String.t(),
          iron_laws: [String.t()],
          usage: String.t() | nil,
          example: String.t() | nil,
          should_trigger: [String.t()],
          should_not_trigger: [String.t()],
          adapter: String.t() | nil,
          source: map()
        }

  defstruct name: nil,
            description: nil,
            effort: "medium",
            rationale: nil,
            iron_laws: [],
            usage: nil,
            example: nil,
            should_trigger: [],
            should_not_trigger: [],
            adapter: nil,
            source: %{}
end
