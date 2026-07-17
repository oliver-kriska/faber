defmodule Faber.MCP.Tools.SearchFriction do
  @moduledoc """
  Rank the user's recent coding-agent sessions by *friction* (repeated errors, retries, dead-ends,
  context pressure) and return the worst offenders. Use this to discover where a coding agent keeps
  struggling — each finding is a candidate for a reusable skill. Returns **aggregates only** (scores,
  signals, touched file paths, project dir) — never the raw transcript text.

  Each finding also carries `hazards`: frictionless hazards the session ran (`faber_propose_hook`
  turns one into a hook). They are **not** part of the friction score and a session carrying one may
  rank last — this is the only place they surface, since the ranking is blind to them by
  construction.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias Faber.Scan

  @default_limit 10
  @max_limit 50

  schema do
    field(:limit, :integer,
      description: "Max findings to return, 1 to #{@max_limit}; default #{@default_limit}."
    )

    field(:rank_by, :string,
      description:
        "Ranking strategy. 'raw' = total friction, favors long sessions, the default. " <>
          "'rate' = friction per message, surfaces concentrated friction."
    )
  end

  @impl true
  def execute(params, frame) do
    opts =
      scan_opts()
      |> Keyword.merge(limit: clamp(params[:limit]), rank_by: rank_by(params[:rank_by]))

    findings = opts |> Scan.run() |> Enum.map(&summarize/1)

    {:reply, Response.json(Response.tool(), %{count: length(findings), findings: findings}),
     frame}
  end

  @doc """
  Project a `Scan.Result` onto an explicit aggregate-only allowlist — the privacy boundary. Raw
  transcript text NEVER leaves the engine (same boundary as the LLM path); only scores, signals, and
  filesystem metadata the user already owns are exposed. Public so the privacy guarantee is unit-
  testable.
  """
  @spec summarize(Scan.Result.t()) :: map()
  def summarize(%Scan.Result{} = r) do
    %{
      hazards: Enum.map(r.hazards, &hazard/1),
      session_id: r.session_id,
      friction: round2(r.friction),
      raw: round2(r.raw),
      rate: round2(r.rate),
      dominant_signal: r.dominant_signal,
      opportunity: round2(r.opportunity),
      tool_count: r.tool_count,
      error_count: r.error_count,
      message_count: r.message_count,
      human_turns: r.human_turns,
      max_ctx_pct: round2(r.max_ctx_pct),
      cwd: r.cwd,
      file_paths: r.file_paths,
      missed: r.missed,
      skills_used: r.skills_used,
      fingerprint: r.fingerprint
    }
  end

  # A hazard, minus its `evidence` — which QUOTES the Bash command the session ran, and so is
  # transcript content, not an aggregate. The class, how often it happened, and the hook pointer it
  # implies are everything an agent needs to decide whether to call `faber_propose_hook`; the
  # command itself is only needed once the user has explicitly asked for a hook to be written, and
  # that tool returns it there. Keeping it out here is the same instinct that dropped `tool_use`
  # from `Scan.Result` — a read-only tool an agent may call freely is the wrong place to widen the
  # boundary.
  defp hazard(h) do
    %{
      kind: h.kind,
      count: h.count,
      suggested_event: h.suggested_event,
      matcher: h.matcher
    }
  end

  # Base scan options — defaults to the real corpus; tests/config can pin a fixtures base.
  defp scan_opts, do: Application.get_env(:faber, :mcp_scan_opts, [])

  defp clamp(nil), do: @default_limit
  defp clamp(n) when n < 1, do: 1
  defp clamp(n) when n > @max_limit, do: @max_limit
  defp clamp(n), do: n

  defp rank_by("rate"), do: :rate
  defp rank_by(_), do: :raw

  defp round2(nil), do: nil
  defp round2(n) when is_float(n), do: Float.round(n, 2)
  defp round2(n), do: n
end
