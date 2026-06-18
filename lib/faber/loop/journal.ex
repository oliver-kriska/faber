defmodule Faber.Loop.Journal do
  @moduledoc """
  Append-only JSONL journal for the autoresearch loop — one object per iteration, mirroring the
  plugin's `lab/autoresearch/results.jsonl`.

  Each entry records what was tried and whether it was kept, so a loop can be audited and resumed.
  Schema: `iteration, skill, old_composite, new_composite, kept, timestamp (ISO8601 UTC),
  description, reason`.
  """

  @type entry :: %{
          iteration: non_neg_integer(),
          skill: String.t() | nil,
          old_composite: float(),
          new_composite: float(),
          kept: boolean(),
          timestamp: String.t(),
          description: String.t(),
          reason: String.t() | nil
        }

  @doc "Build a journal entry, stamping it with the current UTC time."
  @spec entry(keyword()) :: entry()
  def entry(fields) do
    %{
      iteration: Keyword.fetch!(fields, :iteration),
      skill: Keyword.get(fields, :skill),
      old_composite: Keyword.get(fields, :old_composite, 0.0),
      new_composite: Keyword.get(fields, :new_composite, 0.0),
      kept: Keyword.fetch!(fields, :kept),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      description: Keyword.get(fields, :description, ""),
      reason: Keyword.get(fields, :reason)
    }
  end

  @doc "Append one entry as a JSON line to `path` (creating it if needed)."
  @spec append(Path.t(), entry()) :: :ok | {:error, term()}
  def append(path, entry) do
    with {:ok, line} <- Jason.encode(entry) do
      File.write(path, line <> "\n", [:append])
    end
  end

  @doc "Read all journal entries from `path` (string-keyed maps). Missing file → `[]`."
  @spec read(Path.t()) :: [map()]
  def read(path) do
    case File.read(path) do
      {:ok, content} ->
        # Skip corrupt/partial lines (e.g. a truncated append from a crash) rather than letting
        # one bad line raise and break the whole read.
        content
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case Jason.decode(line) do
            {:ok, entry} -> [entry]
            {:error, _} -> []
          end
        end)

      {:error, _} ->
        []
    end
  end
end
