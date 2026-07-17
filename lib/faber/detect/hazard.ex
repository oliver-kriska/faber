defmodule Faber.Detect.Hazard do
  @moduledoc """
  **Frictionless hazards** — the dangerous things a session does *without struggling*.

  Every friction signal (`Faber.Detect.Friction`) keys on **visible struggle**: retry loops,
  corrections, errored tools, thrashing, compaction, interrupts. A command that *lies about
  succeeding* produces none of them. `mix verify | tail -5; echo $?` prints `0` while verify
  really exited 8 — no error, so no retry, so no correction, so `raw` is `0.0`. That is not a
  friction signal Faber is missing; it is a different **kind** of thing, and it needs a different
  detector.

  This module is that detector. It scans tool **inputs** (what the session was about to do)
  rather than outcomes (what went wrong), so it sees a hazard whether or not the session noticed.
  Each hazard maps 1:1 onto the hook that would intercept it — `suggested_event` and `matcher`
  are the `settings.json` pointer shape — which is why the detector is the hook proposer's input
  source.

  ## Deliberately NOT part of the friction score

  Hazards are returned as their own list, never folded into `signals` and never weighted into
  `raw`. Two reasons: a hazard is not evidence the session was hard (a frictionless session with
  one hazard must still surface, and a hazard must not inflate the ranking of a session that was
  already painful); and `raw`'s weights are a calibrated port of a proven scorer
  (`.claude/research/2026-06-18-friction-scoring-calibration.md`) that a new term would silently
  recalibrate. `test/faber/detect/hazard_test.exs` asserts the separation holds.

  ## What this sees, and what it does not

  **One class**: `:pipe_masks_exit`. This module does **not** detect "silent successes" in
  general — it detects one shape of one of them. Adding a class is a `@hazard_patterns` entry,
  not a code change; until an entry exists, the hazard is invisible, and "Faber detects false
  greens" would be an over-claim.
  """

  alias Faber.Ingest.Event

  @typedoc """
  A detected hazard. `evidence` is human-readable and quotes the offending command (it seeds the
  hook proposal's prompt); `suggested_event` + `matcher` are the `settings.json` hook pointer the
  hazard implies; `tool_use` is the originating call, kept so a caller can cite it.
  """
  @type hazard :: %{
          kind: atom(),
          evidence: String.t(),
          tool_use: map(),
          suggested_event: String.t(),
          matcher: String.t()
        }

  # A command whose EXIT CODE is the point of running it — a gate. Piping one of these is what
  # makes the pipe a lie: nobody pipes `git log` for its status, everybody reads `mix verify`'s.
  @gate_command ~S"(?:mix\s+(?:verify|test(?:\.\w+)*|compile|credo|dialyzer|format)|make\s+[\w.-]+|npm\s+(?:test|run\s+[\w:-]+)|yarn\s+(?:test|[\w:-]+)|pnpm\s+(?:test|run\s+[\w:-]+)|pytest|tox|ruff\s+check|cargo\s+(?:test|build|clippy|fmt)|go\s+(?:test|build|vet)|bundle\s+exec\s+rspec|rspec|rake\s+[\w:-]+|gradle\s+[\w:-]+|mvn\s+[\w:-]+|tsc|eslint|dotnet\s+(?:test|build))"

  # Filters that swallow the gate's status by becoming the pipeline's last command. `cat`/`sort`/
  # `wc` are here for the same reason `tail` is: the shell reports THEIR exit code, and they
  # basically always succeed.
  @masking_filter ~S"(?:head|tail|tee|grep|egrep|rg|awk|sed|less|more|cat|sort|uniq|wc|jq|cut|tr|column)"

  # The hazard: <gate> … | <filter>. `[^|;&\n]*` keeps the gate and the pipe in the SAME pipeline —
  # without it, `mix test > log; git log | head` would match across the `;` and fire falsely.
  @pipe_masks_exit Regex.compile!(
                     @gate_command <> ~S"[^|;&\n]*\|\s*(?:\\\n\s*)?" <> @masking_filter
                   )

  # `set -o pipefail` (or `set -eo pipefail`) makes the pipeline return the gate's failure, which
  # is precisely the fix — a command that already did this is not a hazard.
  @pipefail ~r/\bpipefail\b/

  # Reading a status after a pipe. `$?` is the filter's status, not the gate's. `PIPESTATUS` is
  # here too and that is deliberate, not an error: it is bash-only, and Oliver's shell is zsh
  # (where the array is lowercase `pipestatus`), so `${PIPESTATUS[0]}` expands to nothing and the
  # check silently passes. Both shapes are the "I checked the exit code" that did not check it.
  @status_read ~r/(?:echo\s+[^\n]*\$\?|\$\{?PIPESTATUS|\$\{?pipestatus|\bPIPESTATUS\b)/

  # The pattern list. A new hazard class is an entry here — `kind`, the `tool` whose input to scan,
  # the `field` of that input, `require`/`refute` regexes, the hook pointer the class implies, and
  # the `explain` text that opens the evidence. `aggravator` is optional: an extra regex whose
  # presence sharpens the evidence but is NOT required to fire.
  @hazard_patterns [
    %{
      kind: :pipe_masks_exit,
      tool: "Bash",
      field: "command",
      require: [@pipe_masks_exit],
      refute: [@pipefail],
      aggravator:
        {@status_read, "and then reads a status that belongs to the filter, not the gate"},
      suggested_event: "PreToolUse",
      matcher: "Bash",
      explain:
        "a gate command is piped into a filter, so the shell reports the filter's exit code — " <>
          "the gate can fail while the pipeline reports success"
    }
  ]

  @doc """
  Scan a session's events for frictionless hazards.

  Accepts precomputed `tool_uses` so `Faber.Detect.analyze/2` shares its single traversal; the
  arity-1 form is for callers holding only events.
  """
  @spec hazards(Enumerable.t()) :: [hazard()]
  def hazards(events) do
    events = Enum.to_list(events)
    hazards(events, Enum.flat_map(events, & &1.tool_uses))
  end

  @spec hazards([Event.t()], [map()]) :: [hazard()]
  def hazards(events, tool_uses) when is_list(events) and is_list(tool_uses) do
    for tool_use <- tool_uses,
        pattern <- @hazard_patterns,
        hazard = match(pattern, tool_use),
        do: hazard
  end

  @typedoc """
  One hazard **class** as it appears on a scan result: the per-occurrence detail collapsed to the
  hook it implies, plus `count` (how many calls tripped it). `tool_use` is deliberately absent —
  see `summarize/1`.
  """
  @type summary :: %{
          kind: atom(),
          evidence: String.t(),
          suggested_event: String.t(),
          matcher: String.t(),
          count: pos_integer()
        }

  @doc """
  Collapse per-occurrence hazards to one entry per **kind** — the shape a scan result carries.

  Two things happen here, both deliberate:

    * **Dedupe by kind.** A session that pipes `mix verify` five times implies ONE hook, not five.
      Since a hazard maps 1:1 onto a hook, the kind is a total selector (`faber propose --hazard
      pipe_masks_exit`) and no ids need minting. `count` keeps the frequency honest.
    * **Drop `tool_use`.** `Faber.Scan.Result` is *persisted* (`Faber.Scan.Cache` snapshots it to
      disk), and a raw tool input map is the user's own shell history. `evidence` already quotes the
      offending command, which is all a hook proposal needs, so carrying the whole map into a
      snapshot would add a privacy surface and buy nothing. Callers wanting the originating call
      still have it on `Faber.Detect.analyze/2`'s in-memory result.

  Sorted by kind so the output is stable run-to-run.
  """
  @spec summarize([hazard()]) :: [summary()]
  def summarize(hazards) when is_list(hazards) do
    hazards
    |> Enum.group_by(& &1.kind)
    |> Enum.map(fn {kind, [first | _] = occurrences} ->
      %{
        kind: kind,
        evidence: first.evidence,
        suggested_event: first.suggested_event,
        matcher: first.matcher,
        count: length(occurrences)
      }
    end)
    |> Enum.sort_by(& &1.kind)
  end

  @doc """
  The hazard classes this module can see, as a list of atoms.

  Exposed so callers (and docs) can state the detector's coverage honestly instead of implying it
  sees every silent success.
  """
  @spec known_kinds() :: [atom()]
  def known_kinds, do: Enum.map(@hazard_patterns, & &1.kind)

  # A pattern fires on a tool call when the tool matches, the scanned field is a string, every
  # `require` matches, and no `refute` does. Anything else ⇒ nil (no hazard), which the `for`
  # comprehension's `hazard = match(...)` filter drops.
  defp match(%{tool: tool} = pattern, %{name: tool} = tool_use) do
    case field_value(tool_use, pattern.field) do
      command when is_binary(command) -> match_command(pattern, tool_use, command)
      _ -> nil
    end
  end

  defp match(_pattern, _tool_use), do: nil

  defp match_command(pattern, tool_use, command) do
    if Enum.all?(pattern.require, &Regex.match?(&1, command)) and
         not Enum.any?(pattern.refute, &Regex.match?(&1, command)) do
      %{
        kind: pattern.kind,
        evidence: evidence(pattern, command),
        tool_use: tool_use,
        suggested_event: pattern.suggested_event,
        matcher: pattern.matcher
      }
    end
  end

  defp field_value(%{input: input}, field) when is_map(input), do: Map.get(input, field)
  defp field_value(_tool_use, _field), do: nil

  # Evidence quotes the command verbatim — it is what a human reads in the scan output and what
  # seeds the hook proposal's prompt, so the offending text must survive intact. Trimmed to keep a
  # heredoc-sized command from flooding a report.
  defp evidence(pattern, command) do
    base = "`#{excerpt(command)}` — #{pattern.explain}"

    case pattern[:aggravator] do
      {regex, note} -> if Regex.match?(regex, command), do: base <> ", " <> note, else: base
      nil -> base
    end
  end

  @excerpt_limit 200

  defp excerpt(command) do
    collapsed = command |> String.split() |> Enum.join(" ")

    if String.length(collapsed) > @excerpt_limit,
      do: String.slice(collapsed, 0, @excerpt_limit) <> "…",
      else: collapsed
  end
end
