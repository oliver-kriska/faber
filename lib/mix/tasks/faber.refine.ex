defmodule Mix.Tasks.Faber.Refine do
  @shortdoc "Self-improve a skill for the highest-friction session (propose → eval → keep loop)"
  @moduledoc """
  Dev-mode entry to the self-improving loop — the same command the release binary exposes as
  `faber refine`. Scans your sessions, seeds a proposal for the ranked session, then loops
  propose → eval → keep-the-best (reflective by default: each candidate is a targeted edit of
  the current best, driven by its weakest eval dimension).

      mix faber.refine                          # rank-1 session, 5 reflective iterations
      mix faber.refine --rank 2 --iterations 3
      mix faber.refine --trigger --holdout      # also optimize routing recall (pinned fixtures)
      mix faber.refine --install                # install the final best skill

  With the dev default (`Faber.LLM.ClaudeCLI`) this needs **no API key** — every iteration
  drives your local `claude -p`, so budget minutes per iteration. Same flags as the binary:
  see `faber help` (`Faber.CLI`).
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    # Load :faber application env (config :faber, :llm / :eval_threshold / …) so config-driven
    # dispatch resolves in every MIX_ENV. Not `app.start` — that would bind the endpoint port.
    Mix.Task.run("app.config")
    Application.ensure_all_started(:req_llm)

    # `parse/1` can answer `{:help, _}` or `{:parse_error, _, _}` instead of a runnable command —
    # both must print and stop here rather than MatchError'ing (or, worse, running a refine loop
    # the flags didn't ask for).
    status =
      case Faber.CLI.parse(["refine" | argv]) do
        {:refine, opts} -> Faber.CLI.run(:refine, opts)
        {:help, subcommand} -> Faber.CLI.run(:help, subcommand: subcommand)
        {:parse_error, subcommand, invalid} -> parse_error(subcommand, invalid)
      end

    case status do
      0 -> :ok
      status -> exit({:shutdown, status})
    end
  end

  defp parse_error(subcommand, invalid),
    do: Faber.CLI.run(:parse_error, subcommand: subcommand, invalid: invalid)
end
