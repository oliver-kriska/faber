defmodule Faber.LLM.Stub do
  @moduledoc """
  Deterministic `Faber.LLM` implementation for tests and offline runs — no network, no key.

  Returns the map passed as `opts[:stub_response]` when given, otherwise a canned proposal
  shaped like a real `generate_object` result (the keys `Faber.Propose` expects). This lets the
  whole proposer → eval → loop pipeline be exercised end to end without an LLM.
  """

  @behaviour Faber.LLM

  @impl Faber.LLM
  def generate_object(_prompt, _schema, opts) do
    {:ok, Keyword.get(opts, :stub_response, default_proposal())}
  end

  @doc "The canned proposal returned when no `:stub_response` is supplied."
  @spec default_proposal() :: map()
  def default_proposal do
    %{
      "name" => "investigate-retry-loops",
      "description" =>
        "Investigate failing shell commands systematically — read the error, form a " <>
          "hypothesis, change one thing. Use when the same command is retried after an error, " <>
          "before blindly re-running. NOT for first-time command failures.",
      "effort" => "low",
      "rationale" =>
        "The session showed repeated same-command retries after errored results — a " <>
          "structured investigate step would have cut the retry loop short.",
      "iron_laws" => [
        "Read the actual error output before retrying — never re-run blind.",
        "Change exactly one variable per attempt so the result is attributable.",
        "After 3 failed attempts, stop and escalate with what was tried."
      ],
      "usage" => "Triggered automatically when a command is retried after a failure.",
      "example" => "mix test --failed   # re-run only what broke, after reading the error",
      "should_trigger" => [
        "the same mix command keeps failing and I keep re-running it",
        "this git command errored, let me try it again"
      ],
      "should_not_trigger" => [
        "run the test suite once",
        "what does this Elixir function do"
      ]
    }
  end
end
