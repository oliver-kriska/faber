defmodule Faber.Optimize do
  @moduledoc """
  **GEPA optimizer seam (M5, not yet wired).** The Elixir call-path to the Python sidecar's
  `optimize` command — an evolve→eval→keep prompt optimizer wrapping GEPA / `dspy.GEPA`.

  This is intentionally a **stub boundary**: GEPA needs `dspy` installed *and* a provider API key,
  neither of which the v1 sidecar contract assumes (the boundary is stdlib-only). So the sidecar
  reports `status: "not_implemented"` and `run/2` surfaces that as `{:error, {:not_implemented,
  reason}}`. The seam exists so that wiring GEPA later is a Python-side change only — the Elixir
  call-path, request shape, and response handling are already in place.

  **For v1, use `Faber.Loop`** — the deterministic propose→eval→keep/revert/plateau cycle. It
  delivers the same evolve→eval→keep value with no extra Python deps and no API key, and is what
  the scheduler and dashboard drive today.
  """

  alias Faber.{Propose, Proposal, Sidecar}

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
