defmodule Faber.Detect.Opportunity do
  @moduledoc """
  Missed-automation scoring — port of `compute-metrics.py`'s `compute_plugin_opportunity`,
  generalized to **rules**: each rule maps a friction condition (`when`) to a suggested skill.

  Rules and the skill namespaces used to detect already-used skills come from the selected
  adapter's detection vocab (contract §4.1); adapter-free runs use the engine defaults (see
  `Faber.Detect`).
  """

  alias Faber.Adapter
  alias Faber.Detect
  alias Faber.Ingest.Event

  @type opportunity :: %{score: float(), missed: [String.t()], used: [String.t()]}

  @doc """
  Score missed automation opportunities (0.0–1.0) and list the skills that could have helped
  but weren't used. See `Faber.Detect.opportunity/2`.

  `opportunity/4` accepts precomputed `tool_uses` / `bash_cmds` so `Faber.Detect.analyze/2`
  can share one traversal across all detection domains.
  """
  @spec opportunity(Enumerable.t(), Adapter.t() | nil) :: opportunity()
  def opportunity(events, adapter \\ nil) do
    events = Enum.to_list(events)
    tool_uses = Enum.flat_map(events, & &1.tool_uses)
    opportunity(events, adapter, tool_uses, Detect.bash_commands(tool_uses))
  end

  @spec opportunity([Event.t()], Adapter.t() | nil, [map()], [String.t()]) :: opportunity()
  def opportunity(events, adapter, tool_uses, bash_cmds) do
    names = Enum.map(tool_uses, & &1.name)
    used = used_skills(events, Detect.skill_namespaces(adapter))

    ctx = %{
      bash_cmds: bash_cmds,
      tool_count: length(names),
      edit_count: Enum.count(names, &(&1 in ["Edit", "Write"]))
    }

    missed =
      adapter
      |> Detect.opportunity_rules()
      |> Enum.reduce([], fn rule, acc ->
        if opportunity_match?(rule, used, ctx), do: [rule.skill | acc], else: acc
      end)
      |> Enum.reverse()

    %{
      score: Float.round(min(length(missed) * 0.2, 1.0), 2),
      missed: missed,
      used: Enum.sort(MapSet.to_list(used))
    }
  end

  # A rule fires when its trigger condition holds AND (unless `unless_used: false`) the skill
  # was not already used. `and` is commutative over booleans, so this matches the original
  # `trigger and not used?(...)` ordering exactly.
  defp opportunity_match?(%{skill: skill} = rule, used, ctx) do
    guard_ok = not (Map.get(rule, :unless_used, true) and used?(used, skill))
    guard_ok and rule_triggered?(rule, ctx)
  end

  # The `when` semantics (faithful to the original comparison operators):
  #   :retry_loops → 3+ consecutive same-prefix Bash commands
  #   :tool_count  → total tool calls   STRICTLY GREATER than threshold
  #   :edit_count  → Edit/Write calls   STRICTLY GREATER than threshold
  #   :commands    → count of Bash calls matching ANY command  >=  threshold
  defp rule_triggered?(%{when: :retry_loops}, ctx), do: investigate_opportunity?(ctx.bash_cmds)
  defp rule_triggered?(%{when: :tool_count, threshold: t}, ctx), do: ctx.tool_count > t
  defp rule_triggered?(%{when: :edit_count, threshold: t}, ctx), do: ctx.edit_count > t

  defp rule_triggered?(%{when: :commands, commands: cmds, threshold: t}, ctx),
    do: count_cmds(ctx.bash_cmds, cmds) >= t

  defp rule_triggered?(_rule, _ctx), do: false

  defp used?(used, name), do: MapSet.member?(used, name)

  defp count_cmds(bash_cmds, needles) do
    Enum.count(bash_cmds, fn cmd -> Enum.any?(needles, &String.contains?(cmd, &1)) end)
  end

  # 3+ consecutive Bash commands sharing their first two tokens (faithful to the source's
  # separate opportunity-retry heuristic).
  defp investigate_opportunity?(bash_cmds) do
    bash_cmds
    |> Enum.map(&(&1 |> String.split() |> Enum.take(2)))
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce_while(0, fn [prev, curr], consec ->
      if curr != [] and curr == prev do
        if consec + 1 >= 2, do: {:halt, true}, else: {:cont, consec + 1}
      else
        {:cont, 0}
      end
    end)
    |> case do
      true -> true
      _ -> false
    end
  end

  # Skills the session already used: Skill tool calls, attributionSkill, and /ns:cmd in text.
  # `namespaces` are the `ns:` prefixes matched in text (adapter-supplied, or the generic
  # defaults). An empty list means this stack has no skill namespaces → skip text extraction.
  defp used_skills(events, namespaces) do
    from_text =
      if namespaces == [] do
        []
      else
        re = skill_namespace_regex(namespaces)

        events
        |> Enum.filter(&is_binary(&1.text))
        |> Enum.flat_map(fn e -> Regex.scan(re, e.text, capture: :all_but_first) end)
        |> List.flatten()
      end

    from_attribution =
      events |> Enum.map(& &1.raw["attributionSkill"]) |> Enum.map(&skill_short_name/1)

    from_skill_tool =
      events
      |> Enum.flat_map(& &1.tool_uses)
      |> Enum.filter(&(&1.name == "Skill"))
      |> Enum.map(fn tu -> tu.input["command"] || tu.input["name"] || tu.input["skill"] end)
      |> Enum.map(&skill_short_name/1)

    (from_text ++ from_attribution ++ from_skill_tool)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.downcase/1)
    |> MapSet.new()
  end

  defp skill_short_name(s) when is_binary(s) do
    s |> String.split(":") |> List.last() |> String.replace_prefix("/", "")
  end

  defp skill_short_name(_), do: ""

  # Build the `(?:ns1|ns2):skill` extraction regex from a namespace list. Namespaces are escaped
  # so they're matched literally. For the default `~w(phx ecto lv)` this is byte-identical to the
  # original literal `~r/(?:phx|ecto|lv):([a-z][a-z0-9_-]*)/i`.
  #
  # Fails CLOSED: a malformed adapter pack can't crash a scan — it degrades to a never-match
  # regex. `Adapter.validate/1` rejects such packs at load, so this is defense in depth for an
  # adapter built in-memory rather than via `load/1`. Non-binary entries are filtered (so
  # `Regex.escape` can't raise); an all-junk / empty alternation and any compile failure both
  # collapse to never-match.
  #
  # The alternation shape (`(?:a|b):…`) has no nested quantifier, so it is not ReDoS-catastrophic;
  # packs are local, trusted repo files today. If adapters ever arrive over a network, add a
  # length cap on `skill_namespaces` in `Adapter.validate/1`.
  defp skill_namespace_regex(namespaces) do
    case namespaces |> Enum.filter(&is_binary/1) |> Enum.map_join("|", &Regex.escape/1) do
      "" ->
        ~r/(?!)/

      alt ->
        case Regex.compile("(?:#{alt}):([a-z][a-z0-9_-]*)", "i") do
          {:ok, re} -> re
          {:error, _} -> ~r/(?!)/
        end
    end
  end
end
