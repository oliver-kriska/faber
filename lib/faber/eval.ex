defmodule Faber.Eval do
  @moduledoc """
  **Stage 4 — Eval gate.** Judge a proposed skill before it is presented, installed, or fed back
  into the loop.

  Structural scoring runs **natively in Elixir** by default (`Faber.Eval.Native`) — no `python3`
  spawn on the hot path, which matters inside the loop. The Python sidecar (`Faber.Sidecar`) runs
  the same matcher port and stays available via `engine: :sidecar` (or by injecting a `:sidecar`
  module in tests) for parity and as the future home for GEPA / trigger accuracy.

  `score/2` returns `{:ok, %{composite, dimensions, threshold, passed}}`. `gate/2` is the
  pass/fail form the loop uses. Both accept either a rendered `SKILL.md` string or a
  `Faber.Proposal` (rendered via `Faber.Propose.render_skill_md/1`).
  """

  require Logger

  alias Faber.{Adapter, Proposal, Propose, Sidecar}
  alias Faber.Eval.Native

  @type result :: %{
          composite: float(),
          dimensions: map(),
          threshold: float(),
          passed: boolean()
        }

  @doc """
  Score a proposal or SKILL.md string.

  Options:

    * `:threshold` — pass mark for `:passed` (default `config :faber, :eval_threshold` or `0.75`)
    * `:engine`    — `:native` (default, in-process) or `:sidecar` (Python). A `:sidecar`
      module option forces the sidecar engine (tests inject a stub).
    * `:adapter`   — a `%Faber.Adapter{}`; its `eval/eval.yaml` supplies the stack-specific bar.
      `mode: vendored` dimensions drive native scoring; `mode: exec-in-place` dispatches to the
      referenced scorer (env-bound) and falls back to the default native eval if unavailable.
    * `:eval`      — an explicit eval definition (overrides `:adapter`)
  """
  @spec score(Proposal.t() | String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def score(proposal_or_md, opts \\ [])

  def score(%Proposal{} = proposal, opts) do
    with {:ok, result} <- proposal |> render(opts) |> score(opts) do
      {:ok, maybe_add_trigger(result, proposal, opts)}
    end
  end

  def score(skill_md, opts) when is_binary(skill_md) do
    threshold = opts[:threshold] || Application.get_env(:faber, :eval_threshold, 0.75)

    case run_eval(skill_md, opts) do
      {:ok, result} -> {:ok, build_result(result, threshold)}
      {:error, _} = err -> err
    end
  end

  # Render via the adapter's `templates/` scaffold when one is supplied, so the eval scores the
  # same artifact the proposer/installer will emit; otherwise use the built-in renderer.
  defp render(proposal, opts) do
    case opts[:adapter] do
      %Adapter{} = adapter -> Propose.render_skill_md(proposal, adapter)
      _ -> Propose.render_skill_md(proposal)
    end
  end

  # Resolve HOW to score: explicit :eval wins, then an adapter's stack-specific criteria, else the
  # built-in default. This is the moat — a skill is judged by its stack's bar, not a generic one.
  defp run_eval(skill_md, opts) do
    cond do
      opts[:eval] != nil -> run_engine(engine(opts), skill_md, opts[:eval], opts)
      adapter_eval(opts) != nil -> run_adapter_eval(skill_md, adapter_eval(opts), opts)
      true -> run_engine(engine(opts), skill_md, nil, opts)
    end
  end

  defp adapter_eval(opts) do
    case opts[:adapter] do
      %Adapter{eval: e} when is_map(e) -> e
      _ -> nil
    end
  end

  # Vendored: the adapter ships dimension/check definitions → native scoring honors them.
  defp run_adapter_eval(skill_md, %{"mode" => "vendored"} = e, opts) do
    run_engine(:native, skill_md, build_native_def(e["dimensions"] || []), opts)
  end

  # Exec-in-place: the adapter references an external scorer (e.g. the plugin's lab.eval, run with
  # cwd = source_repo). That's environment-bound (needs the repo + its deps), so attempt it and fall
  # back to the default native eval — never block the gate because a referenced repo is absent.
  defp run_adapter_eval(skill_md, %{"mode" => "exec-in-place"}, opts) do
    Logger.info(
      "adapter eval is exec-in-place; using default native scoring (referenced scorer " <>
        "integration is env-bound — see ADAPTER_CONTRACT §7)."
    )

    run_engine(:native, skill_md, nil, opts)
  end

  defp run_adapter_eval(skill_md, _other, opts), do: run_engine(engine(opts), skill_md, nil, opts)

  # An injected :sidecar module forces the Python path; otherwise honor :engine / config default.
  defp engine(opts) do
    if opts[:sidecar] do
      :sidecar
    else
      opts[:engine] || Application.get_env(:faber, :eval_engine, :native)
    end
  end

  defp run_engine(:native, skill_md, eval_def, _opts) do
    {:ok, Native.score(skill_md, eval_def)}
  end

  defp run_engine(:sidecar, skill_md, eval_def, opts) do
    request = maybe_put(%{"skill_md" => skill_md}, "eval", eval_def)

    case Sidecar.call("score", request, opts) do
      {:ok, %{"status" => "ok", "result" => result}} -> {:ok, result}
      {:ok, %{"status" => "error", "error" => err}} -> {:error, {:sidecar_error, err}}
      {:ok, other} -> {:error, {:unexpected_sidecar_response, other}}
      {:error, _} = err -> err
    end
  end

  # Translate a vendored adapter's eval dimensions (string-keyed YAML) into Native's internal form.
  defp build_native_def(dimensions) do
    Enum.map(dimensions, fn d ->
      checks =
        (d["checks"] || [])
        |> Enum.map(fn c -> {to_string(c["type"]), atomize_params(c["params"] || %{})} end)

      {to_string(d["name"]), (d["weight"] || 0.0) * 1.0, checks}
    end)
  end

  defp atomize_params(params) when is_map(params) do
    Map.new(params, fn {k, v} -> {safe_atom(k), v} end)
  end

  # Matcher param keys are a fixed, known set already present as atoms — to_existing_atom keeps an
  # adapter's YAML from minting arbitrary atoms. Unknown keys stay strings (the matcher ignores them).
  defp safe_atom(k) when is_atom(k), do: k

  defp safe_atom(k) when is_binary(k) do
    String.to_existing_atom(k)
  rescue
    ArgumentError ->
      Logger.warning(
        "adapter eval references unknown matcher param #{inspect(k)} — ignored (no such matcher key)"
      )

      k
  end

  @doc """
  Gate a proposal: `{:pass, result}` if `composite >= threshold`, else `{:fail, result}`. Errors
  pass through unchanged.
  """
  @spec gate(Proposal.t() | String.t(), keyword()) ::
          {:pass, result()} | {:fail, result()} | {:error, term()}
  def gate(proposal_or_md, opts \\ []) do
    case score(proposal_or_md, opts) do
      {:ok, %{passed: true} = r} -> {:pass, r}
      {:ok, %{passed: false} = r} -> {:fail, r}
      {:error, _} = err -> err
    end
  end

  # Behavioral trigger-accuracy is opt-in (`trigger: true`) — it costs one LLM call per fixture, so
  # it stays off the structural hot path. Only a %Proposal{} carries the trigger fixtures.
  defp maybe_add_trigger(result, proposal, opts) do
    if opts[:trigger] do
      Map.put(result, :trigger, Faber.Eval.Trigger.score(proposal, opts))
    else
      result
    end
  end

  defp build_result(result, threshold) do
    composite = result["composite"] || 0.0

    %{
      composite: composite,
      dimensions: result["dimensions"] || %{},
      threshold: threshold,
      passed: composite >= threshold
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
