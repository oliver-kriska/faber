defmodule Faber.Detect do
  @moduledoc """
  **Stage 2 — Detect.** Score friction over a session's normalized events.

  This is the engine's **generic** friction scorer — a faithful port of the algorithm
  proven in the reference plugin's `session-scan` (`scoring-guide.md` / `compute-metrics.py`).
  It is agent-level (it reads Claude Code transcript shapes), not stack-specific; an
  adapter's `detect/` signatures layer **on top** of this baseline.

  ## Friction score

      raw   = Σ (signal_value × weight)
      score = sigmoid(raw) = 1 / (1 + e^(-k × (raw - midpoint)))     # k = 3.0, midpoint = 1.5

  Signals and native weights (from the scoring guide):

  | signal | weight | value |
  |---|---|---|
  | `retry_loops` | 3.0 | runs of the same Bash command (3+ consecutive) **with a failed result among them** |
  | `user_corrections` | 2.5 | human messages matching the correction regex |

  > **Deliberate improvement over the source.** `compute-metrics.py` *documents*
  > `retry_loops` as "same command 3+ times with failures between" but its implementation
  > never checks for failures — it counts any consecutive same-first-token Bash calls, which
  > over-fires on normal sequential workflows (`git …`, `cd …`). Faber implements the
  > *intended* semantic: a run only counts when it contains an errored result, keyed on a
  > 2-token command prefix. See `.claude/research/2026-06-18-friction-scoring-calibration.md`.
  | `error_tool_ratio` | 2.0 | error_count / tool_count |
  | `approach_changes` | 2.0 | dominant-tool transitions across the 4 session quarters |
  | `context_compactions` | 1.5 | context-compaction system events |
  | `interrupted_requests` | 1.0 | `[Request interrupted by user]` occurrences |
  """

  alias Faber.Ingest.Event

  @sigmoid_k 3.0
  @sigmoid_midpoint 1.5

  @weights %{
    retry_loops: 3.0,
    user_corrections: 2.5,
    error_tool_ratio: 2.0,
    approach_changes: 2.0,
    context_compactions: 1.5,
    interrupted_requests: 1.0
  }

  # Applied to the first 500 chars of each human message (from scoring-guide.md).
  @correction_regex ~r/\b(no[,.]?\s|wrong|instead|actually|that's not|not what I|I meant|I said|please don't|stop|undo|revert)\b/

  @interrupt_marker "[Request interrupted by user]"

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

  # Leading whitespace tokens of a Bash command that define its "prefix" for retry
  # detection (e.g. `mix test`, `git commit`). 2 groups re-runs of the same command while
  # still separating `mix test` from `mix deps.get`.
  @bash_prefix_tokens 2

  @type signals :: %{
          retry_loops: non_neg_integer(),
          user_corrections: non_neg_integer(),
          error_tool_ratio: float(),
          approach_changes: non_neg_integer(),
          context_compactions: non_neg_integer(),
          interrupted_requests: non_neg_integer()
        }

  @type friction :: %{
          score: float(),
          raw: float(),
          signals: signals(),
          dominant_signal: atom() | nil,
          tool_count: non_neg_integer(),
          error_count: non_neg_integer(),
          message_count: non_neg_integer()
        }

  @doc """
  Compute the friction score (and its component signals) for a session's events.
  """
  @spec friction(Enumerable.t()) :: friction()
  def friction(events) do
    events = Enum.to_list(events)

    tool_uses = Enum.flat_map(events, & &1.tool_uses)
    tool_count = length(tool_uses)
    error_count = count_errors(events)

    signals = %{
      retry_loops: count_retry_loops(tool_uses, error_index(events)),
      user_corrections: count_corrections(events),
      error_tool_ratio: ratio(error_count, tool_count),
      approach_changes: count_approach_changes(tool_uses),
      context_compactions: count_compactions(events),
      interrupted_requests: count_interrupts(events)
    }

    raw =
      Enum.reduce(signals, 0.0, fn {signal, value}, acc ->
        acc + value * Map.fetch!(@weights, signal)
      end)

    %{
      score: sigmoid(raw),
      raw: raw,
      signals: signals,
      dominant_signal: dominant_signal(signals),
      tool_count: tool_count,
      error_count: error_count,
      message_count: Enum.count(events, &(&1.type in [:user, :assistant]))
    }
  end

  # The signal contributing the most to `raw` (value × weight); nil when there is no friction.
  defp dominant_signal(signals) do
    {signal, value} =
      Enum.max_by(signals, fn {signal, value} -> value * Map.fetch!(@weights, signal) end)

    if value > 0, do: signal, else: nil
  end

  @doc """
  Tool-usage profile: percentage breakdown of tool calls by category.
  """
  @spec tool_profile(Enumerable.t()) :: %{optional(atom()) => float()}
  def tool_profile(events) do
    names = events |> Enum.flat_map(& &1.tool_uses) |> Enum.map(& &1.name)
    total = length(names)

    empty = %{read: 0, edit: 0, bash: 0, grep: 0, tidewave: 0, other: 0}

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
  defp categorize_tool("mcp__tidewave" <> _), do: :tidewave
  defp categorize_tool(_), do: :other

  @type fingerprint :: %{type: String.t(), confidence: float()}

  @doc """
  Classify the session type — `bug-fix` / `feature` / `exploration` / `maintenance` /
  `review` / `refactoring` (or `unknown`) — with a confidence in 0.0–1.0.

  Port of `compute_fingerprint`: keyword matches over the first 10 human messages (×2.0
  each) plus tool-profile, files-edited, Tidewave, `mix deps`/`hex`, and `gh pr`/`issue`
  bonuses. Confidence = winning score / total score.
  """
  @spec fingerprint(Enumerable.t()) :: fingerprint()
  def fingerprint(events) do
    events = Enum.to_list(events)

    user_text =
      events
      |> Enum.filter(&Event.human_turn?/1)
      |> Enum.take(10)
      |> Enum.map_join(" ", & &1.text)

    tool_uses = Enum.flat_map(events, & &1.tool_uses)
    names = Enum.map(tool_uses, & &1.name)
    total = max(length(names), 1)
    counts = Enum.frequencies(names)

    read_pct = (count(counts, "Read") + count(counts, "Grep") + count(counts, "Glob")) / total
    edit_pct = (count(counts, "Edit") + count(counts, "Write")) / total
    bash_pct = count(counts, "Bash") / total

    bash_cmds = bash_commands(tool_uses)
    files = files_edited(tool_uses)
    tidewave? = Enum.any?(names, &String.starts_with?(&1, "mcp__tidewave"))

    scores =
      @fingerprint_keywords
      |> Map.new(fn {type, re} -> {type, length(Regex.scan(re, user_text)) * 2.0} end)
      |> bonus("exploration", read_pct > 0.5 and edit_pct < 0.1, 3.0)
      |> bonus("feature", edit_pct > 0.3, 2.0)
      |> bonus("bug-fix", bash_pct > 0.3, 2.0)
      |> bonus("refactoring", length(files) > 10, 2.0)
      |> bonus("feature", length(files) > 5, 1.0)
      |> bonus("bug-fix", tidewave?, 1.5)
      |> bonus("maintenance", any_cmd?(bash_cmds, ["mix deps", "mix hex"]), 3.0)
      |> bonus("review", any_cmd?(bash_cmds, ["gh pr", "gh issue"]), 3.0)

    total_score = scores |> Map.values() |> Enum.sum()

    if total_score <= 0.0 do
      %{type: "unknown", confidence: 0.0}
    else
      {best, best_score} = Enum.max_by(scores, fn {_type, score} -> score end)
      %{type: best, confidence: Float.round(best_score / total_score, 2)}
    end
  end

  @type opportunity :: %{score: float(), missed: [String.t()], used: [String.t()]}

  @doc """
  Score missed automation opportunities (0.0–1.0) and list the skills that could have
  helped but weren't used.

  Port of `compute_plugin_opportunity`: retry loops → `investigate`; >50 tools without
  `plan` → `plan`; 3+ `mix test`/`compile` without `verify` → `verify`; 2+ `gh pr` without
  `pr-review` → `pr-review`; >10 edits without `review` → `review`. score = min(n×0.2, 1.0).
  Skills already used (Skill calls, `attributionSkill`, `/ns:cmd` in text) are excluded.
  """
  @spec opportunity(Enumerable.t()) :: opportunity()
  def opportunity(events) do
    events = Enum.to_list(events)
    tool_uses = Enum.flat_map(events, & &1.tool_uses)
    names = Enum.map(tool_uses, & &1.name)
    tool_count = length(names)
    bash_cmds = bash_commands(tool_uses)
    used = used_skills(events)
    edit_count = Enum.count(names, &(&1 in ["Edit", "Write"]))

    missed =
      []
      |> add_if(investigate_opportunity?(bash_cmds), "investigate")
      |> add_if(tool_count > 50 and not used?(used, "plan"), "plan")
      |> add_if(
        count_cmds(bash_cmds, ["mix test", "mix compile"]) >= 3 and not used?(used, "verify"),
        "verify"
      )
      |> add_if(
        count_cmds(bash_cmds, ["gh pr"]) >= 2 and not used?(used, "pr-review"),
        "pr-review"
      )
      |> add_if(edit_count > 10 and not used?(used, "review"), "review")
      |> Enum.reverse()

    %{
      score: Float.round(min(length(missed) * 0.2, 1.0), 2),
      missed: missed,
      used: Enum.sort(MapSet.to_list(used))
    }
  end

  defp add_if(list, true, item), do: [item | list]
  defp add_if(list, false, _item), do: list

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
  defp used_skills(events) do
    from_text =
      events
      |> Enum.filter(&is_binary(&1.text))
      |> Enum.flat_map(fn e ->
        Regex.scan(~r/(?:phx|ecto|lv):([a-z][a-z0-9_-]*)/i, e.text, capture: :all_but_first)
      end)
      |> List.flatten()

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

  defp bonus(scores, type, true, amount), do: Map.update!(scores, type, &(&1 + amount))
  defp bonus(scores, _type, false, _amount), do: scores

  defp count(counts, key), do: Map.get(counts, key, 0)

  defp any_cmd?(bash_cmds, needles) do
    Enum.any?(bash_cmds, fn cmd -> Enum.any?(needles, &String.contains?(cmd, &1)) end)
  end

  defp bash_commands(tool_uses) do
    tool_uses
    |> Enum.filter(&(&1.name == "Bash"))
    |> Enum.map(fn tu -> to_string(tu.input["command"] || "") end)
  end

  defp files_edited(tool_uses) do
    tool_uses
    |> Enum.filter(&(&1.name in ["Edit", "Write", "NotebookEdit"]))
    |> Enum.map(fn tu -> tu.input["file_path"] end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp count_errors(events) do
    events
    |> Enum.flat_map(& &1.tool_results)
    |> Enum.count(& &1.is_error)
  end

  # Map of tool_use_id => errored?, so a Bash call can be linked to its result.
  defp error_index(events) do
    events
    |> Enum.flat_map(& &1.tool_results)
    |> Map.new(fn r -> {r.tool_use_id, r.is_error} end)
  end

  # Runs of the same Bash command prefix (length >= 3) that contain at least one failed
  # result — i.e. the repeats were driven by failures, not normal sequential work.
  defp count_retry_loops(tool_uses, error_index) do
    tool_uses
    |> Enum.filter(&(&1.name == "Bash"))
    |> Enum.map(fn tu -> {bash_prefix(tu), Map.get(error_index, tu.id, false)} end)
    |> Enum.chunk_by(fn {prefix, _errored?} -> prefix end)
    |> Enum.count(fn run ->
      length(run) >= 3 and Enum.any?(run, fn {_prefix, errored?} -> errored? end)
    end)
  end

  defp bash_prefix(%{input: %{"command" => cmd}}) when is_binary(cmd) do
    cmd |> String.split() |> Enum.take(@bash_prefix_tokens) |> Enum.join(" ")
  end

  defp bash_prefix(_), do: ""

  defp count_corrections(events) do
    events
    |> Enum.filter(&Event.human_turn?/1)
    |> Enum.count(fn %Event{text: text} ->
      text |> String.slice(0, 500) |> then(&Regex.match?(@correction_regex, &1))
    end)
  end

  defp count_interrupts(events) do
    events
    |> Enum.filter(&(&1.type == :user and is_binary(&1.text)))
    |> Enum.count(&String.contains?(&1.text, @interrupt_marker))
  end

  # Events that mark a context compaction. The proven scorer matches the literal
  # "context compaction" in message text; we also honor the modern transcript markers.
  defp count_compactions(events) do
    Enum.count(events, fn %Event{} = e ->
      e.raw["isCompactSummary"] == true or
        e.raw["subtype"] in ["compact", "compact_boundary"] or
        (is_binary(e.text) and String.contains?(String.downcase(e.text), "context compact"))
    end)
  end

  # Split the tool sequence into ~4 chunks, take each chunk's dominant tool, count
  # transitions between differing dominants. Per the proven scorer, only sessions with at
  # least 10 tool calls are eligible (smaller ones aren't meaningfully "thrashing").
  defp count_approach_changes(tool_uses) when length(tool_uses) < 10, do: 0

  defp count_approach_changes(tool_uses) do
    names = Enum.map(tool_uses, & &1.name)
    chunk = max(div(length(names), 4), 5)

    names
    |> Enum.chunk_every(chunk)
    |> Enum.map(&dominant/1)
    |> count_transitions()
  end

  defp dominant(names) do
    names
    |> Enum.frequencies()
    |> Enum.max_by(fn {_name, count} -> count end)
    |> elem(0)
  end

  defp count_transitions(seq) do
    seq
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.count(fn [a, b] -> a != b end)
  end

  defp ratio(_num, 0), do: 0.0
  defp ratio(num, denom), do: num / denom

  defp sigmoid(raw), do: 1.0 / (1.0 + :math.exp(-@sigmoid_k * (raw - @sigmoid_midpoint)))
end
