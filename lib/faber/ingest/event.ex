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

  ## `:synthetic` vs `:is_meta` — two different claims

  `:is_meta` mirrors the transcript's own `isMeta` flag: the *agent* declared this line
  internal. `:synthetic` is Faber's own classification — the line is *shaped* like a user turn
  but its content was written by the harness (task notifications, teammate messages, command
  stdout, system reminders) rather than typed by a human. Only a format module, which knows
  what its agent's injected blocks look like, may set it; `Faber.Detect` just consumes
  `human_turn?/1` and stays agent-agnostic. They stay separate because they can disagree: a
  line can be harness-authored without the agent flagging it `isMeta`, which is exactly the
  case that was polluting the correction signal.
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
          synthetic: boolean(),
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
            synthetic: false,
            usage: nil,
            cwd: nil,
            raw: %{}

  @doc """
  A human turn: a `:user` event carrying actual text (not a tool-result-only turn), not an
  internal/meta marker, and not harness-synthesized (`:synthetic`). Used to scope friction
  signals like corrections to real user messages.

  The `:synthetic` gate is load-bearing, not cosmetic: agents write their own machinery back
  into the transcript as `role: "user"` turns. A 2026-07-15 audit of real sessions found 27 of
  30 detected "user corrections" in one session were `<task-notification>` blocks — a
  background task reporting "fix applied, no errors" trips the correction regex exactly like a
  human saying "no, fix that instead". See
  `.claude/research/2026-07-15-faber-scan-propose-verification.md`.
  """
  @spec human_turn?(t()) :: boolean()
  def human_turn?(%__MODULE__{type: :user, text: text, is_meta: false, synthetic: false})
      when is_binary(text),
      do: String.trim(text) != ""

  def human_turn?(%__MODULE__{}), do: false
end
