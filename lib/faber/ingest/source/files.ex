defmodule Faber.Ingest.Source.Files do
  @moduledoc """
  The default ingest source: session transcripts on the local filesystem.

  A thin wrapper over `Faber.Ingest` (which delegates the on-disk shape to the active
  `Faber.Ingest.Format`). The handle is a file path; `discover/1` and `parse/2` are exactly the
  pre-source behavior, so the file-walking path is unchanged and stays dependency-free.
  """

  @behaviour Faber.Ingest.Source

  alias Faber.Ingest

  @impl true
  def discover(opts), do: Ingest.discover(Keyword.take(opts, [:base, :format]))

  @impl true
  def parse(path, opts), do: Ingest.parse_file(path, Keyword.take(opts, [:format]))

  @impl true
  def label(path), do: path
end
