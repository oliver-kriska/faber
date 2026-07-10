defmodule Faber.Loop do
  @moduledoc """
  **Stage 5 — The autoresearch loop.** Self-improve a skill: propose → eval → keep-winner, with
  git as the ratchet, until the score plateaus or hits the target.

  A faithful port of the plugin's `lab/autoresearch` pattern (generate → eval → keep/revert →
  journal), with one deliberate improvement: **strict** improvement is required to keep a
  candidate (`composite > best`). The source keeps on ties, which the SkillOpt research flagged as
  "lateral churn"; requiring a strict gain makes plateau detection real and the loop converge.

  `run/1` is the pure-ish driver — inject `propose_fn`/`eval_fn` and it returns the final state
  with a full history, so the keep/revert/plateau logic is deterministically testable with no LLM,
  no Python, and no git. `refine/3` wires the real pipeline (`Faber.Propose` + `Faber.Eval`).
  Side effects (writing the candidate file, git keep/revert, journal append) are opt-in via
  `:path`, `:git`, and `:journal_path`.

  `refine/3` returns `{:error, reason}` (rather than crashing) when the very first proposal fails
  — e.g. the LLM backend is unavailable or the `claude` CLI exits non-zero.

  Stop conditions (ported): `best_composite >= target` (default `0.95`) → `:complete`;
  `iteration >= max_iterations` (default `50`) → `:complete`; `consecutive_discards >= patience`
  (default `50`) → `:stuck`.

  ## Optimizing routing (behavioral recall) — `trigger: true`

  By default the loop's composite is **structural-only**: `eval_fn` scores a rendered string,
  which never folds the behavioral trigger dimension. `refine/3` with `trigger: true` opts into
  behavioral optimization: candidates are scored as **proposals** (so trigger accuracy /
  precision / recall fold in at weight 0.10) — but always against the **seed proposal's
  fixtures, pinned** for the whole run. A candidate may not rewrite the exam it is graded on;
  without pinning the LLM could game the objective by generating fixtures its own description
  trivially routes (the reason this dimension was originally kept out of the loop). Because one
  routing call is a single Bernoulli draw, trigger mode defaults to `trigger_samples: 3`
  (pooled) and `min_improvement` can gate keeps above the remaining noise.

  Pinning stops *gaming*, but the loop still optimizes against the fixtures it is judged on —
  `trigger_holdout: true` adds a generalization check: the seed's fixtures are split
  deterministically (alternating) into a **train** half the loop pins and optimizes against, and
  a **validation** half it never sees; the final best is scored once on the validation half and
  the result lands in `State.holdout`. A big train/validation gap means the loop overfit the
  train phrasings rather than improving routing.
  """

  alias Faber.{Adapter, Eval, Propose, Proposal, Scan}
  alias Faber.Loop.{Git, Journal, Reflect}

  defmodule State do
    @moduledoc "Loop state carried across iterations and returned by `Faber.Loop.run/1`."
    defstruct skill: nil,
              path: nil,
              dir: nil,
              git: false,
              git_paths: [],
              journal_path: nil,
              best_content: nil,
              best_proposal: nil,
              best_composite: 0.0,
              # The current best's full eval (%{composite:, dimensions:}) when the eval_fn
              # supplies one ({:ok, comp, meta}) — lets :reflect derive feedback without
              # re-scoring the unchanged best every iteration. nil for plain 2-tuple eval_fns.
              best_eval: nil,
              iteration: 0,
              consecutive_discards: 0,
              patience: 50,
              max_iterations: 50,
              target: 0.95,
              min_improvement: 0.0,
              # Set only by refine/3 with trigger_holdout: true — the final best scored on the
              # held-out validation fixtures (never optimized against): %{composite:, behavioral:,
              # fixtures:} or %{error: reason}.
              holdout: nil,
              status: :running,
              propose_fn: nil,
              eval_fn: nil,
              checks_fn: nil,
              history: []
  end

  @doc """
  Run the loop to termination and return the final `%State{}` (with `:status` and reversed
  `:history`).

  Required opts: `:content` (seed SKILL.md), `:propose_fn`, `:eval_fn`. Optional: `:composite`
  (seed score; else computed via `eval_fn`), `:skill`, `:checks_fn` (default `default_checks/1`),
  `:target`, `:max_iterations`, `:patience`, `:min_improvement` (keep only when
  `composite > best + min_improvement`; default `0.0` = strict), `:proposal` (the seed
  `%Faber.Proposal{}`, tracked as `best_proposal`), `:path`, `:dir`, `:git`, `:git_paths`,
  `:journal_path`.

  `propose_fn` returns `{:ok, %{content: String.t(), description: String.t()}}`; the map may
  also carry `proposal: %Faber.Proposal{}`. `eval_fn` is arity 1 (`content`) or arity 2
  (`content, candidate_map`) — arity 2 is how proposal-aware scoring (the behavioral trigger
  dimension) reaches the eval. It returns `{:ok, composite}` or `{:ok, composite, meta}` — the
  optional `meta` (`%{composite:, dimensions:}`) is cached as the best's eval on a keep so the
  `:reflect` strategy can derive feedback without re-scoring the unchanged best (`:best_eval`
  seeds it when a precomputed `:composite` is supplied).
  """
  @spec run(keyword()) :: State.t()
  def run(opts) do
    opts |> init() |> loop()
  end

  defp init(opts) do
    content = Keyword.fetch!(opts, :content)
    eval_fn = Keyword.fetch!(opts, :eval_fn)

    {composite, best_eval} =
      case Keyword.get(opts, :composite) do
        nil -> seed_eval(eval_fn, content, Keyword.get(opts, :proposal))
        c -> {c, Keyword.get(opts, :best_eval)}
      end

    %State{
      skill: Keyword.get(opts, :skill),
      path: Keyword.get(opts, :path),
      dir: Keyword.get(opts, :dir),
      git: Keyword.get(opts, :git, false),
      git_paths: Keyword.get(opts, :git_paths, []),
      journal_path: Keyword.get(opts, :journal_path),
      best_content: content,
      best_proposal: Keyword.get(opts, :proposal),
      best_composite: composite,
      best_eval: best_eval,
      patience: Keyword.get(opts, :patience, 50),
      max_iterations: Keyword.get(opts, :max_iterations, 50),
      target: Keyword.get(opts, :target, 0.95),
      min_improvement: Keyword.get(opts, :min_improvement, 0.0),
      propose_fn: Keyword.fetch!(opts, :propose_fn),
      eval_fn: eval_fn,
      checks_fn: Keyword.get(opts, :checks_fn, &default_checks/1)
    }
  end

  # Score the seed when no :composite was supplied. An arity-2 eval_fn (proposal-aware) gets a
  # synthetic candidate map built from the seed opts, mirroring what propose_fn will emit.
  defp seed_eval(eval_fn, content, proposal) do
    result =
      if is_function(eval_fn, 2),
        do: eval_fn.(content, %{content: content, proposal: proposal}),
        else: eval_fn.(content)

    case result do
      {:ok, c} -> {c, nil}
      {:ok, c, meta} -> {c, meta}
      _ -> {0.0, nil}
    end
  end

  defp loop(%State{} = state) do
    cond do
      state.best_composite >= state.target -> finish(state, :complete)
      state.iteration >= state.max_iterations -> finish(state, :complete)
      state.consecutive_discards >= state.patience -> finish(state, :stuck)
      true -> state |> step() |> loop()
    end
  end

  defp step(%State{} = state) do
    iteration = state.iteration + 1

    case state.propose_fn.(state) do
      {:ok, %{content: _} = candidate} ->
        handle_candidate(state, iteration, candidate)

      {:error, reason} ->
        reject(state, iteration, state.best_composite, "proposal failed", inspect(reason))
    end
  end

  defp handle_candidate(state, iteration, %{content: content} = candidate) do
    desc = Map.get(candidate, :description, "proposed change")

    case write_candidate(state, content) do
      {:error, reason} ->
        reject(state, iteration, state.best_composite, desc, "write failed: #{inspect(reason)}")

      :ok ->
        run_checks_and_eval(state, iteration, candidate, desc)
    end
  end

  defp run_checks_and_eval(state, iteration, %{content: content} = candidate, desc) do
    case state.checks_fn.(content) do
      {:error, reason} ->
        reject(state, iteration, state.best_composite, desc, "checks failed: #{inspect(reason)}")

      :ok ->
        case eval_candidate(state, candidate) do
          {:ok, composite} ->
            decide(state, iteration, candidate, composite, nil, desc)

          {:ok, composite, meta} ->
            decide(state, iteration, candidate, composite, meta, desc)

          {:error, reason} ->
            reject(
              state,
              iteration,
              state.best_composite,
              desc,
              "eval failed: #{inspect(reason)}"
            )
        end
    end
  end

  defp decide(state, iteration, candidate, composite, meta, desc) do
    if composite > state.best_composite + state.min_improvement do
      keep(state, iteration, candidate, composite, meta, desc)
    else
      reject(state, iteration, composite, desc, "no improvement")
    end
  end

  # An arity-2 eval_fn sees the whole candidate map (so proposal-aware scoring — the behavioral
  # trigger dimension — is possible); the arity-1 form keeps the original content-only contract.
  defp eval_candidate(%State{eval_fn: f}, %{content: content} = candidate)
       when is_function(f, 2),
       do: f.(content, candidate)

  defp eval_candidate(%State{eval_fn: f}, %{content: content}), do: f.(content)

  # ── keep / revert / discard ──────────────────────────────────────────────

  # A keep the ratchet can't bank is a failed keep: the git-mode invariant is "HEAD always holds
  # the current best", so a failed commit routes to reject/5 (restore to HEAD, count the discard)
  # rather than letting in-memory best and the committed tree silently diverge.
  defp keep(state, iteration, %{content: content} = candidate, composite, meta, desc) do
    case commit_best(state, composite) do
      :ok ->
        entry = entry(state, iteration, composite, true, desc, nil)
        log(state, entry)

        %{
          state
          | iteration: iteration,
            best_content: content,
            best_proposal: Map.get(candidate, :proposal) || state.best_proposal,
            best_composite: composite,
            best_eval: meta,
            consecutive_discards: 0,
            history: [entry | state.history]
        }

      {:error, reason} ->
        reject(state, iteration, composite, desc, "commit failed: #{inspect(reason)}")
    end
  end

  defp commit_best(%State{git: true} = state, composite),
    do: Git.commit(state.dir, state.git_paths, keep_message(state, composite))

  defp commit_best(_state, _composite), do: :ok

  # A rejected candidate (no improvement, failed checks, or eval error): restore the working tree
  # to the current best, journal it, and bump the plateau counter. The entry's desc/reason record
  # which kind of rejection it was.
  defp reject(state, iteration, composite, desc, reason) do
    restore(state)
    entry = entry(state, iteration, composite, false, desc, reason)
    log(state, entry)

    %{
      state
      | iteration: iteration,
        consecutive_discards: state.consecutive_discards + 1,
        history: [entry | state.history]
    }
  end

  defp finish(state, status), do: %{state | status: status, history: Enum.reverse(state.history)}

  # ── filesystem / git side effects (opt-in) ─────────────────────────────────

  defp write_candidate(%State{path: nil}, _content), do: :ok
  defp write_candidate(%State{path: path}, content), do: File.write(path, content)

  # Restore the working tree to the current best after a rejected candidate. Best-effort: a
  # restore failure shouldn't itself raise out of the run.
  defp restore(%State{git: true, dir: dir, git_paths: paths}), do: Git.revert(dir, paths)

  defp restore(%State{path: path, best_content: best}) when is_binary(path) do
    _ = File.write(path, best)
    :ok
  end

  defp restore(_state), do: :ok

  defp log(%State{journal_path: nil}, _entry), do: :ok
  defp log(%State{journal_path: path}, entry), do: Journal.append(path, entry)

  defp entry(state, iteration, composite, kept, desc, reason) do
    Journal.entry(
      iteration: iteration,
      skill: state.skill,
      old_composite: state.best_composite,
      new_composite: composite,
      kept: kept,
      description: desc,
      reason: reason
    )
  end

  defp keep_message(state, composite) do
    "autoresearch: #{state.skill || "skill"} " <>
      "#{fmt(state.best_composite)}->#{fmt(composite)}"
  end

  defp fmt(n), do: :erlang.float_to_binary(n * 1.0, decimals: 4)

  # ── default structural checks (mirrors checks.sh essentials) ───────────────

  @doc "Minimal structural guard: frontmatter name+description, no conflict markers, ≤535 lines."
  @spec default_checks(String.t()) :: :ok | {:error, term()}
  def default_checks(content) do
    cond do
      not Regex.match?(~r/^name:\s*\S/m, content) -> {:error, :missing_name}
      not Regex.match?(~r/^description:\s*\S/m, content) -> {:error, :missing_description}
      Regex.match?(~r/^(<<<<<<<|=======|>>>>>>>)/m, content) -> {:error, :conflict_markers}
      length(String.split(content, "\n")) > 535 -> {:error, :too_long}
      true -> :ok
    end
  end

  # ── real-pipeline wiring ───────────────────────────────────────────────────

  @doc """
  Refine a proposal for `result` under `adapter` by repeatedly re-proposing and keeping the
  best-scoring variant. Wires `Faber.Propose` + `Faber.Eval` (scoring) into `run/1`. Forwards
  `opts` to both (e.g. `:llm`, `:sidecar`, `:threshold`, `:max_iterations`, `:patience`, `:target`,
  `:min_improvement`).

  `:seed` (a `%Faber.Proposal{}`) starts the loop from an existing proposal — e.g. one already
  produced by `faber propose` or installed and now being improved — instead of minting a fresh
  one from the friction finding.

  `:strategy` selects how each candidate is generated:

    * `:regenerate` (default) — re-propose from the friction finding from scratch each iteration.
    * `:reflect` — **reflective evolution** (the keyless GEPA-style path): score the current best,
      find its weakest eval dimension + failed checks, and feed that back into `Propose` so the next
      candidate is a *targeted* edit of the current draft. See `Faber.Optimize.reflect/3` and
      `.claude/research/2026-06-23-gepa-reflective-loop-decision.md`.

  `trigger: true` folds the behavioral routing dimension into the loop's composite: candidates
  are scored as proposals with the **seed's trigger fixtures pinned** (never their own — see the
  moduledoc's fixture-gaming note), pooled over `:trigger_samples` (defaults to `3` here; the
  one-shot eval default stays `1`). This is what lets the loop optimize recall, which a
  structural-only composite can never see.

  `trigger_holdout: true` (requires `trigger: true` and ≥2 fixtures in BOTH lists, else
  `{:error, :insufficient_fixtures_for_holdout}`) splits the seed's fixtures: the loop optimizes
  against the train half only, and the returned state carries `holdout` — the final best scored
  on the never-optimized validation half (see the moduledoc).
  """
  @spec refine(Scan.Result.t(), Adapter.t(), keyword()) :: State.t() | {:error, term()}
  def refine(%Scan.Result{} = result, %Adapter{} = adapter, opts \\ []) do
    case seed_proposal(result, adapter, opts) do
      {:ok, seed} ->
        run_refinement(result, adapter, seed, opts)

      {:error, _} = err ->
        err
    end
  end

  defp seed_proposal(result, adapter, opts) do
    case Keyword.get(opts, :seed) do
      %Proposal{} = seed -> {:ok, seed}
      nil -> Propose.propose(result, adapter, opts)
    end
  end

  defp run_refinement(result, adapter, seed, opts) do
    trigger? = Keyword.get(opts, :trigger, false)
    holdout? = trigger? and Keyword.get(opts, :trigger_holdout, false)

    case holdout_split(seed, holdout?) do
      {:ok, pin_seed, validate_seed} ->
        result
        |> do_refinement(adapter, seed, pin_seed, opts)
        |> attach_holdout(validate_seed, holdout_eval_opts(adapter, opts))

      {:error, _} = err ->
        err
    end
  end

  # `pin_seed` carries the fixtures candidates are graded on: the whole seed normally, the train
  # half under trigger_holdout (so reflection feedback can't peek at the validation half either).
  defp do_refinement(result, adapter, seed, pin_seed, opts) do
    content = Propose.render_skill_md(seed, adapter)

    # Judge each candidate by THIS adapter's stack-specific eval bar (the moat), not a generic one.
    # In trigger mode, single draws bank noise — default to pooled sampling (see moduledoc).
    eval_opts =
      opts
      |> Keyword.put(:adapter, adapter)
      |> then(fn eo ->
        if eo[:trigger], do: Keyword.put_new(eo, :trigger_samples, 3), else: eo
      end)

    trigger? = Keyword.get(eval_opts, :trigger, false)
    strategy = Keyword.get(opts, :strategy, :regenerate)
    propose_fn = build_propose_fn(strategy, result, adapter, eval_opts, opts, pin_seed)
    eval_fn = build_eval_fn(trigger?, pin_seed, eval_opts)

    run_opts =
      Keyword.merge(opts,
        skill: seed.name,
        content: content,
        proposal: seed,
        propose_fn: propose_fn,
        eval_fn: eval_fn
      )

    # In trigger mode the seed must be scored the same way candidates are (behavioral folded),
    # or the first candidate would be compared against an incompatible structural-only baseline.
    run_opts =
      if trigger? do
        case score_pinned(seed, pin_seed, eval_opts) do
          {:ok, comp, meta} ->
            run_opts |> Keyword.put(:composite, comp) |> Keyword.put(:best_eval, meta)

          {:error, _} ->
            run_opts
        end
      else
        run_opts
      end

    run(run_opts)
  end

  # ── held-out validation (trigger_holdout: true) ────────────────────────────

  defp holdout_split(seed, false), do: {:ok, seed, nil}

  defp holdout_split(%Proposal{} = seed, true) do
    if length(seed.should_trigger || []) >= 2 and length(seed.should_not_trigger || []) >= 2 do
      {st_train, st_val} = alternate(seed.should_trigger)
      {snt_train, snt_val} = alternate(seed.should_not_trigger)

      {:ok, %{seed | should_trigger: st_train, should_not_trigger: snt_train},
       %{seed | should_trigger: st_val, should_not_trigger: snt_val}}
    else
      {:error, :insufficient_fixtures_for_holdout}
    end
  end

  # Deterministic alternating split (even indices train, odd validate) — reproducible runs, and
  # both polarities land on both sides whenever each list has ≥2 fixtures.
  defp alternate(list) do
    list
    |> Enum.with_index()
    |> Enum.split_with(fn {_, i} -> rem(i, 2) == 0 end)
    |> then(fn {evens, odds} -> {Enum.map(evens, &elem(&1, 0)), Enum.map(odds, &elem(&1, 0))} end)
  end

  # Validation must score with the same trigger-fold + pooling the loop used.
  defp holdout_eval_opts(adapter, opts) do
    opts
    |> Keyword.put(:adapter, adapter)
    |> Keyword.put_new(:trigger_samples, 3)
  end

  defp attach_holdout(state_or_err, nil, _eval_opts), do: state_or_err
  defp attach_holdout({:error, _} = err, _validate_seed, _eval_opts), do: err

  defp attach_holdout(%State{best_proposal: %Proposal{} = best} = state, validate, eval_opts) do
    report =
      case Eval.score(pin_fixtures(best, validate), eval_opts) do
        {:ok, %{composite: comp} = result} ->
          %{
            composite: comp,
            behavioral: get_in(result.dimensions, ["behavioral", "score"]),
            fixtures: length(validate.should_trigger) + length(validate.should_not_trigger)
          }

        {:error, reason} ->
          %{error: reason}
      end

    %{state | holdout: report}
  end

  defp attach_holdout(%State{} = state, _validate_seed, _eval_opts), do: state

  # Blind regeneration — the baseline. Each candidate is independent of the last.
  defp build_propose_fn(:regenerate, result, adapter, _eval_opts, opts, _seed) do
    fn _state ->
      case Propose.propose(result, adapter, opts) do
        {:ok, p} ->
          {:ok,
           %{
             content: Propose.render_skill_md(p, adapter),
             description: "regenerated #{p.name}",
             proposal: p
           }}

        {:error, _} = err ->
          err
      end
    end
  end

  # Reflective evolution — derive the next candidate from the current best + its eval feedback.
  # In trigger mode the current best is scored AS a (pinned) proposal, so `behavioral` can be
  # the weakest dimension and the feedback can target routing/recall explicitly.
  defp build_propose_fn(:reflect, result, adapter, eval_opts, opts, seed) do
    fn state ->
      subject =
        case {eval_opts[:trigger], state.best_proposal} do
          {true, %Proposal{} = best} -> pin_fixtures(best, seed)
          _ -> state.best_content
        end

      {target, feedback} =
        Reflect.feedback(state.best_eval, subject, state.best_content, eval_opts)

      case Propose.propose(result, adapter, Keyword.put(opts, :feedback, feedback)) do
        {:ok, p} ->
          {:ok,
           %{
             content: Propose.render_skill_md(p, adapter),
             description: "reflect: #{target}",
             proposal: p
           }}

        {:error, _} = err ->
          err
      end
    end
  end

  # Structural-only scoring (the default): the composite of the rendered string. The full eval
  # rides along as the 3rd element so a keep caches it for :reflect feedback (see State.best_eval).
  defp build_eval_fn(false, _seed, eval_opts) do
    fn c ->
      case Eval.score(c, eval_opts) do
        {:ok, %{composite: comp} = result} -> {:ok, comp, eval_meta(result)}
        {:error, _} = err -> err
      end
    end
  end

  # Behavioral-in-the-loop: score the candidate AS a proposal so the trigger dimension folds in —
  # always against the seed's fixtures (pinned), never the candidate's own.
  defp build_eval_fn(true, seed, eval_opts) do
    fn _content, candidate ->
      case candidate do
        %{proposal: %Proposal{} = p} -> score_pinned(p, seed, eval_opts)
        _ -> {:error, :candidate_without_proposal}
      end
    end
  end

  defp score_pinned(proposal, seed, eval_opts) do
    case Eval.score(pin_fixtures(proposal, seed), eval_opts) do
      {:ok, %{composite: comp} = result} -> {:ok, comp, eval_meta(result)}
      {:error, _} = err -> err
    end
  end

  defp eval_meta(%{composite: comp} = result),
    do: %{composite: comp, dimensions: result.dimensions}

  @doc false
  # The fixture-gaming guard: candidates are graded on the SEED's routing fixtures for the whole
  # run. Exposed (@doc false) so the pinning contract itself is unit-testable.
  @spec pin_fixtures(Proposal.t(), Proposal.t()) :: Proposal.t()
  def pin_fixtures(%Proposal{} = proposal, %Proposal{} = seed) do
    %{
      proposal
      | should_trigger: seed.should_trigger,
        should_not_trigger: seed.should_not_trigger
    }
  end
end
