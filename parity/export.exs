# Parity export — Faber side.
#
# Scores a deterministic spread of real sessions with Faber's NATIVE scorer and writes one JSON
# object per line (including the source path), so the Python oracle (parity/compare.py) can run
# the plugin's compute-metrics.py on the SAME raw files and diff the comparable fields.
#
#   mix run --no-start parity/export.exs <out.jsonl> [limit] [base]
#
# --no-start: scoring is pure (Faber.Ingest + Faber.Scan.score_session), so we skip app boot and
# never bind the web endpoint. Default limit 40; default base ~/.claude/projects.

[out | rest] = System.argv()

{limit, base} =
  case rest do
    [l, b | _] -> {String.to_integer(l), b}
    [l | _] -> {String.to_integer(l), nil}
    [] -> {40, nil}
  end

ingest_opts = if base, do: [base: base], else: []

all = Faber.Ingest.discover(ingest_opts)
n = length(all)
step = max(div(n, max(limit, 1)), 1)
sample = all |> Enum.take_every(step) |> Enum.take(limit)

rows =
  Enum.map(sample, fn path ->
    r = Faber.Scan.score_session(path, ingest_opts)

    %{
      path: path,
      raw: r.raw,
      score: r.friction,
      signals: r.signals,
      fingerprint: r.fingerprint,
      confidence: r.fingerprint_confidence,
      opportunity: r.opportunity,
      missed: r.missed,
      tier2: r.tier2,
      tool_count: r.tool_count,
      error_count: r.error_count,
      message_count: r.message_count
    }
  end)

File.write!(out, Enum.map_join(rows, "\n", &Jason.encode!/1) <> "\n")
IO.puts("wrote #{length(rows)} rows to #{out} (sampled #{length(sample)} of #{n})")
