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

  @impl true
  def stamp(path) do
    # `{mtime, size}`, not a content hash: transcripts run to hundreds of MB and hashing them
    # would cost exactly what the cache exists to avoid. Both fields are load-bearing — size alone
    # misses an in-place rewrite that keeps the length, and mtime alone misses an append landing
    # inside the filesystem's mtime granularity.
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime, size: size}} -> {mtime, size}
      {:error, _} -> nil
    end
  end
end
