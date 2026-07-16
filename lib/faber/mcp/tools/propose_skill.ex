defmodule Faber.MCP.Tools.ProposeSkill do
  @moduledoc """
  Propose a new skill for one ranked friction finding, gate it through the stack-specific eval, and
  optionally install it. **This calls an LLM, so it spends tokens** (unlike the read-only tools) — it
  is therefore **opt-in**: disabled unless `config :faber, :mcp_allow_propose` is true, returning a
  structured error that explains how to enable it.

  Pick the finding by `rank` (1-based, matching `faber_search_friction`'s order under the same
  ranking). The skill is generated keylessly (the configured `Faber.LLM`, `claude -p` by default),
  scored by the adapter's eval bar, and — when `install: true` and it **passes** the gate — written
  to the skills dir with a Faber provenance marker. Returns the proposal's name/description, the
  composite score + per-dimension breakdown, whether it passed, the install outcome, and the full
  rendered `SKILL.md`. Only generated content + aggregates are returned — never raw transcript text.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias Faber.{Adapter, Eval, Install, Propose, Scan}

  schema do
    field(:rank, :integer,
      description:
        "Which friction finding to propose for: 1-based position in faber_search_friction's " <>
          "ranking. Default 1 (the worst offender)."
    )

    field(:rank_by, :string,
      description:
        "Ranking strategy used to resolve `rank`; must match the faber_search_friction call. " <>
          "'raw' (default) = total friction; 'rate' = friction per message."
    )

    field(:install, :boolean,
      description:
        "If true, install the skill into the skills dir — but only when it PASSES the eval gate. " <>
          "Default false (propose + score only; nothing is written)."
    )

    field(:force, :boolean,
      description:
        "Bypass the stack gate (propose even if the session doesn't match this adapter's stack). " <>
          "Default false."
    )

    field(:model, :string,
      description: "Optional model for the keyless generation (e.g. \"sonnet\", \"opus\")."
    )
  end

  @impl true
  def execute(params, frame) do
    if allowed?() do
      run(params, frame)
    else
      {:reply, Response.error(Response.tool(), disabled_message()), frame}
    end
  end

  defp run(params, frame) do
    rank = rank(params[:rank])

    with {:ok, adapter} <- load_adapter(),
         {:ok, result} <- find_at_rank(rank, params[:rank_by]),
         :ok <- stack_gate(adapter, result, params[:force]),
         {:ok, proposal} <- propose(result, adapter, params[:model]),
         {:ok, eval} <- Eval.score(proposal, adapter: adapter) do
      skill_md = Propose.render_skill_md(proposal, adapter)
      installed = maybe_install(proposal, adapter, params[:install], eval.passed)

      payload = %{
        rank: rank,
        session_id: result.session_id,
        fingerprint: result.fingerprint,
        name: proposal.name,
        description: proposal.description,
        composite: eval.composite,
        threshold: eval.threshold,
        passed: eval.passed,
        dimensions: dimension_scores(eval.dimensions),
        installed: installed,
        skill_md: skill_md
      }

      {:reply, Response.json(Response.tool(), payload), frame}
    else
      {:error, reason} -> {:reply, Response.error(Response.tool(), error_message(reason)), frame}
    end
  end

  # ── opt-in gate ────────────────────────────────────────────────────────────

  defp allowed?, do: Application.get_env(:faber, :mcp_allow_propose, false) == true

  defp disabled_message do
    "faber_propose_skill is disabled because it calls an LLM and spends tokens. Enable it with " <>
      "`config :faber, :mcp_allow_propose, true`. The read-only tools (faber_search_friction, " <>
      "faber_list_skills, faber_get_skill) need no opt-in."
  end

  # ── pipeline steps (mirror the CLI propose path) ───────────────────────────

  defp load_adapter do
    case Adapter.load(Faber.adapter_dir()) do
      {:ok, adapter} -> {:ok, adapter}
      {:error, reason} -> {:error, {:adapter, reason}}
    end
  end

  defp find_at_rank(rank, rank_by) do
    opts = Keyword.merge(scan_opts(), rank_by: rank_by(rank_by))

    case Enum.at(Scan.run(opts), rank - 1) do
      %Scan.Result{} = result -> {:ok, result}
      nil -> {:error, {:no_finding, rank}}
    end
  end

  # Don't propose an off-stack skill unless forced — the same guard as `faber propose` and the
  # dashboard, and now literally the same function. This was a third copy of the decision, which is
  # the failure `Faber.Propose.stack_gate/3` exists to prevent: a gate each caller re-implements is
  # a gate the next caller forgets. `!!force` because `params[:force]` is `true | nil` and the spec
  # says `boolean()`.
  defp stack_gate(adapter, result, force), do: Propose.stack_gate(adapter, result, !!force)

  # Keyless by default (the configured Faber.LLM is `claude -p`); a `model` param overrides.
  defp propose(result, adapter, model) do
    opts = if model in [nil, ""], do: [], else: [model: model]

    case Propose.propose(result, adapter, opts) do
      {:ok, proposal} -> {:ok, proposal}
      {:error, reason} -> {:error, {:propose, reason}}
    end
  end

  # Install ONLY on an explicit request AND a passing gate — never write a sub-threshold skill.
  defp maybe_install(_proposal, _adapter, install, _passed) when install != true,
    do: false

  defp maybe_install(_proposal, _adapter, _install, false),
    do: "skipped: did not pass the eval gate"

  defp maybe_install(proposal, adapter, _install, true) do
    case Install.install(proposal, adapter: adapter) do
      {:ok, path} -> path
      {:error, {:exists, path}} -> "exists: #{path} (not overwritten)"
      {:error, reason} -> "install failed: #{inspect(reason)}"
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp scan_opts, do: Application.get_env(:faber, :mcp_scan_opts, [])

  defp rank(nil), do: 1
  defp rank(n) when is_integer(n) and n < 1, do: 1
  defp rank(n) when is_integer(n), do: n
  defp rank(_), do: 1

  defp rank_by("rate"), do: :rate
  defp rank_by(_), do: :raw

  # `eval.dimensions` is always a map, so there's no non-map fallback clause — a shape change
  # should fail loudly here rather than silently report an empty dimension set.
  defp dimension_scores(dimensions) when is_map(dimensions) do
    Map.new(dimensions, fn {name, dim} -> {name, round3(dim["score"])} end)
  end

  defp round3(n) when is_number(n), do: Float.round(n * 1.0, 3)
  defp round3(_), do: nil

  defp error_message({:adapter, reason}),
    do: "Could not load the adapter: #{inspect(reason)}."

  defp error_message({:no_finding, rank}),
    do:
      "No friction finding at rank #{rank}. Call faber_search_friction to see available findings."

  # Cites the evidence, like the CLI's refusal and the dashboard's badge — from the same
  # `touched_extensions/1`, so all three quote the same numbers. "doesn't match the Elixir stack"
  # invites an argument; ".go×74, .md×30" ends it.
  defp error_message({:stack_mismatch, adapter, result}) do
    # `"none"` and not an empty string: a session CAN touch no extension-bearing file (`file_paths:
    # []` is a real Scan.Result shape), and "It touched ." is worse than saying so. Mirrors the
    # CLI's refusal, which guards the same way.
    exts =
      case Propose.touched_extensions(result) do
        [] -> "no files"
        pairs -> Enum.map_join(pairs, ", ", fn {ext, n} -> "#{ext}×#{n}" end)
      end

    "This session doesn't match the #{adapter.name} stack, so a #{adapter.name} skill would be " <>
      "off-target. It touched #{exts}. Pass force: true to propose anyway."
  end

  defp error_message({:propose, reason}),
    do:
      "Skill generation failed (#{inspect(reason)}). The keyless backend needs the `claude` CLI " <>
        "on PATH; check that it's installed."

  defp error_message(reason), do: "faber_propose_skill failed: #{inspect(reason)}"
end
