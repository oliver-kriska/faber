defmodule Faber.CLI.JSON do
  @moduledoc """
  `--json` renderings of the CLI's read-only surfaces — the machine half of clig.dev's
  "human-readable by default, machine-readable when asked".

  Every shape here is written out **explicitly** rather than dumping a struct. Three reasons, in
  order of how much they'd hurt:

    1. Some internals simply don't encode. A `Faber.Scan.Result`'s `:stamp` and a stored proposal's
       `:session_stamp` are source-defined terms — tuples today — and `Jason` raises on a tuple, so
       a blanket dump would turn `faber scan --json` into a crash the day a source changed shape.
    2. An explicit map is a **contract**. Anything scripting against this should break loudly when a
       field is renamed, not silently start emitting a new internal field because someone added one
       to a struct.
    3. The table's columns are lossy on purpose (`fmt/1` rounds, `ctx` prints `—` for unknown).
       These carry the raw values instead: full floats, the whole signal vector, `null` where the
       table shows a dash.

  Human output stays on stdout as text; nothing here writes — the caller prints. Status lines are
  stderr regardless (see `--quiet`), so `faber scan --json | jq` is always a clean stream.
  """

  alias Faber.Scan
  alias Faber.Scan.Scope

  @doc "The ranked table, as `{scope, elapsed_ms, count, sessions}`."
  @spec scan([Scan.Result.t()], non_neg_integer(), Scope.t() | nil) :: String.t()
  def scan(results, elapsed_ms, scope) do
    encode(%{
      scope: scope(scope),
      elapsed_ms: elapsed_ms,
      count: length(results),
      sessions: Enum.map(results, &session/1)
    })
  end

  @doc "The proposal list. `installed` mirrors the table's ✓ column."
  @spec proposals([map()], MapSet.t(String.t())) :: String.t()
  def proposals(records, installed) do
    encode(%{
      dir: Faber.proposals_dir(),
      count: length(records),
      proposals: Enum.map(records, &proposal(&1, installed))
    })
  end

  @doc "One proposal, including its rendered SKILL.md."
  @spec show(map()) :: String.t()
  def show(record), do: record |> proposal(MapSet.new()) |> Map.put(:md, record.md) |> encode()

  @doc "The outer-loop usage report, one entry per Faber-installed skill."
  @spec feedback([map()]) :: String.t()
  def feedback(reports) do
    encode(%{count: length(reports), skills: Enum.map(reports, &report/1)})
  end

  defp session(%Scan.Result{} = r) do
    %{
      session_id: r.session_id,
      path: r.path,
      cwd: r.cwd,
      # Both friction numbers, always: `raw` is what the table ranks by, `score` is the sigmoid the
      # tier-2 gate uses. Printing one and calling it "friction" is what made the table ambiguous.
      friction: %{
        raw: r.raw,
        score: r.friction,
        rate: r.rate,
        dominant_signal: r.dominant_signal,
        signals: r.signals
      },
      # Deliberately a sibling of `friction`, not a member of it: a hazard is a frictionless
      # SUCCESS, so it contributes nothing to the score and a session carrying one may rank last.
      # This is the discovery surface for `faber propose --hazard <kind>`.
      hazards: r.hazards,
      fingerprint: %{type: r.fingerprint, confidence: r.fingerprint_confidence},
      opportunity: %{score: r.opportunity, missed: r.missed, skills_used: r.skills_used},
      counts: %{
        events: r.message_count,
        turns: r.human_turns,
        tools: r.tool_count,
        errors: r.error_count,
        parse_errors: r.parse_errors
      },
      file_paths: r.file_paths,
      max_ctx_pct: r.max_ctx_pct,
      tier2: r.tier2
    }
  end

  defp proposal(record, installed) do
    %{
      id: record.id,
      name: record.name,
      outcome: record.outcome,
      adapter: record.adapter,
      created_at: record.created_at,
      source_sessions: record.source_sessions,
      installed: MapSet.member?(installed, record.name),
      eval: eval(record.eval)
    }
  end

  # `dimensions` survives the store's JSON round-trip with STRING keys while the top-level eval keys
  # are atomized, so a dimension is read through the same both-shapes accessor the text renderer uses
  # rather than assuming whichever one this record happens to have.
  defp eval(eval) when is_map(eval) do
    %{
      composite: eval[:composite],
      engine: eval[:engine],
      dimensions: dimensions(eval[:dimensions] || eval["dimensions"])
    }
  end

  defp eval(_eval), do: %{composite: nil, engine: nil, dimensions: %{}}

  defp dimensions(dims) when is_map(dims) do
    Map.new(dims, fn {name, d} -> {to_string(name), score(d)} end)
  end

  defp dimensions(_dims), do: %{}

  defp score(%{score: s}), do: s
  defp score(%{"score" => s}), do: s
  defp score(_dimension), do: nil

  defp report(r) do
    %{
      skill: r.skill,
      installed_at: r.installed_at,
      sessions: r.sessions,
      sessions_used: r.sessions_used,
      usage_rate: r.usage_rate,
      friction_with: r.friction_with,
      friction_without: r.friction_without,
      verdict: r.verdict
    }
  end

  defp scope(%Scope{kind: :project} = s),
    do: %{kind: "project", project: s.label, root: s.root, transcript_dir: s.base}

  defp scope(%Scope{kind: :all} = s), do: %{kind: "all", reason: s.reason}
  defp scope(nil), do: %{kind: "all", reason: nil}

  # Pretty-printed: this is still a terminal, and a human eyeballing `--json` before piping it into
  # something is the common first use. `jq` does not care either way.
  defp encode(data), do: Jason.encode!(data, pretty: true)
end
