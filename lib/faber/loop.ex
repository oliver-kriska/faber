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
  """

  alias Faber.{Adapter, Eval, Propose, Scan}
  alias Faber.Loop.{Git, Journal}

  defmodule State do
    @moduledoc "Loop state carried across iterations and returned by `Faber.Loop.run/1`."
    defstruct skill: nil,
              path: nil,
              dir: nil,
              git: false,
              git_paths: [],
              journal_path: nil,
              best_content: nil,
              best_composite: 0.0,
              iteration: 0,
              consecutive_discards: 0,
              patience: 50,
              max_iterations: 50,
              target: 0.95,
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
  `:target`, `:max_iterations`, `:patience`, `:path`, `:dir`, `:git`, `:git_paths`,
  `:journal_path`.
  """
  @spec run(keyword()) :: State.t()
  def run(opts) do
    opts |> init() |> loop()
  end

  defp init(opts) do
    content = Keyword.fetch!(opts, :content)
    eval_fn = Keyword.fetch!(opts, :eval_fn)

    composite =
      case Keyword.get(opts, :composite) do
        nil ->
          case eval_fn.(content) do
            {:ok, c} -> c
            _ -> 0.0
          end

        c ->
          c
      end

    %State{
      skill: Keyword.get(opts, :skill),
      path: Keyword.get(opts, :path),
      dir: Keyword.get(opts, :dir),
      git: Keyword.get(opts, :git, false),
      git_paths: Keyword.get(opts, :git_paths, []),
      journal_path: Keyword.get(opts, :journal_path),
      best_content: content,
      best_composite: composite,
      patience: Keyword.get(opts, :patience, 50),
      max_iterations: Keyword.get(opts, :max_iterations, 50),
      target: Keyword.get(opts, :target, 0.95),
      propose_fn: Keyword.fetch!(opts, :propose_fn),
      eval_fn: eval_fn,
      checks_fn: Keyword.get(opts, :checks_fn, &default_checks/1)
    }
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
      {:ok, %{content: content} = prop} ->
        desc = Map.get(prop, :description, "proposed change")
        handle_candidate(state, iteration, content, desc)

      {:error, reason} ->
        discard(state, iteration, state.best_composite, "proposal failed", inspect(reason))
    end
  end

  defp handle_candidate(state, iteration, content, desc) do
    case write_candidate(state, content) do
      {:error, reason} ->
        discard(state, iteration, state.best_composite, desc, "write failed: #{inspect(reason)}")

      :ok ->
        run_checks_and_eval(state, iteration, content, desc)
    end
  end

  defp run_checks_and_eval(state, iteration, content, desc) do
    case state.checks_fn.(content) do
      {:error, reason} ->
        discard(state, iteration, state.best_composite, desc, "checks failed: #{inspect(reason)}")

      :ok ->
        case state.eval_fn.(content) do
          {:ok, composite} when composite > state.best_composite ->
            keep(state, iteration, content, composite, desc)

          {:ok, composite} ->
            revert(state, iteration, composite, desc, "no improvement")

          {:error, reason} ->
            discard(
              state,
              iteration,
              state.best_composite,
              desc,
              "eval failed: #{inspect(reason)}"
            )
        end
    end
  end

  # ── keep / revert / discard ──────────────────────────────────────────────

  defp keep(state, iteration, content, composite, desc) do
    if state.git, do: Git.commit(state.dir, state.git_paths, keep_message(state, composite))

    entry = entry(state, iteration, composite, true, desc, nil)
    log(state, entry)

    %{
      state
      | iteration: iteration,
        best_content: content,
        best_composite: composite,
        consecutive_discards: 0,
        history: [entry | state.history]
    }
  end

  defp revert(state, iteration, composite, desc, reason) do
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

  defp discard(state, iteration, composite, desc, reason) do
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
  best-scoring variant. Wires `Faber.Propose` (regeneration) + `Faber.Eval` (scoring) into
  `run/1`. Forwards `opts` to both (e.g. `:llm`, `:sidecar`, `:threshold`, `:max_iterations`,
  `:patience`, `:target`).
  """
  @spec refine(Scan.Result.t(), Adapter.t(), keyword()) :: State.t() | {:error, term()}
  def refine(%Scan.Result{} = result, %Adapter{} = adapter, opts \\ []) do
    case Propose.propose(result, adapter, opts) do
      {:ok, seed} ->
        run_refinement(result, adapter, seed, opts)

      {:error, _} = err ->
        err
    end
  end

  defp run_refinement(result, adapter, seed, opts) do
    content = Propose.render_skill_md(seed)

    propose_fn = fn _state ->
      case Propose.propose(result, adapter, opts) do
        {:ok, p} ->
          {:ok, %{content: Propose.render_skill_md(p), description: "regenerated #{p.name}"}}

        {:error, _} = err ->
          err
      end
    end

    eval_fn = fn c ->
      case Eval.score(c, opts) do
        {:ok, %{composite: comp}} -> {:ok, comp}
        {:error, _} = err -> err
      end
    end

    run(
      Keyword.merge(opts,
        skill: seed.name,
        content: content,
        propose_fn: propose_fn,
        eval_fn: eval_fn
      )
    )
  end
end
