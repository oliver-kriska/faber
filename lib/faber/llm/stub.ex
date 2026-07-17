defmodule Faber.LLM.Stub do
  @moduledoc """
  Deterministic `Faber.LLM` implementation for tests and offline runs — no network, no key.

  Returns the map passed as `opts[:stub_response]` when given, otherwise a canned proposal
  shaped like a real `generate_object` result (the keys `Faber.Propose` expects). This lets the
  whole proposer → eval → loop pipeline be exercised end to end without an LLM.

  The canned answer follows the **schema it was asked to fill**, because a real model would: a
  stub that always returned a skill would hand `Faber.Propose.build_hook_proposal/4` a map with no
  `event`/`matcher`/`script` and produce a hook of `nil`s, so every hermetic hook test would be
  exercising the failure path while looking like it passed.
  """

  @behaviour Faber.LLM

  alias Faber.Propose

  @impl Faber.LLM
  def generate_object(_prompt, schema, opts) do
    {:ok, Keyword.get_lazy(opts, :stub_response, fn -> canned(schema) end)}
  end

  # Keyed off the schema's own identity rather than a shape guess: the two schemas are disjoint by
  # design, so if `hook_schema/0` gains a field this keeps answering the right one.
  defp canned(schema) do
    if schema == Propose.hook_schema(), do: default_hook(), else: default_proposal()
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

  @doc """
  The canned **hook** returned when the proposer asks for `Faber.Propose.hook_schema/0`.

  Answers the one hazard class `Faber.Detect.Hazard` detects (`:pipe_masks_exit`), so the
  hazard → hook → eval → install path has a deterministic subject.
  """
  @spec default_hook() :: map()
  def default_hook do
    %{
      "name" => "no-masked-gate-exit",
      "description" =>
        "Blocks piping a gate command (mix verify/test/credo) into head/tail/grep, which makes " <>
          "the shell report the filter's exit code. Use when a gate's status is the point of " <>
          "running it. NOT for piping ordinary output-producing commands.",
      "rationale" =>
        "The hazard produces no friction at all — the pipeline reports success — so no skill " <>
          "would ever be triggered by it. Only an interception before the command runs helps.",
      "event" => "PreToolUse",
      "matcher" => "Bash",
      "script" => """
      #!/usr/bin/env bash
      input=$(cat)
      command=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')

      # `set -o pipefail` already propagates the gate's failure — that form is the fix, not the hazard.
      case "$command" in *pipefail*) exit 0 ;; esac

      if printf '%s' "$command" | grep -Eq '(mix (verify|test|compile|credo|dialyzer)|make [a-z.-]+)[^|;&]*\\| *(head|tail|grep|tee)'; then
        echo "This pipes a gate command into a filter, so the exit code you read is the filter's," >&2
        echo "not the gate's — it can report success while the gate failed. Redirect to a log" >&2
        echo "instead, then check the status: mix verify > /tmp/v.log 2>&1; echo \$?" >&2
        exit 2
      fi

      exit 0
      """
    }
  end
end
