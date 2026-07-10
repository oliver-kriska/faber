defmodule Faber.Detect.Context do
  @moduledoc """
  Context pressure: the peak prompt-token fill as a percentage of the model's context window —
  port of `compute-metrics.py`'s `extract_token_usage` / `get_context_window`, extended with
  the normalized cross-agent `Event.usage` source. Feeds the `max_ctx_pct ≥ 90` tier-2 trigger.
  """

  alias Faber.Ingest.Event

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

  @type context :: %{max_ctx_pct: float() | nil, primary_model: String.t() | nil}

  @doc """
  Peak prompt-token fill as a percentage of the model's context window; `nil` when there is no
  usage data or the window is unknown. See `Faber.Detect.context/1`.

  Two cross-agent sources, preferred in order:

    * **Normalized `Event.usage`** (Codex) — the format already carries `prompt_tokens` and the
      window *inline* (Codex's model isn't in any static map), so use it directly.
    * **Per-turn `message.usage`** (Claude) — prompt tokens per turn =
      `input + cache_creation + cache_read`, window resolved from `message.model`.
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

  # Most-frequent model across turns (ties break by name for reproducibility). Pattern-matched
  # (not `get_in`) and filtered to binaries: `message` / `model` come from untrusted transcript
  # JSON, so a non-map message or non-string model must be skipped, not crash the scan.
  defp primary_model(events) do
    events
    |> Enum.map(fn
      %Event{raw: %{"message" => %{"model" => model}}} -> model
      _ -> nil
    end)
    |> Enum.filter(&is_binary/1)
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
end
