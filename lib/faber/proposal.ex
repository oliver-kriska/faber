defmodule Faber.Proposal do
  @moduledoc """
  A proposed artifact — the output of `Faber.Propose` and the input to `Faber.Eval`.

  Carries the artifact's content (name, description, body parts) plus its **provenance**: which
  friction finding and adapter produced it. Provenance is what lets the loop (M5) and any future
  audit trail explain *why* it was proposed.

  ## `kind` — which artifact this is

  A proposal is a **skill** (the original and overwhelmingly common case) or a **hook**. `kind`
  defaults to `:skill`, which makes every pre-existing path an identity: the 13 skill fields keep
  their meaning, `filename/1` still answers `SKILL.md`, and the whole existing suite passes with
  zero fixture changes. That identity is the design constraint, not a happy accident — if adding a
  kind required touching skill behavior, the default would be wrong.

  The two kinds populate disjoint halves of the struct. A skill fills the skill vocabulary
  (`iron_laws`, `workflow`, `patterns`, `should_trigger`, …) and leaves `event`/`matcher`/`script`
  nil. A hook fills those three and leaves most of the skill vocabulary empty — it is a
  `settings.json` pointer plus a script, not prose with frontmatter. `name`, `description`,
  `rationale`, `adapter` and `source` are the fields both genuinely share.
  """

  @typedoc "The artifact a proposal renders into. `:skill` is the default and the identity case."
  @type kind :: :skill | :hook

  @type t :: %__MODULE__{
          kind: kind(),
          name: String.t(),
          description: String.t(),
          effort: String.t(),
          rationale: String.t(),
          iron_laws: [String.t()],
          usage: String.t() | nil,
          example: String.t() | nil,
          workflow: [String.t()],
          patterns: [String.t()],
          should_trigger: [String.t()],
          should_not_trigger: [String.t()],
          event: String.t() | nil,
          matcher: String.t() | nil,
          script: String.t() | nil,
          adapter: String.t() | nil,
          source: map()
        }

  defstruct kind: :skill,
            name: nil,
            description: nil,
            effort: "medium",
            rationale: nil,
            iron_laws: [],
            usage: nil,
            example: nil,
            # Ordered imperative steps + idiom/anti-pattern lines. Optional, but populating them is
            # what gives a skill its actionable density (clarity) — see Faber.Propose.
            workflow: [],
            patterns: [],
            should_trigger: [],
            should_not_trigger: [],
            # ── hook vocabulary (`kind: :hook`); nil for skills ──────────────────────────────
            # The Claude Code hook event (`"PreToolUse"`) and tool matcher (`"Bash"`) — together the
            # `settings.json` pointer — plus the script body that runs. See `Faber.Install.Hook`.
            event: nil,
            matcher: nil,
            script: nil,
            adapter: nil,
            source: %{}

  @doc """
  The on-disk filename this proposal's artifact is written as.

  The one place the artifact filename is decided. It used to be the literal `"SKILL.md"` spelled
  out at five write seams (install, exec-in-place eval, the mix task, the dashboard); each was a
  place a second kind would have silently written a skill-shaped path.

  Takes a proposal or a bare `kind`, since some callers (the dashboard's assigns) carry the kind
  without the struct.

      iex> Faber.Proposal.filename(%Faber.Proposal{})
      "SKILL.md"

      iex> Faber.Proposal.filename(%Faber.Proposal{kind: :hook})
      "hook.sh"

      iex> Faber.Proposal.filename(:hook)
      "hook.sh"
  """
  @spec filename(t() | kind()) :: String.t()
  def filename(%__MODULE__{kind: kind}), do: filename(kind)
  def filename(:skill), do: "SKILL.md"
  def filename(:hook), do: "hook.sh"
end
