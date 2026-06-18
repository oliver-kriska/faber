defmodule Mix.Tasks.Faber.Propose do
  @shortdoc "Propose (and eval) a skill for the highest-friction session"
  @moduledoc """
  Run the Faber pipeline end to end on your real sessions: scan → pick the top friction session →
  propose a skill (via the configured LLM) → eval it through the Python sidecar → print the
  rendered `SKILL.md` and its score.

      mix faber.propose                      # top session, faber-elixir adapter
      mix faber.propose --rank 2             # the 2nd-ranked session
      mix faber.propose --adapter adapters/faber-elixir
      mix faber.propose --limit 200          # cap sessions scored
      mix faber.propose --write proposals    # also write SKILL.md under proposals/<name>/

  With the dev default (`Faber.LLM.ClaudeCLI`) this needs **no API key** — it drives your local
  `claude -p`. The eval step needs `python3` (the sidecar is stdlib-only).

  Options:

    * `--rank N`       which ranked session to use (1 = highest friction; default 1)
    * `--adapter DIR`  adapter pack dir (default `adapters/faber-elixir`)
    * `--limit N`      cap sessions scored (default 300, for speed)
    * `--base PATH`    transcript root (default ~/.claude/projects)
    * `--write DIR`    write the rendered skill to `DIR/<name>/SKILL.md`
    * `--no-eval`      skip the eval step
  """

  use Mix.Task

  alias Faber.{Adapter, Eval, Propose}

  @switches [
    rank: :integer,
    adapter: :string,
    limit: :integer,
    base: :string,
    write: :string,
    eval: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _argv, _invalid} = OptionParser.parse(argv, strict: @switches)
    # Load :faber application env (config :faber, :llm / :eval_threshold / …) so config-driven
    # dispatch resolves in every MIX_ENV. Not `app.start` — that would bind the endpoint port.
    Mix.Task.run("app.config")
    Application.ensure_all_started(:req_llm)

    adapter_dir = Keyword.get(opts, :adapter, "adapters/faber-elixir")
    rank = Keyword.get(opts, :rank, 1)

    with {:ok, adapter} <- Adapter.load(adapter_dir),
         {:ok, result} <- pick_session(opts, rank),
         {:ok, proposal} <- propose(result, adapter) do
      md = Propose.render_skill_md(proposal)
      report(result, proposal, md, opts)
    else
      {:error, reason} -> Mix.shell().error("faber.propose failed: #{inspect(reason)}")
    end
  end

  defp pick_session(opts, rank) do
    scan_opts =
      opts
      |> Keyword.take([:limit, :base])
      |> Keyword.put_new(:limit, 300)

    case Faber.Scan.run(scan_opts) |> Enum.at(rank - 1) do
      nil -> {:error, :no_session_at_rank}
      result -> {:ok, result}
    end
  end

  defp propose(result, adapter) do
    Mix.shell().info(
      "Proposing for #{result.fingerprint} session (raw #{fmt(result.raw)}, " <>
        "dominant #{result.dominant_signal}) via #{inspect(Faber.LLM.impl())}…\n"
    )

    Propose.propose(result, adapter)
  end

  defp report(result, proposal, md, opts) do
    Mix.shell().info(String.duplicate("─", 72))
    Mix.shell().info(md)
    Mix.shell().info(String.duplicate("─", 72))

    if Keyword.get(opts, :eval, true), do: run_eval(proposal)
    if dir = opts[:write], do: write(dir, proposal, md)

    Mix.shell().info("\nProvenance: #{result.session_id} — #{result.path}")
  end

  defp run_eval(proposal) do
    case Eval.score(proposal) do
      {:ok, r} ->
        verdict = if r.passed, do: "PASS", else: "below threshold"
        Mix.shell().info("Eval: composite #{fmt(r.composite)} (#{verdict} @ #{r.threshold})")
        for {dim, d} <- r.dimensions, do: Mix.shell().info("  #{dim}: #{fmt(d["score"])}")

      {:error, reason} ->
        Mix.shell().error("Eval skipped: #{inspect(reason)}")
    end
  end

  defp write(dir, proposal, md) do
    path = Path.join([dir, proposal.name, "SKILL.md"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, md)
    Mix.shell().info("Wrote #{path}")
  end

  defp fmt(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 2)
  defp fmt(n), do: to_string(n)
end
