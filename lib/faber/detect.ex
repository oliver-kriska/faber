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

  alias Faber.Adapter
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

  # Fixed fingerprint-type order = compute-metrics.py's FINGERPRINT_KEYWORDS insertion order.
  # On a score tie, both pick the earliest type in THIS order — deterministic AND parity-matching
  # (the reference's `max(scores, key=...)` returns the first-inserted key on ties).
  @fingerprint_order ~w(bug-fix feature exploration maintenance review refactoring)

  # ── adapter-overridable detection vocab (contract §4.1) ─────────────────────
  #
  # These three module attributes are the engine's **generic defaults** — what the original
  # plugin port hardcoded. They apply ONLY when `Scan` runs adapter-free (the byte-for-byte
  # parity path). When an adapter is selected it supplies its own vocab via `detect/signatures.yaml`
  # (`fingerprint_rules` / `opportunity_rules` / `skill_namespaces` on the `Faber.Adapter`), so the
  # engine itself stays domain-free. The reference adapter `faber-elixir` restates these.

  # Command → session-type bonus. When ANY listed command is a substring of a Bash call, add
  # `bonus` to that fingerprint type. (Elixir/plugin-specific — `mix deps`/`mix hex`, `gh pr`/`issue`.)
  @default_fingerprint_rules [
    %{type: "maintenance", commands: ["mix deps", "mix hex"], bonus: 3.0},
    %{type: "review", commands: ["gh pr", "gh issue"], bonus: 3.0}
  ]

  # Missed-automation → suggested skill rules, in report order. See `rule_triggered?/2` for the
  # `when` semantics. `unless_used: false` (investigate) suggests even when already used.
  @default_opportunity_rules [
    %{skill: "investigate", when: :retry_loops, commands: [], threshold: nil, unless_used: false},
    %{skill: "plan", when: :tool_count, commands: [], threshold: 50, unless_used: true},
    %{
      skill: "verify",
      when: :commands,
      commands: ["mix test", "mix compile"],
      threshold: 3,
      unless_used: true
    },
    %{skill: "pr-review", when: :commands, commands: ["gh pr"], threshold: 2, unless_used: true},
    %{skill: "review", when: :edit_count, commands: [], threshold: 10, unless_used: true}
  ]

  # Namespace prefixes scanned as `(?:ns):skill` in session text to detect skills already used.
  @default_skill_namespaces ~w(phx ecto lv)

  # Context-window sizes by model — ported from compute-metrics.py MODEL_CONTEXT_WINDOWS and
  # EXTENDED to current models (the reference map predates opus-4-8). `[1m]` variants use the 1M
  # beta window. Unknown models → nil window → no context-pressure signal (conservative).
  @context_windows %{
    "claude-opus-4-8" => 200_000,
    "claude-opus-4-8[1m]" => 1_000_000,
    "claude-opus-4-7" => 200_000,
    "claude-opus-4-7[1m]" => 1_000_000,
    "claude-opus-4-6" => 200_000,
    "claude-opus-4-6[1m]" => 1_000_000,
    "claude-opus-4-5" => 200_000,
    "claude-opus-4-5[1m]" => 1_000_000,
    "claude-sonnet-4-6" => 200_000,
    "claude-sonnet-4-6[1m]" => 1_000_000,
    "claude-sonnet-4-5" => 200_000,
    "claude-haiku-4-5" => 200_000,
    "claude-haiku-4-5-20251001" => 200_000,
    "claude-3-5-sonnet-20241022" => 200_000,
    "claude-3-5-haiku-20241022" => 200_000
  }

  # Hard ceiling on reported context fill — a final safety net so a stale model→window map can never
  # report a nonsensical >100%.
  @max_ctx_pct 100.0

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
  # Ties break deterministically by signal name (the second tuple element) so the dominant signal
  # is reproducible run-to-run — `Enum.max_by/2` over a map is otherwise order-dependent on ties.
  defp dominant_signal(signals) do
    {signal, value} =
      Enum.max_by(signals, fn {signal, value} ->
        {value * Map.fetch!(@weights, signal), signal}
      end)

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
  each) plus tool-profile, files-edited, Tidewave, and **command-bonus rules**. Confidence =
  winning score / total score.

  `adapter` (a `Faber.Adapter` or `nil`) supplies the command-bonus rules. When `nil`, the
  engine uses its generic defaults (`mix deps`/`hex` → maintenance, `gh pr`/`issue` → review),
  keeping the adapter-free path byte-identical to the original port.
  """
  @spec fingerprint(Enumerable.t(), Faber.Adapter.t() | nil) :: fingerprint()
  def fingerprint(events, adapter \\ nil) do
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
      # Generic, engine-side bonuses (tool-ratio / files / Tidewave) — never stack-specific.
      |> bonus("exploration", read_pct > 0.5 and edit_pct < 0.1, 3.0)
      |> bonus("feature", edit_pct > 0.3, 2.0)
      |> bonus("bug-fix", bash_pct > 0.3, 2.0)
      |> bonus("refactoring", length(files) > 10, 2.0)
      |> bonus("feature", length(files) > 5, 1.0)
      |> bonus("bug-fix", tidewave?, 1.5)
      # Stack-specific command bonuses — from the adapter, or the generic defaults when adapter-free.
      |> apply_fingerprint_rules(bash_cmds, fingerprint_rules(adapter))

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

  # Apply each command-bonus rule: when any of its `commands` appears in the session's Bash calls,
  # add `bonus` to its `type`. `Map.update/4` (not `update!`) so adapter-introduced novel types are
  # created on first hit rather than crashing.
  defp apply_fingerprint_rules(scores, bash_cmds, rules) do
    Enum.reduce(rules, scores, fn %{type: type, commands: cmds, bonus: amount}, acc ->
      if any_cmd?(bash_cmds, cmds), do: Map.update(acc, type, amount, &(&1 + amount)), else: acc
    end)
  end

  @type opportunity :: %{score: float(), missed: [String.t()], used: [String.t()]}

  @doc """
  Score missed automation opportunities (0.0–1.0) and list the skills that could have
  helped but weren't used.

  Port of `compute_plugin_opportunity`, generalized to **rules**: each rule maps a friction
  condition (`when`) to a suggested skill. The generic defaults reproduce the original port —
  retry loops → `investigate`; >50 tools without `plan` → `plan`; 3+ `mix test`/`compile`
  without `verify` → `verify`; 2+ `gh pr` without `pr-review` → `pr-review`; >10 edits without
  `review` → `review`. score = min(n×0.2, 1.0).

  `adapter` (a `Faber.Adapter` or `nil`) supplies the rules and the skill namespaces used to
  detect already-used skills. When `nil`, the engine uses its generic defaults, keeping the
  adapter-free path byte-identical. Skills already used (Skill calls, `attributionSkill`,
  `/ns:cmd` in text) are excluded unless a rule sets `unless_used: false`.
  """
  @spec opportunity(Enumerable.t(), Faber.Adapter.t() | nil) :: opportunity()
  def opportunity(events, adapter \\ nil) do
    events = Enum.to_list(events)
    tool_uses = Enum.flat_map(events, & &1.tool_uses)
    names = Enum.map(tool_uses, & &1.name)
    tool_count = length(names)
    bash_cmds = bash_commands(tool_uses)
    used = used_skills(events, skill_namespaces(adapter))
    edit_count = Enum.count(names, &(&1 in ["Edit", "Write"]))

    ctx = %{bash_cmds: bash_cmds, tool_count: tool_count, edit_count: edit_count}

    missed =
      adapter
      |> opportunity_rules()
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

  @type context :: %{max_ctx_pct: float() | nil, primary_model: String.t() | nil}

  @doc """
  Context pressure: the peak prompt-token fill as a percentage of the model's context window.
  `nil` when there's no usage data or the window is unknown.

  Two cross-agent sources, preferred in order:

    * **Normalized `Event.usage`** (Codex) — the format already carries `prompt_tokens` and the
      window *inline* (Codex's model isn't in any static map), so use it directly.
    * **Per-turn `message.usage`** (Claude) — port of compute-metrics.py `extract_token_usage` /
      `get_context_window`; prompt tokens per turn = `input + cache_creation + cache_read`, window
      resolved from `message.model`.

  Feeds the `max_ctx_pct ≥ 90` tier-2 trigger.
  """
  @spec context(Enumerable.t()) :: context()
  def context(events) do
    events = Enum.to_list(events)

    case Enum.filter(events, & &1.usage) do
      [] -> context_from_message_usage(events)
      usages -> context_from_normalized_usage(usages)
    end
  end

  # Codex path: prompt fill + window come pre-normalized on the event (window is inline, not a
  # model lookup), so primary_model is left nil — Scan doesn't surface it and scoring never reads it.
  defp context_from_normalized_usage(events_with_usage) do
    peak = events_with_usage |> Enum.max_by(& &1.usage.prompt_tokens)
    %{prompt_tokens: prompt, context_window: window} = peak.usage

    %{max_ctx_pct: pct(prompt, window), primary_model: nil}
  end

  # Claude path: per-turn usage on the assistant message, window from the model map.
  defp context_from_message_usage(events) do
    peak =
      events
      |> Enum.map(&turn_prompt_tokens/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.max(fn -> nil end)

    model = primary_model(events)
    %{max_ctx_pct: pct(peak, resolve_window(model, peak)), primary_model: model}
  end

  # Peak prompt fill as a % of the window — rounded and clamped to `@max_ctx_pct`. `nil` when either
  # input is missing.
  defp pct(nil, _window), do: nil
  defp pct(_peak, nil), do: nil
  defp pct(peak, window), do: Float.round(min(peak / window * 100, @max_ctx_pct), 1)

  # The context window for a model, accounting for the 1M beta: Claude Code records the plain model
  # id (`claude-opus-4-8`) even when a session ran on the 1M window, so a peak prompt that exceeds
  # the standard window is the tell that the 1M beta was active — prefer the model's `[1m]` window
  # when one is known. Without a peak (no usage) we can't tell, so fall back to the standard window.
  defp resolve_window(nil, _peak), do: nil

  defp resolve_window(model, peak) do
    case context_window(model) do
      nil -> nil
      base when is_integer(peak) and peak > base -> onem_window(model) || base
      base -> base
    end
  end

  # Prompt tokens for one turn = input + cache_creation + cache_read; nil if the event has no
  # `message.usage` block (only assistant turns carry usage).
  defp turn_prompt_tokens(%Event{raw: raw}) when is_map(raw) do
    with %{} = msg <- Map.get(raw, "message"),
         %{} = u <- Map.get(msg, "usage") do
      num(u["input_tokens"]) + num(u["cache_creation_input_tokens"]) +
        num(u["cache_read_input_tokens"])
    else
      _ -> nil
    end
  end

  defp turn_prompt_tokens(_), do: nil

  defp num(n) when is_number(n), do: n
  defp num(_), do: 0

  # Most-frequent model across turns (ties break by name for reproducibility).
  defp primary_model(events) do
    events
    |> Enum.map(fn
      %Event{raw: raw} when is_map(raw) -> get_in(raw, ["message", "model"])
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      models -> models |> Enum.frequencies() |> Enum.max_by(fn {m, c} -> {c, m} end) |> elem(0)
    end
  end

  defp context_window(model) do
    cond do
      w = @context_windows[model] ->
        w

      w = @context_windows[String.replace_suffix(model, "[1m]", "")] ->
        w

      true ->
        Enum.find_value(@context_windows, fn {k, w} -> if String.contains?(model, k), do: w end)
    end
  end

  # The 1M-beta window for a model, if one is registered — tried exact, date-stripped, then by
  # substring against the `[1m]` keys (mirrors `context_window/1`'s cascade).
  defp onem_window(model) do
    base = String.replace(model, ~r/-\d{8}$/, "")

    @context_windows[model <> "[1m]"] || @context_windows[base <> "[1m]"] ||
      Enum.find_value(@context_windows, fn {k, w} ->
        if String.ends_with?(k, "[1m]") and
             String.contains?(model, String.replace_suffix(k, "[1m]", "")),
           do: w
      end)
  end

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

  defp bonus(scores, type, true, amount), do: Map.update!(scores, type, &(&1 + amount))
  defp bonus(scores, _type, false, _amount), do: scores

  # ── adapter vocab accessors ─────────────────────────────────────────────────
  #
  # `nil` adapter ⇒ engine defaults (the adapter-free parity path). An adapter that IS selected
  # owns its detection vocab verbatim — including an empty list, which means "none for this
  # stack" (e.g. a stack with no skill namespaces). The reference adapter restates the defaults.
  defp fingerprint_rules(nil), do: @default_fingerprint_rules
  defp fingerprint_rules(%Adapter{fingerprint_rules: rules}), do: rules

  defp opportunity_rules(nil), do: @default_opportunity_rules
  defp opportunity_rules(%Adapter{opportunity_rules: rules}), do: rules

  defp skill_namespaces(nil), do: @default_skill_namespaces
  defp skill_namespaces(%Adapter{skill_namespaces: namespaces}), do: namespaces

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
