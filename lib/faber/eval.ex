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

  alias Faber.{Proposal, Propose, Sidecar}
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
    * `:eval`      — a custom eval definition (forwarded to the sidecar)
  """
  @spec score(Proposal.t() | String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def score(proposal_or_md, opts \\ [])

  def score(%Proposal{} = proposal, opts) do
    proposal |> Propose.render_skill_md() |> score(opts)
  end

  def score(skill_md, opts) when is_binary(skill_md) do
    threshold = opts[:threshold] || Application.get_env(:faber, :eval_threshold, 0.75)

    case run_engine(engine(opts), skill_md, opts) do
      {:ok, result} -> {:ok, build_result(result, threshold)}
      {:error, _} = err -> err
    end
  end

  # An injected :sidecar module forces the Python path; otherwise honor :engine / config default.
  defp engine(opts) do
    cond do
      opts[:sidecar] -> :sidecar
      true -> opts[:engine] || Application.get_env(:faber, :eval_engine, :native)
    end
  end

  defp run_engine(:native, skill_md, opts) do
    {:ok, Native.score(skill_md, opts[:eval])}
  end

  defp run_engine(:sidecar, skill_md, opts) do
    request = maybe_put(%{"skill_md" => skill_md}, "eval", opts[:eval])

    case Sidecar.call("score", request, opts) do
      {:ok, %{"status" => "ok", "result" => result}} -> {:ok, result}
      {:ok, %{"status" => "error", "error" => err}} -> {:error, {:sidecar_error, err}}
      {:ok, other} -> {:error, {:unexpected_sidecar_response, other}}
      {:error, _} = err -> err
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
