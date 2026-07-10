defmodule Faber.Detect do
  @moduledoc """
  **Stage 2 — Detect.** Score friction over a session's normalized events.

  The public facade for the four detection domains — the algorithms live in one module per
  domain, all faithful ports of the reference plugin's `session-scan`
  (`scoring-guide.md` / `compute-metrics.py`):

    * `Faber.Detect.Friction` — the generic friction score (weighted signals → sigmoid)
    * `Faber.Detect.Fingerprint` — session-type classification + tool profile
    * `Faber.Detect.Opportunity` — missed-automation scoring
    * `Faber.Detect.Context` — context-window pressure (peak prompt fill %)

  Detection is agent-level (it reads normalized transcript shapes), not stack-specific; an
  adapter's `detect/` signatures layer **on top** of this baseline. The adapter-overridable
  vocab (contract §4.1) is resolved here — `fingerprint_rules/1`, `opportunity_rules/1`,
  `skill_namespaces/1` — so the domain modules stay policy-free.

  `analyze/2` runs all four domains over ONE traversal of the session's tool calls; the
  per-domain functions remain for callers that need a single analysis.
  """

  alias Faber.Adapter
  alias Faber.Detect.Context
  alias Faber.Detect.Fingerprint
  alias Faber.Detect.Friction
  alias Faber.Detect.Opportunity

  # ── adapter-overridable detection vocab (contract §4.1) ─────────────────────
  #
  # These three module attributes are the engine's **stack-neutral defaults**, applied ONLY when
  # `Scan` runs adapter-free. When an adapter is selected it supplies its own vocab via
  # `detect/signatures.yaml` (`fingerprint_rules` / `opportunity_rules` / `skill_namespaces` on
  # the `Faber.Adapter`). The engine carries NO stack-specific vocabulary — the historical
  # Elixir/plugin command bonuses (`mix`/`gh`/Tidewave) and `phx|ecto|lv` namespaces live in
  # the reference adapter `faber-elixir` (`detect/signatures.yaml`).

  # Command/tool → session-type bonuses are inherently stack vocabulary, so adapter-free there
  # are none (only the generic tool-ratio/keyword fingerprinting applies).
  @default_fingerprint_rules []

  # Missed-automation → suggested skill rules, in report order — only the conditions that need
  # no stack vocabulary (retry loops and tool counts). See `Faber.Detect.Opportunity` for the
  # `when` semantics. `unless_used: false` (investigate) suggests even when already used.
  @default_opportunity_rules [
    %{skill: "investigate", when: :retry_loops, commands: [], threshold: nil, unless_used: false},
    %{skill: "plan", when: :tool_count, commands: [], threshold: 50, unless_used: true},
    %{skill: "review", when: :edit_count, commands: [], threshold: 10, unless_used: true}
  ]

  # Namespace prefixes scanned as `(?:ns):skill` in session text to detect skills already used —
  # stack-specific by nature, so none adapter-free (Skill tool calls and `attributionSkill`
  # detection still work; only the text-regex extraction is namespace-driven).
  @default_skill_namespaces []

  @type signals :: Friction.signals()
  @type friction :: Friction.friction()
  @type fingerprint :: Fingerprint.fingerprint()
  @type opportunity :: Opportunity.opportunity()
  @type context :: Context.context()

  @type analysis :: %{
          friction: friction(),
          fingerprint: fingerprint(),
          opportunity: opportunity(),
          context: context(),
          tool_uses: [map()]
        }

  @doc """
  Run all four detection domains over a session's events in one pass.

  The session's `tool_uses` and Bash commands are extracted ONCE and shared across the
  domains (each per-domain entry point would otherwise rebuild them from the events). The
  extracted `tool_uses` are returned so callers (`Faber.Scan.score_session/2`) can derive
  further per-tool data without another traversal.
  """
  @spec analyze(Enumerable.t(), Adapter.t() | nil) :: analysis()
  def analyze(events, adapter \\ nil) do
    events = Enum.to_list(events)
    tool_uses = Enum.flat_map(events, & &1.tool_uses)
    bash_cmds = bash_commands(tool_uses)

    %{
      friction: Friction.friction(events, tool_uses),
      fingerprint: Fingerprint.fingerprint(events, adapter, tool_uses, bash_cmds),
      opportunity: Opportunity.opportunity(events, adapter, tool_uses, bash_cmds),
      context: Context.context(events),
      tool_uses: tool_uses
    }
  end

  @doc """
  Compute the friction score (and its component signals) for a session's events.
  See `Faber.Detect.Friction` for the algorithm, signals, and weights.
  """
  defdelegate friction(events), to: Friction

  @doc """
  Tool-usage profile: percentage breakdown of tool calls by category.
  """
  defdelegate tool_profile(events), to: Fingerprint

  @doc """
  Classify the session type — `bug-fix` / `feature` / `exploration` / `maintenance` /
  `review` / `refactoring` (or `unknown`) — with a confidence in 0.0–1.0.

  Port of `compute_fingerprint`: keyword matches over the first 10 human messages (×2.0
  each) plus tool-profile, files-edited, Tidewave, and **command-bonus rules**. Confidence =
  winning score / total score.

  `adapter` (a `Faber.Adapter` or `nil`) supplies the command/tool-bonus rules. When `nil`
  there are none (the engine defaults are stack-neutral) — only the generic keyword and
  tool-ratio fingerprinting applies.
  """
  defdelegate fingerprint(events, adapter \\ nil), to: Fingerprint

  @doc """
  Score missed automation opportunities (0.0–1.0) and list the skills that could have
  helped but weren't used.

  Port of `compute_plugin_opportunity`, generalized to **rules**: each rule maps a friction
  condition (`when`) to a suggested skill. The stack-neutral defaults keep only the rules
  needing no command vocabulary — retry loops → `investigate`; >50 tools without `plan` →
  `plan`; >10 edits without `review` → `review`. score = min(n×0.2, 1.0).

  `adapter` (a `Faber.Adapter` or `nil`) supplies the rules and the skill namespaces used to
  detect already-used skills; the historical `verify`/`pr-review` command rules live in the
  faber-elixir pack. Skills already used (Skill calls, `attributionSkill`, `/ns:cmd` in text)
  are excluded unless a rule sets `unless_used: false`.
  """
  defdelegate opportunity(events, adapter \\ nil), to: Opportunity

  @doc """
  Context pressure: the peak prompt-token fill as a percentage of the model's context window.
  `nil` when there's no usage data or the window is unknown. See `Faber.Detect.Context`.
  """
  defdelegate context(events), to: Context

  # ── shared intermediates + vocab accessors (used by the domain modules) ─────

  @doc """
  The Bash command strings among a session's tool calls — a shared intermediate the
  fingerprint/opportunity domains (and `analyze/2`) reuse.
  """
  @spec bash_commands([map()]) :: [String.t()]
  def bash_commands(tool_uses) do
    tool_uses
    |> Enum.filter(&(&1.name == "Bash"))
    |> Enum.map(fn tu -> to_string(tu.input["command"] || "") end)
  end

  # `nil` adapter ⇒ the stack-neutral engine defaults. An adapter that IS selected owns its
  # detection vocab verbatim — including an empty list, which means "none for this stack"
  # (e.g. a stack with no skill namespaces).

  @doc false
  @spec fingerprint_rules(Adapter.t() | nil) :: [map()]
  def fingerprint_rules(nil), do: @default_fingerprint_rules
  def fingerprint_rules(%Adapter{fingerprint_rules: rules}), do: rules

  @doc false
  @spec opportunity_rules(Adapter.t() | nil) :: [map()]
  def opportunity_rules(nil), do: @default_opportunity_rules
  def opportunity_rules(%Adapter{opportunity_rules: rules}), do: rules

  @doc false
  @spec skill_namespaces(Adapter.t() | nil) :: [String.t()]
  def skill_namespaces(nil), do: @default_skill_namespaces
  def skill_namespaces(%Adapter{skill_namespaces: namespaces}), do: namespaces
end
