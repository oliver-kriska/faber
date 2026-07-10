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

  # `:trigger` is added dynamically when `trigger: true` (behavioral fold); not all callers see it.
  @type result :: %{
          schema_version: String.t(),
          composite: float(),
          dimensions: map(),
          threshold: float(),
          passed: boolean(),
          weight_total: float()
        }

  # Fallback contract version if a (legacy) scorer result omits it; the engines (Native +
  # python sidecar) carry their own and the parity test asserts they agree.
  @schema_version "1.0"

  @ref_checks ~w(valid_file_refs valid_skill_refs valid_agent_refs)
  @behavioral_weight 0.10

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
    * `:eval_set`  — `:default` (6 structural dimensions, the gate baseline) or `:full` (8 — adds
      `accuracy`; `behavioral` is folded in when `:trigger`). Default `:default`, so adding the new
      dimensions never silently inflates the gate.
    * `:refs`      — resolved cross-reference known-sets for the `accuracy` dimension, a map with
      `:files` / `:skills` / `:agents` (and optional `:builtin_agents`) lists. The boundary resolves
      these from the install/adapter tree once; they thread into the (pure) accuracy matchers. Absent
      a known-set, accuracy neutral-passes — it never blocks the gate for missing context.
    * `:trigger`   — when true, run the behavioral trigger-accuracy eval and fold it into the
      composite as the `behavioral` dimension (weight #{0.10}). Costs one LLM call per fixture.
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
    case {opts[:eval], adapter_eval(opts)} do
      {eval, _} when eval != nil -> run_engine(engine(opts), skill_md, eval, opts)
      {_, adapter_eval} when adapter_eval != nil -> run_adapter_eval(skill_md, adapter_eval, opts)
      _ -> run_engine(engine(opts), skill_md, nil, opts)
    end
  end

  defp adapter_eval(opts) do
    case opts[:adapter] do
      %Adapter{eval: e} when is_map(e) -> e
      _ -> nil
    end
  end

  # Vendored: the adapter ships dimension/check definitions → native scoring honors them.
  # No `dimensions` in the pack ⇒ no stack-specific bar — fall through to the engine default
  # (which honors `:eval_set` + `:refs`) instead of a truthy `[]` that would mask them.
  defp run_adapter_eval(skill_md, %{"mode" => "vendored"} = e, opts) do
    case build_native_def(e["dimensions"] || []) do
      [] -> run_engine(:native, skill_md, nil, opts)
      dims -> run_engine(:native, skill_md, dims, opts)
    end
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

  defp run_engine(:native, skill_md, eval_def, opts) do
    def_ = (eval_def || native_default(opts)) |> inject_refs(opts[:refs])
    {:ok, Native.score(skill_md, def_)}
  end

  defp run_engine(:sidecar, skill_md, eval_def, opts) do
    request =
      %{"skill_md" => skill_md}
      |> maybe_put("eval", eval_def)
      |> maybe_put("eval_set", sidecar_eval_set(opts[:eval_set]))
      |> maybe_put("refs", sidecar_refs(opts[:refs]))

    case Sidecar.call("score", request, opts) do
      {:ok, %{"status" => "ok", "result" => result}} -> {:ok, result}
      {:ok, %{"status" => "error", "error" => err}} -> {:error, {:sidecar_error, err}}
      {:ok, other} -> {:error, {:unexpected_sidecar_response, other}}
      {:error, _} = err -> err
    end
  end

  # `:full` opts into the 8-dimension eval (adds accuracy); default stays the 6-dimension gate
  # baseline. nil → Native applies its own built-in default.
  defp native_default(opts) do
    case opts[:eval_set] do
      :full -> Native.full_eval()
      _ -> nil
    end
  end

  defp sidecar_eval_set(:full), do: "full"
  defp sidecar_eval_set(_), do: nil

  # Thread resolved ref known-sets into every accuracy check's params (the matcher reads only its own
  # key; extras are ignored). Keeps the matchers pure — the filesystem walk happens at the boundary.
  defp inject_refs(nil, _refs), do: nil
  defp inject_refs(def_, refs) when not is_map(refs), do: def_

  defp inject_refs(def_, refs) when is_list(def_) do
    extra = ref_params(refs)

    Enum.map(def_, fn {name, weight, checks} ->
      checks =
        Enum.map(checks, fn {type, params} ->
          if to_string(type) in @ref_checks,
            do: {type, Map.merge(params, extra)},
            else: {type, params}
        end)

      {name, weight, checks}
    end)
  end

  defp ref_params(refs) do
    %{}
    |> put_ref(:known_files, refs[:files] || refs["files"])
    |> put_ref(:known_skills, refs[:skills] || refs["skills"])
    |> put_ref(:known_agents, refs[:agents] || refs["agents"])
    |> put_ref(:builtin_agents, refs[:builtin_agents] || refs["builtin_agents"])
  end

  defp put_ref(map, _key, nil), do: map
  defp put_ref(map, key, value), do: Map.put(map, key, value)

  # JSON request form for the sidecar: string keys the Python `inject_refs` understands.
  defp sidecar_refs(refs) when is_map(refs) do
    Map.new(ref_params(refs), fn {k, v} -> {to_string(k), v} end)
  end

  defp sidecar_refs(_), do: nil

  # Translate a vendored adapter's eval dimensions (string-keyed YAML) into Native's internal form.
  # A check-level `weight` (sibling of `type`, mirroring the Python scorer's contract) is threaded
  # into the params so `Native.score_dimension` honors it — dropping it would silently flatten a
  # weighted adapter eval to 1.0. Non-numeric weights fall back to the 1.0 default (fail closed).
  defp build_native_def(dimensions) do
    Enum.map(dimensions, fn d ->
      checks =
        (d["checks"] || [])
        |> Enum.map(fn c ->
          params = atomize_params(c["params"] || %{})

          params =
            case c["weight"] do
              w when is_number(w) -> Map.put(params, :weight, w * 1.0)
              _ -> params
            end

          {to_string(c["type"]), params}
        end)

      {to_string(d["name"]), (d["weight"] || 0.0) * 1.0, checks}
    end)
  end

  defp atomize_params(params) when is_map(params) do
    # Matcher param atoms live in Matchers' literal pool — make sure the module is loaded before
    # `to_existing_atom`, or lazy module loading could reject valid keys as unknown.
    Code.ensure_loaded(Faber.Eval.Matchers)
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
  # it stays off the structural hot path. Only a %Proposal{} carries the trigger fixtures. When it
  # runs, its accuracy/precision/recall fold into the composite as the `behavioral` dimension, so a
  # well-formed-but-mis-routing skill can still fail the gate (the reference's 8th dimension).
  defp maybe_add_trigger(result, proposal, opts) do
    if opts[:trigger] do
      case Faber.Eval.Trigger.score(proposal, opts) do
        %{accuracy: _} = trigger -> fold_behavioral(result, trigger)
        {:skipped, _} = skipped -> Map.put(result, :trigger, skipped)
      end
    else
      result
    end
  end

  # Build the `behavioral` dimension from the trigger metrics (mirroring the reference's three
  # assertions) and re-weight it into the composite at `@behavioral_weight`, relative to the
  # structural mass the scorer reported (`weight_total`), so the math is exact for any eval set.
  defp fold_behavioral(result, trigger) do
    checks = [
      {trigger.accuracy >= 0.75, "trigger accuracy #{pct(trigger.accuracy)} (>= 75%)"},
      {trigger.precision >= 0.80, "precision #{pct(trigger.precision)} (>= 80%)"},
      {trigger.recall >= 0.60, "recall #{pct(trigger.recall)} (>= 60%)"}
    ]

    passed = Enum.count(checks, fn {ok, _} -> ok end)
    total = length(checks)

    # The dimension SCORE is **continuous** — the mean of the raw metrics — not the fraction of
    # thresholds met. A boolean step-function (`passed / total`) gives the reflective loop no gradient
    # once the bars are cleared: composite pins at the ceiling and the loop can't push raw accuracy
    # higher (confirmed empirically — see .claude/research/2026-06-26-dogfood-real-friction-*.md). A
    # continuous reward keeps a gradient toward better routing. The threshold `checks` above are kept
    # as human-readable evidence (which bars were cleared); they no longer drive the score.
    score = (trigger.accuracy + trigger.precision + trigger.recall) / 3

    dimension = %{
      "dimension" => "behavioral",
      "score" => Float.round(score, 4),
      "passed" => passed,
      "failed" => total - passed,
      "total" => total,
      "metrics" => %{
        "accuracy" => Float.round(trigger.accuracy, 4),
        "precision" => Float.round(trigger.precision, 4),
        "recall" => Float.round(trigger.recall, 4)
      },
      "assertions" =>
        Enum.with_index(checks, fn {ok, evidence}, i ->
          %{
            "id" => "behavioral-#{i}",
            "check_type" => "trigger_accuracy",
            "passed" => ok,
            "evidence" => evidence
          }
        end)
    }

    struct_mass = result.weight_total

    composite =
      (result.composite * struct_mass + score * @behavioral_weight) /
        (struct_mass + @behavioral_weight)

    composite = Float.round(composite, 4)

    %{
      result
      | composite: composite,
        weight_total: Float.round(struct_mass + @behavioral_weight, 4),
        dimensions: Map.put(result.dimensions, "behavioral", dimension),
        passed: composite >= result.threshold
    }
    |> Map.put(:trigger, trigger)
  end

  defp pct(f), do: "#{round(f * 100)}%"

  defp build_result(result, threshold) do
    composite = result["composite"] || 0.0

    %{
      schema_version: result["schema_version"] || @schema_version,
      composite: composite,
      dimensions: result["dimensions"] || %{},
      threshold: threshold,
      passed: composite >= threshold,
      weight_total: result["weight_total"] || 1.0
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
