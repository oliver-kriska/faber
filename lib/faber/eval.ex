defmodule Faber.Eval do
  @moduledoc """
  **Stage 4 — Eval gate.** Judge a proposed skill before it is presented, installed, or fed back
  into the loop.

  Structural scoring runs **natively in Elixir** by default (`Faber.Eval.Native`) — no `python3`
  spawn on the hot path, which matters inside the loop. The Python sidecar (`Faber.Sidecar`) runs
  the same matcher port and stays available via `engine: :sidecar` (or by injecting a `:sidecar`
  module in tests) for parity and as the future home for GEPA / trigger accuracy.

  `score/2` returns `{:ok, %{composite, dimensions, threshold, passed, vetoed}}`. `gate/2` is the
  pass/fail form the loop uses. Both accept either a rendered `SKILL.md` string or a
  `Faber.Proposal` (rendered via `Faber.Propose.render_skill_md/1`).

  `:passed` is **not** simply `composite >= threshold`: a failed *veto* check (`:vetoed`) fails the
  gate outright, because a weighted average cannot express "never install this". See `@veto_checks`.
  """

  require Logger

  alias Faber.{Adapter, Proposal, Propose, Sidecar}
  alias Faber.Eval.{ExecInPlace, Matchers, Native}

  # `:trigger` is added dynamically when `trigger: true` (behavioral fold); not all callers see it.
  @typedoc """
  `:engine` records **which scorer actually produced this result** — `"adapter:exec-in-place"` when
  the adapter's referenced scorer ran, `"native:fallback"` when it was attempted and failed, and
  `"native"` otherwise. A fallback PASS certifies generic markdown structure, not the stack's bar,
  so downstream must be able to tell them apart rather than infer it from the adapter being set.
  """
  @type result :: %{
          schema_version: String.t(),
          composite: float(),
          dimensions: map(),
          threshold: float(),
          passed: boolean(),
          vetoed: [veto()],
          weight_total: float(),
          engine: String.t()
        }

  @typedoc """
  A failed veto check: fatal to `:passed` regardless of `:composite`. See `@veto_checks`.

  Carries no dimension — a veto is a property of the **artifact**, established by re-running the
  check against it, not a reading of whatever dimension some scorer happened to file it under.
  """
  @type veto :: %{check_type: String.t(), evidence: String.t()}

  # Fallback contract version if a (legacy) scorer result omits it; the engines (Native +
  # python sidecar) carry their own and the parity test asserts they agree.
  @schema_version "1.0"

  @ref_checks ~w(valid_file_refs valid_skill_refs valid_agent_refs)

  # Checks whose params carry the proposal's hook pointer rather than anything readable off the
  # rendered script. See `inject_hook_pointer/2`. `hook_reads_stdin` is here for the `event` alone:
  # only a tool-call event pipes a tool call in, so it has to know which event it is judging.
  @hook_checks ~w(hook_pointer hook_reads_stdin)

  # The hook gate, raised from the skill default (0.75). A hook's dimensions are necessary
  # conditions rather than qualities to average, and at 0.75 they cannot all be individually fatal —
  # see `Faber.Eval.Native`'s `@hook_eval` for the arithmetic. Raising it is deliberate: a hook runs
  # automatically on every matching tool call, with the user not in the loop.
  @hook_threshold 0.90
  @behavioral_weight 0.10

  # Checks whose failure is **fatal to the gate regardless of the composite**, run by the engine
  # against the artifact itself.
  #
  # A weighted average cannot express "never install this". `safety` carries 0.15 (0.10 in the full
  # set), so an otherwise well-formed skill carrying `rm -rf /` scores exactly 0.75 against the 0.75
  # gate and *passes*: detected, reported, installed anyway. This gate decides what gets written
  # into the user's `~/.claude/skills`, and for a check asserting the artifact will **harm** the
  # user, the only correct posture is fail-closed — no amount of good structure buys it back.
  #
  # Per-CHECK, not per-dimension: `has_iron_laws` also lives in `safety`, and a skill merely missing
  # Iron Laws is *poor*, not *dangerous* — it should score badly and stay gradeable, not be vetoed.
  #
  # `hook_no_format_chars` is here rather than in `@hook_eval` for the reason the whole list exists:
  # a weighted average cannot express "never install this", and a bidi override in a script is not a
  # quality to trade off against good structure. It self-scopes to `kind: :hook` (see the matcher),
  # so naming it here costs a skill nothing — and buys the restore path, which has no render to
  # inspect, the same refusal as the propose path.
  @veto_checks ~w(no_dangerous_patterns hook_no_format_chars)

  @doc """
  Score a proposal or SKILL.md string.

  Options:

    * `:threshold` — pass mark for `:passed` (default `config :faber, :eval_threshold` or `0.75`)
    * `:engine`    — `:native` (default, in-process) or `:sidecar` (Python). A `:sidecar`
      module option forces the sidecar engine (tests inject a stub).
    * `:adapter`   — a `%Faber.Adapter{}`; its `eval/eval.yaml` supplies the stack-specific bar.
      `mode: vendored` dimensions drive native scoring; `mode: exec-in-place` runs the referenced
      scorer via `Faber.Eval.ExecInPlace` (env-bound — it needs the referenced repo present) and
      falls back to the default native eval if that fails, warning and recording
      `engine: "native:fallback"` so the fallback is never mistaken for the adapter's verdict.
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
    opts = kind_opts(proposal, opts)

    with {:ok, result} <- proposal |> render(opts) |> score(opts) do
      {:ok, maybe_add_trigger(result, proposal, opts)}
    end
  end

  def score(skill_md, opts) when is_binary(skill_md) do
    threshold = opts[:threshold] || Application.get_env(:faber, :eval_threshold, 0.75)

    case run_eval(skill_md, opts) do
      # `:kind` reaches here from `kind_opts/2`; a bare string scored directly is markdown unless a
      # caller says otherwise, so the veto reads it as a skill.
      {:ok, result} -> {:ok, build_result(result, threshold, skill_md, opts[:kind] || :skill)}
      {:error, _} = err -> err
    end
  end

  # Route a hook to the hook eval set, carrying its pointer along for `hook_pointer`. This is where
  # kind selects the bar — a hook scored by the skill set fails on prose it was never going to have,
  # and a hook scored by no set at all would be gated on nothing.
  #
  # `:eval` (an explicit definition) still wins, since `eval_route/1` prefers it: a caller naming the
  # bar outranks the kind default, exactly as it does for skills. Routing through `:eval` also keeps
  # a hook away from an adapter's `exec-in-place` scorer, which only understands SKILL.md.
  defp kind_opts(%Proposal{kind: :hook} = p, opts) do
    opts
    |> Keyword.put_new(:eval, Native.hook_eval())
    |> Keyword.put_new(:threshold, @hook_threshold)
    |> Keyword.put_new(:kind, :hook)
    |> Keyword.put_new(:hook_pointer, %{
      event: p.event,
      matcher: p.matcher,
      known_events: Propose.hook_events()
    })
  end

  defp kind_opts(%Proposal{}, opts), do: opts

  # Render via the adapter's `templates/` scaffold when one is supplied, so the eval scores the
  # same artifact the proposer/installer will emit; otherwise use the built-in renderer. Kind-neutral
  # (`render/2`, not `render_skill_md/2`) — scoring a hook's rendered *script* is the whole point of
  # the hook eval set, and the plan's own rule is that matchers are probed against the rendered
  # artifact, never a fixture, because the two render paths diverge on exactly these checks.
  defp render(proposal, opts), do: Propose.render(proposal, opts[:adapter])

  @doc """
  The engine `score/2` would **attempt** for these opts, named without scoring anything — what
  `faber propose --dry-run` reports before deciding whether to spend an LLM call.

  "Attempt" is the honest word and the reason this can't promise more: `exec-in-place` genuinely
  tries the adapter's external scorer and degrades to `native:fallback` when the referenced repo
  isn't there (see `run_adapter_eval/3`), which is only knowable by running it. A dry run that
  printed `native:fallback` would be guessing about the environment; one that printed
  `adapter:exec-in-place` is stating the intent, which is what the flag is for.
  """
  @spec planned_engine(keyword()) :: String.t()
  def planned_engine(opts) do
    case eval_route(opts) do
      {:explicit, _eval} -> to_string(engine(opts))
      {:adapter, %{"mode" => "exec-in-place"}} -> "adapter:exec-in-place"
      # A vendored pack is scored by the native engine against the pack's own dimensions.
      {:adapter, %{"mode" => "vendored"}} -> "native"
      {:adapter, _other} -> to_string(engine(opts))
      :default -> to_string(engine(opts))
    end
  end

  # Resolve HOW to score: explicit :eval wins, then an adapter's stack-specific criteria, else the
  # built-in default. This is the moat — a skill is judged by its stack's bar, not a generic one.
  defp run_eval(skill_md, opts) do
    case eval_route(opts) do
      {:explicit, eval} -> run_engine(engine(opts), skill_md, eval, opts)
      {:adapter, adapter_eval} -> run_adapter_eval(skill_md, adapter_eval, opts)
      :default -> run_engine(engine(opts), skill_md, nil, opts)
    end
  end

  # The routing decision, factored out so `planned_engine/1` reports the branch `run_eval/2` will
  # actually take rather than a parallel re-derivation of it that could drift.
  defp eval_route(opts) do
    case {opts[:eval], adapter_eval(opts)} do
      {eval, _} when eval != nil -> {:explicit, eval}
      {_, adapter_eval} when adapter_eval != nil -> {:adapter, adapter_eval}
      _ -> :default
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
  # cwd = source_repo). That's environment-bound (needs the repo + its deps), so genuinely attempt
  # it and fall back to the default native eval — never block the gate because a referenced repo is
  # absent, and never claim the adapter scored something it didn't.
  defp run_adapter_eval(skill_md, %{"mode" => "exec-in-place"}, opts) do
    case adapter_exec(skill_md, opts) do
      {:ok, result} ->
        {:ok, Map.put(result, "engine", "adapter:exec-in-place")}

      {:error, reason} ->
        Logger.warning(
          "adapter eval (exec-in-place) failed: #{inspect(reason)} — falling back to the generic " <>
            "native eval. This score is NOT the adapter's stack-specific verdict."
        )

        with {:ok, result} <- run_engine(:native, skill_md, nil, opts) do
          {:ok, Map.put(result, "engine", "native:fallback")}
        end
    end
  end

  defp run_adapter_eval(skill_md, _other, opts), do: run_engine(engine(opts), skill_md, nil, opts)

  # Only a %Faber.Adapter{} carries the pack that names the scorer; an `:eval` map passed directly
  # (tests, explicit definitions) has no root to run against.
  defp adapter_exec(skill_md, opts) do
    case opts[:adapter] do
      %Adapter{} = adapter -> ExecInPlace.score(skill_md, adapter, opts)
      _ -> {:error, :no_adapter}
    end
  end

  # An injected :sidecar module forces the Python path; otherwise honor :engine / config default.
  defp engine(opts) do
    if opts[:sidecar] do
      :sidecar
    else
      opts[:engine] || Application.get_env(:faber, :eval_engine, :native)
    end
  end

  defp run_engine(:native, skill_md, eval_def, opts) do
    def_ =
      (eval_def || native_default(opts))
      |> inject_refs(opts[:refs])
      |> inject_hook_pointer(opts[:hook_pointer])

    {:ok, Native.score(skill_md, def_)}
  end

  defp run_engine(:sidecar, skill_md, eval_def, opts) do
    request =
      %{"skill_md" => skill_md}
      |> maybe_put("eval", eval_def |> inject_hook_pointer(opts[:hook_pointer]) |> sidecar_eval())
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

  # Translate the internal `[{dimension, weight, [{type, params}]}]` form into the sidecar's JSON
  # shape — `%{dimension => %{"weight" => w, "checks" => [%{"type" => t, ...params}]}}` — where a
  # check's params are flattened alongside its type (`scorer.py`'s `_score_dimension` pops `type`
  # and `weight` and splats the rest as kwargs).
  #
  # Without this, ANY explicit `:eval` sent to `engine: :sidecar` raised `Jason.Encoder` on the bare
  # tuples. It went unnoticed because nothing sent one: the vendored-adapter path pins `:native`, and
  # the parity tests drove the sidecar with `:eval_set`. `kind: :hook` is the first caller to put an
  # `:eval` in opts, so it is the first to reach it — and the hook parity test is what surfaced it.
  defp sidecar_eval(nil), do: nil

  # Already in the sidecar's shape (a caller handing the Python engine its own JSON definition) —
  # pass it through rather than mangling it. Only the internal tuple form needs translating.
  defp sidecar_eval(def_) when is_map(def_), do: def_

  defp sidecar_eval(def_) when is_list(def_) do
    Map.new(def_, fn {name, weight, checks} ->
      {name,
       %{
         "weight" => weight,
         "checks" =>
           Enum.map(checks, fn {type, params} ->
             params |> Map.new(fn {k, v} -> {to_string(k), v} end) |> Map.put("type", type)
           end)
       }}
    end)
  end

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

  # Thread the proposal's hook pointer into the `hook_pointer` check's params — the same shape as
  # `inject_refs/2`, and for the same reason: a matcher stays `(content, params)`, pure and mirrorable
  # in Python, so anything it can't read off the artifact arrives as params from the boundary.
  defp inject_hook_pointer(nil, _pointer), do: nil
  defp inject_hook_pointer(def_, pointer) when not is_map(pointer), do: def_

  defp inject_hook_pointer(def_, pointer) when is_list(def_) do
    Enum.map(def_, fn {name, weight, checks} ->
      checks =
        Enum.map(checks, fn {type, params} ->
          if to_string(type) in @hook_checks,
            do: {type, Map.merge(params, pointer)},
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
  Gate a proposal: `{:pass, result}` if it scored `composite >= threshold` **and** tripped no veto
  check (`:vetoed == []`), else `{:fail, result}`. Errors pass through unchanged.
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
        # Re-derive `passed` from the *new* composite, but keep the veto: folding in a behavioral
        # score must never resurrect an artifact the structural gate refused to install.
        passed: composite >= result.threshold and result.vetoed == []
    }
    |> Map.put(:trigger, trigger)
  end

  defp pct(f), do: "#{round(f * 100)}%"

  defp build_result(result, threshold, content, kind) do
    composite = result["composite"] || 0.0
    vetoed = vetoes(content, kind)

    %{
      schema_version: result["schema_version"] || @schema_version,
      composite: composite,
      dimensions: result["dimensions"] || %{},
      threshold: threshold,
      passed: composite >= threshold and vetoed == [],
      vetoed: vetoed,
      weight_total: result["weight_total"] || 1.0,
      engine: result["engine"] || "native"
    }
  end

  # Run the veto checks **against the artifact**, with the ENGINE's own parameters — never off the
  # scorer's report.
  #
  # The first version of this read the scored `dimensions`, on the reasoning that every engine emits
  # the same `assertions` shape so one implementation would cover them all. That was wrong in the
  # way that matters: it made a fail-closed check **opt-out by configuration**, and review reproduced
  # three ways through it.
  #
  #   * A vendored pack's `dimensions` *wholly replace* the default eval (see `translate_eval/2`), so
  #     a pack that simply OMITS `no_dangerous_patterns` emits no such assertion and is un-vetoable —
  #     `rm -rf /` scored 1.0 and passed. Packs are untrusted input, so the security boundary was
  #     configurable by the thing it constrains.
  #   * A pack supplying its own `patterns` could weaken the check even where it ran.
  #   * A foreign result shape (atom-keyed assertions from an exec-in-place scorer) made
  #     `assertion["passed"] == false` evaluate `nil == false` → the failed assertion was silently
  #     dropped and the artifact passed. Fail-OPEN, on the one function that must fail closed.
  #
  # Reading the artifact makes all three unreachable: the veto no longer depends on what the scorer
  # looked at, what it named things, or what shape it reported. `params: %{}` is deliberate — it
  # pins `@dangerous_default`, so a pack cannot narrow the pattern set for the veto even while
  # narrowing it for its own score.
  #
  # `Matchers.run_check/3` is pure and returns `{bool, evidence}` for a known check; an unknown one
  # returns `{false, "unknown check_type: …"}`, which would veto everything — so `@veto_checks` may
  # only ever name checks this module implements (pinned by a test).
  @doc """
  The veto verdict for a rendered artifact: `[]` when it may be written, else one entry per refusal.

  Public because the **write boundary** (`Faber.Install.install/2`) calls it directly on the bytes it
  is about to write, rather than trusting its caller to have scored the artifact and to have read the
  verdict. That is not belt-and-braces, it is the only version that holds: `passed`/`vetoed` are
  advisory the moment a caller can forget to look at them, and four of them did — two gated on
  `passed`, `Faber.CLI` passed the `--install` *flag* where the verdict belonged, and the dashboard
  checked nothing at all. A gate every caller must remember is a suggestion.

  Pure, cheap, and derived from content alone, so it is safe to call at any layer.

  `kind` (default `:skill`) selects how the artifact is read, and it is not cosmetic. The safety
  scan exempts a section that announces it documents dangerous patterns, so a skill listing
  `rm -rf /` under "## Anti-patterns" stays installable — it is documentation. `##` is *also* an
  ordinary shell comment, so on a `:hook` that exemption is a hole: a script of
  `## Anti-patterns` + `rm -rf /` was vetoed by nothing. Reproduced before this parameter existed,
  and the write boundary is where it mattered most — `Faber.Install.install/2` calls this, so the
  comment defeated the last line of defense, not merely a score.
  """
  @spec vetoes(String.t(), Proposal.kind()) :: [veto()]
  def vetoes(content, kind \\ :skill) when is_binary(content) do
    params = veto_params(kind)

    for check <- @veto_checks,
        {false, evidence} <- [Matchers.run_check(check, content, params)] do
      %{check_type: check, evidence: to_string(evidence)}
    end
  end

  # An executable artifact gets no safe-section exemption: every line of it runs, and it has no
  # documentation for the exemption to protect.
  #
  # `kind` is passed explicitly rather than left absent for `hook_no_format_chars` to infer. A check
  # that guesses what it is reading guesses wrong on exactly the artifact that was built to fool it.
  defp veto_params(:hook), do: %{exempt_safe_sections: false, kind: :hook}
  defp veto_params(kind), do: %{kind: kind}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
