defmodule Faber.MCP.Tools.ProposeHook do
  @moduledoc """
  Propose a **hook** for one mined frictionless hazard, gate it through the hook eval, and
  optionally install it. The hazard sibling of `Faber.MCP.Tools.ProposeSkill`, and opt-in under the
  same `:mcp_allow_propose` flag for the same reason: it calls an LLM and spends tokens.

  ## Why a separate tool rather than a `kind` param on `faber_propose_skill`

  The two share no input. That tool selects by **rank** in a friction ranking; this one selects by
  **hazard class**, which is orthogonal to that ranking by construction — the motivating session
  scores `0.0` friction and would never place. Folding them together would mean a tool whose
  `rank` is meaningless half the time and whose `hazard` is meaningless the other half, described
  to a model that has to guess which. Two tools, two honest descriptions.

  Call `faber_search_friction` to see what is there (each finding carries a `hazards` list); the one
  class Faber detects today is `pipe_masks_exit`. Returns the proposal's name/description, the
  hook's pointer (event + matcher), the composite + per-dimension scores, the install outcome, and
  the rendered script.

  This tool returns the hazard's `evidence` — which quotes the offending command — where
  `faber_search_friction` deliberately does not: writing a hook means sending that command to an
  LLM, so the user asking for one has asked for exactly that. Nothing else from the transcript
  crosses.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias Faber.{Adapter, Eval, Install, Propose, Scan}
  alias Faber.Detect.Hazard

  schema do
    field(:hazard, :string,
      description:
        "Which hazard class to write a hook for. Today: 'pipe_masks_exit' (a gate command piped " <>
          "into a filter, so the shell reports the filter's exit code and the gate can fail " <>
          "while the pipeline reports success). Default 'pipe_masks_exit'."
    )

    field(:install, :boolean,
      description:
        "If true, install the hook — but only when it PASSES the eval gate: the script into the " <>
          "Faber hooks dir, plus one pointer in settings.json. Default false (propose + score " <>
          "only; nothing is written)."
    )

    field(:force, :boolean,
      description:
        "Bypass the stack gate, and adopt a settings.json pointer you have hand-edited. Does " <>
          "NOT override the safety veto — nothing does. Default false."
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
    kind = kind(params[:hazard])

    with {:ok, adapter} <- load_adapter(),
         {:ok, result, hazard} <- find_hazard(kind),
         :ok <- Propose.stack_gate(adapter, result, !!params[:force]),
         {:ok, proposal} <- propose(result, hazard, adapter, params[:model]),
         {:ok, eval} <- Eval.score(proposal, adapter: adapter) do
      payload = %{
        hazard: kind,
        hazard_evidence: hazard[:evidence],
        occurrences: hazard[:count],
        session_id: result.session_id,
        fingerprint: result.fingerprint,
        name: proposal.name,
        description: proposal.description,
        event: proposal.event,
        matcher: proposal.matcher,
        composite: eval.composite,
        threshold: eval.threshold,
        passed: eval.passed,
        dimensions: dimension_scores(eval.dimensions),
        installed:
          maybe_install(proposal, adapter, params[:install], params[:force], eval.passed),
        script: Propose.render(proposal, adapter)
      }

      {:reply, Response.json(Response.tool(), payload), frame}
    else
      {:error, reason} -> {:reply, Response.error(Response.tool(), error_message(reason)), frame}
    end
  end

  defp allowed?, do: Application.get_env(:faber, :mcp_allow_propose, false) == true

  defp disabled_message do
    "faber_propose_hook is disabled because it calls an LLM and spends tokens. Enable it with " <>
      "`config :faber, :mcp_allow_propose, true`. The read-only tools (faber_search_friction, " <>
      "faber_list_skills, faber_get_skill) need no opt-in."
  end

  defp load_adapter do
    case Adapter.load(Faber.adapter_dir()) do
      {:ok, adapter} -> {:ok, adapter}
      {:error, reason} -> {:error, {:adapter, reason}}
    end
  end

  # The first session carrying `kind` — NOT the highest-ranked, because the ranking is friction and
  # a hazard has none. Mirrors `Faber.CLI`'s `select_hazard/2`.
  defp find_hazard(kind) do
    Enum.find_value(Scan.run(scan_opts()), {:error, {:no_such_hazard, kind}}, fn result ->
      case Enum.find(result.hazards, &(to_string(&1.kind) == kind)) do
        nil -> nil
        hazard -> {:ok, result, hazard}
      end
    end)
  end

  defp propose(result, hazard, adapter, model) do
    opts = if model in [nil, ""], do: [], else: [model: model]

    case Propose.propose_hook(result, hazard, adapter, opts) do
      {:ok, proposal} -> {:ok, proposal}
      {:error, reason} -> {:error, {:propose, reason}}
    end
  end

  # Install ONLY on an explicit request AND a passing gate. Takes the two flags as plain values
  # rather than guarding on `params.install`: an omitted field makes that guard raise, a raising
  # guard just doesn't match, and the clause silently falls through to the one that INSTALLS — a
  # propose-only call writing to disk, from a guard that reads like it prevents exactly that.
  #
  # The veto below is not a duplicate of the eval gate: `Install.Hook.install/2` re-checks the
  # exact bytes at the write boundary, and a passing score is not permission to write a dangerous
  # script.
  defp maybe_install(_proposal, _adapter, install, _force, _passed) when install != true,
    do: false

  defp maybe_install(_proposal, _adapter, _install, _force, false),
    do: "skipped: did not pass the eval gate"

  defp maybe_install(proposal, adapter, _install, force, true) do
    opts = [adapter: adapter] ++ if(force, do: [force: true], else: [])

    case Install.Hook.install(proposal, opts) do
      {:ok, %{script: script, settings: settings}} ->
        %{script: script, settings: settings}

      # The same refusal, in the same words, as the CLI and the dashboard: a safety veto is not an
      # overwrite conflict, and `force` must not read like the fix for it.
      {:error, {:vetoed, vetoes}} ->
        "REFUSED — not installed: " <>
          Enum.map_join(vetoes, "; ", &"#{&1.check_type}: #{&1.evidence}") <>
          ". This is a safety refusal, not a score. `force` overrides an existing install, never this."

      {:error, {:hand_edited, command}} ->
        "not installed: this hook's pointer in settings.json has been hand-edited since Faber " <>
          "wrote it (#{command}). Pass force: true to replace it, or keep your edit."

      {:error, reason} ->
        "install failed: #{inspect(reason)}"
    end
  end

  defp scan_opts, do: Application.get_env(:faber, :mcp_scan_opts, [])

  defp kind(k) when is_binary(k) and k != "", do: k
  defp kind(_), do: "pipe_masks_exit"

  defp dimension_scores(dimensions) when is_map(dimensions) do
    Map.new(dimensions, fn {name, dim} -> {name, round3(dim["score"])} end)
  end

  defp round3(n) when is_number(n), do: Float.round(n * 1.0, 3)
  defp round3(_), do: nil

  defp error_message({:adapter, reason}), do: "Could not load the adapter: #{inspect(reason)}."

  # Says what a clean scan does NOT mean. Faber detects one class today, so "not found" is a
  # statement about that class, not a clean bill of health — and a tool description that let a
  # model infer otherwise would be worse than no tool.
  defp error_message({:no_such_hazard, kind}) do
    "No session in this scan carries a `#{kind}` hazard. Known hazard classes: " <>
      "#{Enum.map_join(Hazard.known_kinds(), ", ", &to_string/1)}. Faber detects ONE class of " <>
      "frictionless hazard today, so this means that class wasn't found — not that the sessions " <>
      "are hazard-free."
  end

  defp error_message({:stack_mismatch, adapter, result}) do
    exts =
      case Propose.touched_extensions(result) do
        [] -> "no files"
        pairs -> Enum.map_join(pairs, ", ", fn {ext, n} -> "#{ext}×#{n}" end)
      end

    "This session doesn't match the #{adapter.name} stack, so a #{adapter.name} hook would be " <>
      "off-target. It touched #{exts}. Pass force: true to propose anyway."
  end

  defp error_message({:propose, reason}),
    do:
      "Hook generation failed (#{inspect(reason)}). The keyless backend needs the `claude` CLI " <>
        "on PATH; check that it's installed."

  defp error_message(reason), do: "faber_propose_hook failed: #{inspect(reason)}"
end
