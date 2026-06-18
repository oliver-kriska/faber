defmodule Faber.Eval do
  @moduledoc """
  **Stage 4 — Eval gate.** Judge a proposed skill before it is presented, installed, or fed back
  into the loop.

  The optimizer/eval ecosystem is Python, so this stage composes rather than rebuilds: it shells
  out to the `faber_eval` sidecar (`Faber.Sidecar`), which runs the ported `lab/eval` matchers and
  returns a composite score plus per-dimension breakdown. Structural scoring needs no API key — it
  is pure-stdlib Python — so the gate runs offline. (Trigger-accuracy and GEPA, which need an LLM,
  are later additions.)

  `score/2` returns `{:ok, %{composite, dimensions, threshold, passed}}`. `gate/2` is the
  pass/fail form the loop uses. Both accept either a rendered `SKILL.md` string or a
  `Faber.Proposal` (rendered via `Faber.Propose.render_skill_md/1`).
  """

  alias Faber.{Proposal, Propose, Sidecar}

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
    * `:eval`      — a custom eval definition forwarded to the sidecar (adapter-supplied)
    * `:sidecar`   — override the sidecar implementation (tests inject a stub)
  """
  @spec score(Proposal.t() | String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def score(proposal_or_md, opts \\ [])

  def score(%Proposal{} = proposal, opts) do
    proposal |> Propose.render_skill_md() |> score(opts)
  end

  def score(skill_md, opts) when is_binary(skill_md) do
    threshold = opts[:threshold] || Application.get_env(:faber, :eval_threshold, 0.75)

    request =
      %{"skill_md" => skill_md}
      |> maybe_put("eval", opts[:eval])

    case Sidecar.call("score", request, opts) do
      {:ok, %{"status" => "ok", "result" => result}} ->
        {:ok, build_result(result, threshold)}

      {:ok, %{"status" => "error", "error" => err}} ->
        {:error, {:sidecar_error, err}}

      {:ok, other} ->
        {:error, {:unexpected_sidecar_response, other}}

      {:error, _} = err ->
        err
    end
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
