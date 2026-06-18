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
  | `retry_loops` | 3.0 | runs of the same Bash command prefix repeated 3+ consecutively |
  | `user_corrections` | 2.5 | human messages matching the correction regex |
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

  # How many leading whitespace tokens of a Bash command define its "prefix" for retry
  # detection (so `mix test foo` re-runs collapse, but `mix test` vs `mix compile` don't).
  @bash_prefix_tokens 3

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
      retry_loops: count_retry_loops(tool_uses),
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
      tool_count: tool_count,
      error_count: error_count,
      message_count: Enum.count(events, &(&1.type in [:user, :assistant]))
    }
  end

  @doc """
  Tool-usage profile: percentage breakdown of tool calls by category.
  """
  @spec tool_profile(Enumerable.t()) :: %{optional(atom()) => float()}
  def tool_profile(events) do
    names = events |> Enum.flat_map(& &1.tool_uses) |> Enum.map(& &1.name)
    total = length(names)

    if total == 0 do
      %{read: 0.0, edit: 0.0, bash: 0.0, grep: 0.0, other: 0.0}
    else
      names
      |> Enum.reduce(%{read: 0, edit: 0, bash: 0, grep: 0, other: 0}, fn name, acc ->
        Map.update!(acc, categorize_tool(name), &(&1 + 1))
      end)
      |> Map.new(fn {cat, n} -> {cat, n / total} end)
    end
  end

  defp categorize_tool(name) when name in ["Read", "Glob"], do: :read
  defp categorize_tool(name) when name in ["Edit", "Write", "NotebookEdit"], do: :edit
  defp categorize_tool("Bash"), do: :bash
  defp categorize_tool("Grep"), do: :grep
  defp categorize_tool(_), do: :other

  defp count_errors(events) do
    events
    |> Enum.flat_map(& &1.tool_results)
    |> Enum.count(& &1.is_error)
  end

  # Consecutive runs (length >= 3) of the same Bash command prefix.
  defp count_retry_loops(tool_uses) do
    tool_uses
    |> Enum.filter(&(&1.name == "Bash"))
    |> Enum.map(&bash_prefix/1)
    |> Enum.chunk_by(& &1)
    |> Enum.count(&(length(&1) >= 3))
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

  # System events (or any event) that mark a context compaction.
  defp count_compactions(events) do
    Enum.count(events, fn %Event{} = e ->
      e.raw["isCompactSummary"] == true or
        e.raw["subtype"] in ["compact", "compact_boundary"] or
        (e.type == :system and is_binary(e.text) and e.text =~ ~r/compact/i)
    end)
  end

  # Split the tool sequence into 4 quarters, take each quarter's dominant tool, count
  # transitions between different dominant tools.
  defp count_approach_changes(tool_uses) when length(tool_uses) < 4, do: 0

  defp count_approach_changes(tool_uses) do
    names = Enum.map(tool_uses, & &1.name)
    chunk = max(div(length(names), 4), 1)

    names
    |> Enum.chunk_every(chunk)
    |> Enum.take(4)
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
