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
      mix faber.propose --format codex       # propose from another agent's sessions

  With the dev default (`Faber.LLM.ClaudeCLI`) this needs **no API key** — it drives your local
  `claude -p`. The eval step needs `python3` (the sidecar is stdlib-only).

  Options:

    * `--rank N`       which ranked session to use (1 = highest friction; default 1)
    * `--adapter DIR`  adapter pack dir (default `adapters/faber-elixir`)
    * `--limit N`      cap sessions scored — an even sample across the corpus (default: all)
    * `--base PATH`    transcript root (default: the format's own default)
    * `--format AGENT` ingest format: claude (default), codex, cline, gemini, opencode
    * `--write DIR`    write the rendered skill to `DIR/<name>/SKILL.md`
    * `--no-eval`      skip the eval step
    * `--trigger`      add behavioral routing-accuracy eval (one `claude -p` call per fixture)
    * `--trigger-samples N`  repeat the trigger eval N times and pool for a stable, noise-aware
      estimate (N× the LLM cost; reports `σ`). Default 1.
  """

  use Mix.Task

  alias Faber.{Adapter, Eval, Propose}

  @switches [
    rank: :integer,
    adapter: :string,
    limit: :integer,
    base: :string,
    format: :string,
    write: :string,
    eval: :boolean,
    trigger: :boolean,
    trigger_samples: :integer
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
      md = Propose.render_skill_md(proposal, adapter)
      report(result, proposal, md, adapter, opts)
    else
      {:error, reason} -> Mix.shell().error("faber.propose failed: #{inspect(reason)}")
    end
  end

  defp pick_session(opts, rank) do
    # No default :limit — score all sessions so `--rank N` selects from the true friction ranking.
    # (A `:limit`, if passed, now samples an even spread; see Faber.Scan.) `--limit` still works.
    scan_opts = opts |> Keyword.take([:limit, :base]) |> put_format(opts[:format])

    case Faber.Scan.run(scan_opts) |> Enum.at(rank - 1) do
      nil -> {:error, :no_session_at_rank}
      result -> {:ok, result}
    end
  end

  # Validate `--format` against the ingest registry; fail loudly on a typo rather than silently
  # proposing from the default (Claude) format. Absent flag → Scan defaults to Claude.
  defp put_format(scan_opts, nil), do: scan_opts

  defp put_format(scan_opts, format) do
    case Faber.Ingest.Format.cast(format) do
      {:ok, atom} ->
        Keyword.put(scan_opts, :format, atom)

      :error ->
        Mix.raise(
          "unknown --format #{inspect(format)}; known: " <>
            (Faber.Ingest.Format.known() |> Enum.map_join(", ", &Atom.to_string/1))
        )
    end
  end

  defp propose(result, adapter) do
    Mix.shell().info(
      "Proposing for #{result.fingerprint} session (raw #{fmt(result.raw)}, " <>
        "dominant #{result.dominant_signal}) via #{inspect(Faber.LLM.impl())}…\n"
    )

    Propose.propose(result, adapter)
  end

  defp report(result, proposal, md, adapter, opts) do
    Mix.shell().info(String.duplicate("─", 72))
    Mix.shell().info(md)
    Mix.shell().info(String.duplicate("─", 72))

    if Keyword.get(opts, :eval, true), do: run_eval(proposal, adapter, opts)
    if dir = opts[:write], do: write(dir, proposal, md)

    Mix.shell().info("\nProvenance: #{result.session_id} — #{result.path}")
  end

  defp run_eval(proposal, adapter, opts) do
    # `--trigger` adds behavioral routing accuracy (one keyless `claude -p` call per fixture);
    # `--trigger-samples N` repeats it N times and pools for a stable, noise-aware estimate.
    eval_opts =
      [adapter: adapter, trigger: opts[:trigger]]
      |> then(fn o ->
        if n = opts[:trigger_samples], do: Keyword.put(o, :trigger_samples, n), else: o
      end)

    case Eval.score(proposal, eval_opts) do
      {:ok, r} ->
        Mix.shell().info("Eval: composite #{fmt(r.composite)} (#{verdict(r)} @ #{r.threshold})")
        for {dim, d} <- r.dimensions, do: Mix.shell().info("  #{dim}: #{fmt(d["score"])}")
        report_veto(r)
        report_trigger(Map.get(r, :trigger))

      {:error, reason} ->
        Mix.shell().error("Eval skipped: #{inspect(reason)}")
    end
  end

  # A vetoed artifact can score ABOVE the threshold and still be refused, so "below threshold" is a
  # lie for that case — and the worst kind, since it hides a safety refusal behind a scoring
  # complaint and points the reader at the number instead of the reason.
  defp verdict(%{vetoed: [_ | _]}), do: "REFUSED"
  defp verdict(%{passed: true}), do: "PASS"
  defp verdict(_), do: "below threshold"

  defp report_veto(%{vetoed: [_ | _] = vetoed}) do
    for %{check_type: check, evidence: evidence} <- vetoed,
        do: Mix.shell().error("  REFUSED by #{check}: #{evidence}")

    :ok
  end

  defp report_veto(_), do: :ok

  defp report_trigger(nil), do: :ok
  defp report_trigger({:skipped, reason}), do: Mix.shell().info("Trigger: skipped (#{reason})")

  defp report_trigger(%{accuracy: acc, correct: c, total: t, samples: n, accuracy_stdev: sd}),
    do:
      Mix.shell().info(
        "Trigger accuracy: #{fmt(acc)} (#{c}/#{t} pooled over #{n} samples, σ=#{fmt(sd)})"
      )

  defp report_trigger(%{accuracy: acc, correct: c, total: t}),
    do: Mix.shell().info("Trigger accuracy: #{fmt(acc)} (#{c}/#{t})")

  defp write(dir, proposal, md) do
    path = Path.join([dir, proposal.name, "SKILL.md"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, md)
    Mix.shell().info("Wrote #{path}")
  end

  defp fmt(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 2)
  defp fmt(n), do: to_string(n)
end
