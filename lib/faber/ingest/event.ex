defmodule Faber.Ingest.Event do
  @moduledoc """
  A normalized coding-agent transcript event — the engine-internal shape that
  `Faber.Ingest` produces and `Faber.Detect` consumes, independent of any one agent's
  on-disk format.

  Built from a single Claude Code `*.jsonl` line for v1; other agents map onto the same
  struct later. The original decoded line is kept in `:raw` (string keys) so nothing is
  lost.
  """

  @type tool_use :: %{name: String.t(), input: map(), id: String.t() | nil}
  @type tool_result :: %{tool_use_id: String.t() | nil, is_error: boolean()}

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
