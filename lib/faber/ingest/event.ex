defmodule Faber.Ingest.Event do
  @moduledoc """
  A normalized coding-agent transcript event — the engine-internal shape that
  `Faber.Ingest` produces and `Faber.Detect` consumes, independent of any one agent's
  on-disk format.

  Built from a single Claude Code `*.jsonl` line for v1; other agents (e.g. Codex —
  `Faber.Ingest.Format.Codex`) map onto the same struct. The original decoded line is kept in
  `:raw` (string keys) so nothing is lost.

  ## `:usage` — the cross-agent context-pressure seam

  Claude carries per-turn token usage *on the assistant message* (`raw.message.usage`) and the
  context window is derived from `raw.message.model`; `Faber.Detect.context/1` reads those
  directly, so the Claude format leaves `:usage` `nil`. Codex instead emits usage in a standalone
  `token_count` event **with the window inline** (and a model — GPT-5 — that isn't in any static
  window map), so its format normalizes that into `:usage`. `Detect.context/1` prefers `:usage`
  when present, keeping the friction scorer genuinely agent-agnostic.
  """

  @type tool_use :: %{name: String.t(), input: map(), id: String.t() | nil}
  @type tool_result :: %{tool_use_id: String.t() | nil, is_error: boolean()}

  @typedoc """
  Normalized per-turn token usage for context-pressure, or `nil` when the format carries usage
  elsewhere (Claude — read from `raw.message.usage`). `prompt_tokens` is the prompt fill for the
  turn; `context_window` is the model's window (`nil` if unknown → no pressure signal).
  """
  @type usage :: %{prompt_tokens: non_neg_integer(), context_window: pos_integer() | nil}

  @type t :: %__MODULE__{
          type: :user | :assistant | :system | :summary | :other,
          role: String.t() | nil,
          timestamp: DateTime.t() | nil,
          uuid: String.t() | nil,
          parent_uuid: String.t() | nil,
          session_id: String.t() | nil,
          text: String.t() | nil,
          tool_uses: [tool_use()],
          tool_results: [tool_result()],
          is_meta: boolean(),
          usage: usage() | nil,
          cwd: String.t() | nil,
          raw: map()
        }

  defstruct type: :other,
            role: nil,
            timestamp: nil,
            uuid: nil,
            parent_uuid: nil,
            session_id: nil,
            text: nil,
            tool_uses: [],
            tool_results: [],
            is_meta: false,
            usage: nil,
            cwd: nil,
            raw: %{}

  @doc """
  A human turn: a `:user` event carrying actual text (not a tool-result-only turn) and not
  an internal/meta marker. Used to scope friction signals like corrections to real user
  messages.
  """
  @spec human_turn?(t()) :: boolean()
  def human_turn?(%__MODULE__{type: :user, text: text, is_meta: false}) when is_binary(text),
    do: String.trim(text) != ""

  def human_turn?(%__MODULE__{}), do: false
end
