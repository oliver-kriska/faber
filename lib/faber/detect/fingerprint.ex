defmodule Faber.Detect.Fingerprint do
  @moduledoc """
  Session-type classification (`bug-fix` / `feature` / `exploration` / `maintenance` /
  `review` / `refactoring`) — port of `compute-metrics.py`'s `compute_fingerprint`, plus the
  tool-usage profile.

  Stack-specific command/tool bonuses come from the selected adapter's detection vocab
  (contract §4.1); adapter-free runs have none (see `Faber.Detect`).
  """

  alias Faber.Adapter
  alias Faber.Detect
  alias Faber.Ingest.Event

  # Session fingerprint keyword patterns (applied to the first 10 human messages), ported
  # from compute-metrics.py FINGERPRINT_KEYWORDS. Each match contributes 2.0 to its type.
  @fingerprint_keywords %{
    "bug-fix" => ~r/\b(fix|bug|broken|error|issue|crash|fail|debug|wrong)\b/i,
    "feature" => ~r/\b(add|implement|build|create|new feature|scaffold)\b/i,
    "exploration" => ~r/\b(explore|understand|how does|what is|explain|look at)\b/i,
    "maintenance" => ~r/\b(deps?|update|upgrade|bump|version|migrate)\b/i,
    "review" => ~r/\b(review|PR|pull request|code review|feedback)\b/i,
    "refactoring" => ~r/\b(refactor|extract|rename|move|reorganize|clean ?up)\b/i
  }

  # Fixed fingerprint-type order = compute-metrics.py's FINGERPRINT_KEYWORDS insertion order.
  # On a score tie, both pick the earliest type in THIS order — deterministic AND parity-matching
  # (the reference's `max(scores, key=...)` returns the first-inserted key on ties).
  @fingerprint_order ~w(bug-fix feature exploration maintenance review refactoring)

  @type fingerprint :: %{type: String.t(), confidence: float()}

  @doc """
  Classify the session type with a confidence in 0.0–1.0. See `Faber.Detect.fingerprint/2`.

  `fingerprint/4` accepts precomputed `tool_uses` / `bash_cmds` so `Faber.Detect.analyze/2`
  can share one traversal across all detection domains.
  """
  @spec fingerprint(Enumerable.t(), Adapter.t() | nil) :: fingerprint()
  def fingerprint(events, adapter \\ nil) do
    events = Enum.to_list(events)
    tool_uses = Enum.flat_map(events, & &1.tool_uses)
    fingerprint(events, adapter, tool_uses, Detect.bash_commands(tool_uses))
  end

  @spec fingerprint([Event.t()], Adapter.t() | nil, [map()], [String.t()]) :: fingerprint()
  def fingerprint(events, adapter, tool_uses, bash_cmds) do
    # Intent keywords live in the request's opening words; slice each message (like the
    # corrections detector's 500-char slice) so a pasted log/diff doesn't feed megabytes into
    # every keyword Regex.scan below.
    user_text =
      events
      |> Enum.filter(&Event.human_turn?/1)
      |> Enum.take(10)
      |> Enum.map_join(" ", &String.slice(&1.text || "", 0, 2000))

    names = Enum.map(tool_uses, & &1.name)
    total = max(length(names), 1)
    counts = Enum.frequencies(names)

    read_pct = (count(counts, "Read") + count(counts, "Grep") + count(counts, "Glob")) / total
    edit_pct = (count(counts, "Edit") + count(counts, "Write")) / total
    bash_pct = count(counts, "Bash") / total

    files = files_edited(tool_uses)

    scores =
      @fingerprint_keywords
      |> Map.new(fn {type, re} -> {type, length(Regex.scan(re, user_text)) * 2.0} end)
      # Generic, engine-side bonuses (tool-ratio / files) — never stack-specific.
      |> bonus("exploration", read_pct > 0.5 and edit_pct < 0.1, 3.0)
      |> bonus("feature", edit_pct > 0.3, 2.0)
      |> bonus("bug-fix", bash_pct > 0.3, 2.0)
      |> bonus("refactoring", length(files) > 10, 2.0)
      |> bonus("feature", length(files) > 5, 1.0)
      # Stack-specific command/tool bonuses — from the adapter (adapter-free there are none).
      |> apply_fingerprint_rules(bash_cmds, names, Detect.fingerprint_rules(adapter))

    total_score = scores |> Map.values() |> Enum.sum()

    if total_score <= 0.0 do
      %{type: "unknown", confidence: 0.0}
    else
      # Pick the max score, ties broken by @fingerprint_order, then any adapter-introduced novel
      # types (sorted, for determinism). With only built-in types `extra` is empty, so this is
      # byte-identical to the original `@fingerprint_order`-only selection.
      extra = (Map.keys(scores) -- @fingerprint_order) |> Enum.sort()

      {best, best_score} =
        (@fingerprint_order ++ extra)
        |> Enum.map(fn t -> {t, Map.get(scores, t, 0.0)} end)
        |> Enum.max_by(fn {_t, score} -> score end)

      %{type: best, confidence: Float.round(best_score / total_score, 2)}
    end
  end

  @doc """
  Tool-usage profile: percentage breakdown of tool calls by category.
  """
  @spec tool_profile(Enumerable.t()) :: %{optional(atom()) => float()}
  def tool_profile(events) do
    names = events |> Enum.flat_map(& &1.tool_uses) |> Enum.map(& &1.name)
    total = length(names)

    empty = %{read: 0, edit: 0, bash: 0, grep: 0, mcp: 0, other: 0}

    if total == 0 do
      Map.new(empty, fn {cat, _} -> {cat, 0.0} end)
    else
      names
      |> Enum.reduce(empty, fn name, acc ->
        Map.update!(acc, categorize_tool(name), &(&1 + 1))
      end)
      |> Map.new(fn {cat, n} -> {cat, n / total} end)
    end
  end

  defp categorize_tool(name) when name in ["Read", "Glob"], do: :read
  defp categorize_tool(name) when name in ["Edit", "Write", "NotebookEdit"], do: :edit
  defp categorize_tool("Bash"), do: :bash
  defp categorize_tool("Grep"), do: :grep
  defp categorize_tool("mcp__" <> _), do: :mcp
  defp categorize_tool(_), do: :other

  # Apply each bonus rule: when any of its `commands` appears in the session's Bash calls, OR
  # any tool name starts with one of its `tools` prefixes (contract §4.1 — MCP tool families
  # like `mcp__tidewave`), add `bonus` to its `type`. `Map.update/4` (not `update!`) so
  # adapter-introduced novel types are created on first hit rather than crashing. Both keys are
  # read with `Map.get` — an in-memory rule may carry only one of them.
  defp apply_fingerprint_rules(scores, bash_cmds, names, rules) do
    Enum.reduce(rules, scores, fn %{type: type, bonus: amount} = rule, acc ->
      hit? =
        any_cmd?(bash_cmds, Map.get(rule, :commands, [])) or
          any_tool?(names, Map.get(rule, :tools, []))

      if hit?, do: Map.update(acc, type, amount, &(&1 + amount)), else: acc
    end)
  end

  defp any_cmd?(bash_cmds, needles) do
    Enum.any?(bash_cmds, fn cmd -> Enum.any?(needles, &String.contains?(cmd, &1)) end)
  end

  defp any_tool?(names, prefixes) do
    Enum.any?(names, fn name -> Enum.any?(prefixes, &String.starts_with?(name, &1)) end)
  end

  defp files_edited(tool_uses) do
    tool_uses
    |> Enum.filter(&(&1.name in ["Edit", "Write", "NotebookEdit"]))
    |> Enum.map(fn tu -> tu.input["file_path"] end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp bonus(scores, type, true, amount), do: Map.update!(scores, type, &(&1 + amount))
  defp bonus(scores, _type, false, _amount), do: scores

  defp count(counts, key), do: Map.get(counts, key, 0)
end
