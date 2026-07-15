defmodule Faber.Optimize do
  @moduledoc """
  **Skill optimization — two engines.**

  ## `reflect/3` — keyless reflective evolution (the v1 default)

  The working, keyless GEPA-style optimizer. It drives `Faber.Loop`'s `:reflect` strategy:
  evolve→eval→keep where each candidate is a **targeted edit** of the current best, informed by the
  eval's weakest dimension + failed checks (reflective credit assignment) — not a blind regenerate.
  Uses `Faber.LLM` (keyless `claude -p` by default) and the native deterministic eval; no `dspy`, no
  API key. See `.claude/research/2026-06-23-gepa-reflective-loop-decision.md` for the design and why
  we did **not** take a `dspy` dependency.

  ## `run/2` — `dspy.GEPA` sidecar seam (heavy engine, capability-gated)

  The Elixir call-path to the Python sidecar's `optimize` command (`python/faber_eval/optimize.py`).
  The sidecar's orchestration — the eval-matcher metric, the cost (rollout) guardrail, and result
  shaping — is implemented and unit-tested; the live `dspy.GEPA` engine is an **optional extra**
  (`gepa`) that needs `dspy` installed *and* a provider API key. Without them the sidecar degrades to
  `status: "not_implemented"` and this surfaces it as `{:error, {:not_implemented, reason}}` (the
  keyless reflective loop above covers v1). Enabling GEPA live is then a Python-side concern only —
  the request shape and response handling here are stable. The live path is unvalidated until you
  opt in to spend; the `:sidecar` test in `optimize_test.exs` covers the (free) boundary check.
  """

  alias Faber.{Adapter, Loop, Proposal, Propose, Scan, Sidecar}

  @doc """
  Reflectively optimize the skill for a friction finding — the keyless v1 optimizer.

  Delegates to `Faber.Loop.refine/3` with `strategy: :reflect`, so each iteration scores the current
  best, targets its weakest eval dimension, and re-proposes a focused edit; the strict-improvement
  ratchet keeps only genuine gains. Returns a `Faber.Loop.State` (with `:status`, `:best_composite`,
  and the full `:history`), or `{:error, reason}` if the seed proposal fails. `opts` are forwarded to
  `Propose`/`Eval`/`Loop` (e.g. `:llm`, `:adapter`, `:eval_set`, `:target`, `:max_iterations`).
  """
  @spec reflect(Scan.Result.t(), Adapter.t(), keyword()) :: Loop.State.t() | {:error, term()}
  def reflect(%Scan.Result{} = result, %Adapter{} = adapter, opts \\ []) do
    Loop.refine(result, adapter, Keyword.put(opts, :strategy, :reflect))
  end

  @doc """
  Attempt to optimize a skill via the GEPA sidecar.

  Accepts a rendered `SKILL.md` string or a `%Faber.Proposal{}` (rendered via the adapter's
  template when `:adapter` is supplied). `opts` are forwarded to `Faber.Sidecar.call/3` (so tests
  inject a fake via `:sidecar`); `:eval` and `:budget` are passed through to the optimizer.

  Returns `{:ok, result}` once GEPA is wired, or `{:error, {:not_implemented, reason}}` today.
  """
  @spec run(String.t() | Proposal.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(skill_or_proposal, opts \\ [])

  def run(%Proposal{} = proposal, opts) do
    md =
      case opts[:adapter] do
        nil -> Propose.render_skill_md(proposal)
        adapter -> Propose.render_skill_md(proposal, adapter)
      end

    run(md, opts)
  end

  def run(skill_md, opts) when is_binary(skill_md) do
    case Sidecar.call("optimize", build_request(skill_md, opts), opts) do
      {:ok, %{"status" => "ok", "result" => result}} ->
        {:ok, result}

      {:ok, %{"status" => "not_implemented"} = resp} ->
        {:error, {:not_implemented, resp["reason"] || "GEPA optimizer not wired"}}

      {:ok, %{"status" => "error"} = resp} ->
        {:error, resp["error"] || :sidecar_error}

      {:ok, other} ->
        {:error, {:unexpected_response, other}}

      {:error, _} = err ->
        err
    end
  end

  defp build_request(skill_md, opts) do
    %{"skill_md" => skill_md}
    |> put_present("eval", opts[:eval])
    |> put_present("budget", opts[:budget])
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
