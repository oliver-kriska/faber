defmodule Faber.Detect.Friction do
  @moduledoc """
  The generic friction scorer — a faithful port of the algorithm proven in the reference
  plugin's `session-scan` (`scoring-guide.md` / `compute-metrics.py`).

      raw   = Σ (signal_value × weight)
      score = sigmoid(raw) = 1 / (1 + e^(-k × (raw - midpoint)))     # k = 3.0, midpoint = 1.5

  Signals and native weights (from the scoring guide):

  | signal | weight | value |
  |---|---|---|
  | `retry_loops` | 3.0 | runs of the same Bash command (3+ consecutive) **with a failed result among them** |
  | `user_corrections` | 2.5 | human messages matching the correction regex (human turns only — see `Event.human_turn?/1`) |

  > **Deliberate improvement over the source.** `compute-metrics.py` *documents*
  > `retry_loops` as "same command 3+ times with failures between" but its implementation
  > never checks for failures — it counts any consecutive same-first-token Bash calls, which
  > over-fires on normal sequential workflows (`git …`, `cd …`). Faber implements the
  > *intended* semantic: a run only counts when it contains an errored result.
  > See `.claude/research/2026-06-18-friction-scoring-calibration.md`.
  >
  > **Command identity is the full normalized command, not a token prefix.** The 2026-07-15 audit
  > found 0 of 7 detected loops in `faber/31f10cff` were genuine: a 2-token prefix collides under
  > the `cd /abs/path && …` convention that our own agent instructions mandate — one "loop" grouped
  > 93 distinct commands behind `cd /Users/…`. `git add a/b/c`, `mise exec -- …` and `echo …`
  > collide the same way. Since this is the **highest-weighted signal (3.0)**, the collisions
  > structurally inflated the ranking. So: strip the `cd` preamble, key on the whole command, and
  > accept lower recall (a retry with a tweaked flag no longer groups) for precision on a signal
  > whose recall was 100% noise. See
  > `.claude/research/2026-07-15-faber-scan-propose-verification.md`.
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

  # A leading `cd <path>` segment, joined to the rest by `&&`, `;`, or a newline. Agent
  # instructions across this repo (and the plugin) mandate `cd /abs/path && <cmd>`, so the
  # directory hop is boilerplate, not part of the command's identity.
  @cd_prefix_regex ~r/\A\s*cd\s+(?:'[^']*'|"[^"]*"|\S+)\s*(?:&&|;|\n)\s*/

  @type signals :: %{
          retry_loops: non_neg_integer(),
          user_corrections: non_neg_integer(),
          error_tool_ratio: float(),
          approach_changes: non_neg_integer(),
          context_compactions: non_neg_integer(),
          interrupted_requests: non_neg_integer()
        }

  @typedoc """
  `message_count` counts transcript **events** (user + assistant lines), not turns — a single
  human turn can fan out into hundreds of them. `human_turns` is the honest count of messages a
  person actually typed (see `Event.human_turn?/1`); on the audited session the two read 9161 vs
  ≤137. Both are reported: `message_count` still drives the existing gates (t2, `--min-messages`,
  dedupe), so its semantics are unchanged here — only the display got honest.
  """
  @type friction :: %{
          score: float(),
          raw: float(),
          signals: signals(),
          dominant_signal: atom() | nil,
          tool_count: non_neg_integer(),
          error_count: non_neg_integer(),
          message_count: non_neg_integer(),
          human_turns: non_neg_integer()
        }

  @doc """
  Compute the friction score (and its component signals) for a session's events.

  `friction/2` accepts the session's precomputed `tool_uses` so `Faber.Detect.analyze/2` can
  share one traversal across all detection domains.
  """
  @spec friction(Enumerable.t()) :: friction()
  def friction(events) do
    events = Enum.to_list(events)
    friction(events, Enum.flat_map(events, & &1.tool_uses))
  end

  @spec friction([Event.t()], [map()]) :: friction()
  def friction(events, tool_uses) when is_list(events) and is_list(tool_uses) do
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
      message_count: Enum.count(events, &(&1.type in [:user, :assistant])),
      human_turns: Enum.count(events, &Event.human_turn?/1)
    }
  end

  # The signal contributing the most to `raw` (value × weight); nil when there is no friction.
  # Ties break deterministically by signal name (the second tuple element) so the dominant signal
  # is reproducible run-to-run — `Enum.max_by/2` over a map is otherwise order-dependent on ties.
  defp dominant_signal(signals) do
    {signal, value} =
      Enum.max_by(signals, fn {signal, value} ->
        {value * Map.fetch!(@weights, signal), signal}
      end)

    if value > 0, do: signal, else: nil
  end

  defp count_errors(events) do
    events
    |> Enum.flat_map(& &1.tool_results)
    |> Enum.count(& &1.is_error)
  end

  # Map of tool_use_id => errored?, so a Bash call can be linked to its result. `nil` ids are
  # skipped (id-less results from Gemini/OpenCode would otherwise collapse onto one key), and
  # duplicate ids union their error flags — one failed result marks the call failed, so a later
  # success can't silently overwrite it.
  defp error_index(events) do
    events
    |> Enum.flat_map(& &1.tool_results)
    |> Enum.reject(&is_nil(&1.tool_use_id))
    |> Enum.reduce(%{}, fn r, acc ->
      Map.update(acc, r.tool_use_id, r.is_error, &(&1 or r.is_error))
    end)
  end

  # Consecutive runs (>= 3) of the *same normalized command* that contain at least one failed
  # result — i.e. the repeats were driven by failures, not normal sequential work.
  #
  # `chunk_by` (not `group_by`) is deliberate: a retry loop is consecutive repetition. Grouping
  # session-wide would join a command run at 09:00 with the same command at 17:00 and call it a
  # loop.
  defp count_retry_loops(tool_uses, error_index) do
    tool_uses
    |> Enum.filter(&(&1.name == "Bash"))
    |> Enum.flat_map(fn tu ->
      # A Bash call with no usable command contributes nothing rather than collapsing onto a
      # shared "" key — otherwise a few malformed calls next to one error fake a loop.
      case normalized_command(tu) do
        nil -> []
        cmd -> [{cmd, Map.get(error_index, tu.id, false)}]
      end
    end)
    |> Enum.chunk_by(fn {cmd, _errored?} -> cmd end)
    |> Enum.count(fn run ->
      length(run) >= 3 and Enum.any?(run, fn {_cmd, errored?} -> errored? end)
    end)
  end

  # Identity for retry detection: the full command, minus the `cd <path> &&` preamble that agent
  # instructions mandate, with whitespace collapsed. Returns nil when there is no command to key on.
  defp normalized_command(%{input: %{"command" => cmd}}) when is_binary(cmd) do
    cmd
    |> strip_cd_prefix()
    |> String.split()
    |> Enum.join(" ")
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalized_command(_), do: nil

  # `cd /abs/path && …` chains can stack (`cd a && cd b && cmd`), so strip repeatedly.
  defp strip_cd_prefix(cmd) do
    case Regex.replace(@cd_prefix_regex, cmd, "", global: false) do
      ^cmd -> cmd
      stripped -> strip_cd_prefix(stripped)
    end
  end

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

  # Most-frequent tool in a chunk; ties break by FIRST APPEARANCE in the chunk (Enum.max_by over
  # the first-seen order), matching Python Counter.most_common — deterministic AND parity-matching.
  defp dominant(names) do
    freq = Enum.frequencies(names)

    names
    |> Enum.uniq()
    |> Enum.max_by(&Map.fetch!(freq, &1))
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
