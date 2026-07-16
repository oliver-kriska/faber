defmodule Faber.Loop.Journal do
  @moduledoc """
  Append-only JSONL journal for the autoresearch loop — one object per iteration, mirroring the
  plugin's `lab/autoresearch/results.jsonl`.

  Each entry records what was tried and whether it was kept, so a loop can be audited and resumed.
  Schema: `format, iteration, skill, old_composite, new_composite, kept, timestamp (ISO8601 UTC),
  description, reason`.

  ## Read policy

  `unstamped: 1` — journals written before this store declared a format are **already on disk**
  (this one is Oliver's own loop history), and they predate the key. A reader that demanded
  `format` would orphan every existing line. That is the same bug `Faber.Store.Format` exists to
  prevent, so it is not re-introduced while fixing its class.

  Reads stay **lenient** by design: `read/1` skips a line it cannot parse rather than failing the
  whole journal, and an entry stamped with an unreadable format is skipped the same way. This is
  history — one lost line costs a gap in an audit trail, not money — so it is never worth taking
  the whole read down over.
  """

  use Faber.Store.Format,
    format: 1,
    readable_formats: [1],
    data_class: :history,
    unstamped: 1

  @type entry :: %{
          format: pos_integer(),
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
      format: format(),
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

  @doc """
  Read all journal entries from `path` (string-keyed maps). Missing file → `[]`.

  Lines this reader cannot use are skipped, never raised on: a corrupt/partial line (a truncated
  append from a crash) and a line stamped with an unreadable format are both just gaps. An
  **unstamped** line is a pre-versioning entry and reads as format 1 — see the moduledoc.
  """
  @spec read(Path.t()) :: [map()]
  def read(path) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          with {:ok, entry} <- Jason.decode(line),
               true <- readable?(entry["format"]) do
            [entry]
          else
            _ -> []
          end
        end)

      {:error, _} ->
        []
    end
  end
end
