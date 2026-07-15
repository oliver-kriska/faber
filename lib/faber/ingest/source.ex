defmodule Faber.Ingest.Source do
  @moduledoc """
  **The pluggable ingest source seam.** A `Source` answers *where sessions come from* — the
  filesystem (`Source.Files`, the default) or an external index like ccrider's SQLite DB
  (`Source.Ccrider`, opt-in). It sits one level above `Faber.Ingest.Format` (which answers *how to
  decode one record*): a source `discover`s opaque session **handles** and `parse`s each handle into
  the same normalized `Faber.Ingest.Event` stream, so `Faber.Scan` is agnostic to the origin.

  A source owns three things:

    * `discover/1` — the session handles available under the given options (a handle is opaque: a
      file path for `Source.Files`, a row descriptor for `Source.Ccrider`).
    * `parse/2` — decode one handle into `{events, errors}` (same shape as `Ingest.parse_file/2`).
    * `label/1` — a path-like identity string for the handle (lands in `Scan.Result.path`).

  …and may optionally own a fourth, `stamp/1`, which is what makes a source **cacheable** — see
  `Faber.Scan.Cache`. A source that doesn't implement it is simply always rescored.

  Resolution mirrors `Faber.Ingest.Format`: `opts[:source]` → `config :faber, :ingest_source` → the
  `:files` default. So the whole engine (dashboard included) can be switched to ccrider with one
  config line, or per-call with `source: :ccrider`, while the default stays self-contained.
  """

  alias Faber.Ingest.Event

  @type handle :: term()

  @typedoc """
  An opaque cache-validity token for one handle (see `c:stamp/1`).

  Compared only for equality, never interpreted, so each source picks whatever cheaply and
  *conservatively* captures "the bytes behind this handle changed".
  """
  @type stamp :: term()

  @callback discover(opts :: keyword()) :: [handle()]
  @callback parse(handle(), opts :: keyword()) :: {[Event.t()], [map()]}
  @callback label(handle()) :: String.t()

  @doc """
  A token that changes whenever `parse/2` would yield different events for this handle.

  This is the seam `Faber.Scan.Cache` keys on. Scoring a session is a pure function of the bytes
  `parse/2` reads, so an unchanged stamp means an unchanged `Scan.Result` — and the scan can skip
  the parse entirely. Must be **cheap** (it runs once per handle on every scan, including cache
  hits) and must never miss a change: over-invalidating only costs time, under-invalidating serves
  a stale score.

  Returning `nil` means "can't cheaply tell" — the handle is then never cached and always
  rescored, which is exactly the pre-cache behavior. Optional for that reason: a source that
  doesn't implement it keeps working, it just doesn't get the speedup.
  """
  @callback stamp(handle()) :: stamp() | nil

  @optional_callbacks stamp: 1

  @doc """
  The `c:stamp/1` for `handle` under `source`, or `nil` if the source doesn't implement it.

  Never raises: a source whose stamp blows up (a vanished file, an unreadable DB) degrades to
  "uncacheable" rather than taking down a scan over a cache concern.
  """
  @spec stamp(module(), handle()) :: stamp() | nil
  def stamp(source, handle) do
    # `ensure_loaded?` before `function_exported?`: the latter answers `false` for a module that
    # merely hasn't been loaded yet (lazy loading in dev), which would silently make every source
    # look uncacheable.
    if Code.ensure_loaded?(source) and function_exported?(source, :stamp, 1) do
      source.stamp(handle)
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  @aliases %{files: Faber.Ingest.Source.Files, ccrider: Faber.Ingest.Source.Ccrider}

  @doc """
  Resolve a source from `opts[:source]` → `config :faber, :ingest_source` → the `:files` default.

  Accepts a module directly or a short alias atom (`:files`, `:ccrider`). Raises on an unknown alias
  so a typo fails loudly rather than silently scanning the wrong source.
  """
  @spec resolve(keyword()) :: module()
  def resolve(opts \\ []) do
    case opts[:source] || Application.get_env(:faber, :ingest_source, :files) do
      mod when is_atom(mod) -> from_alias(mod)
      other -> raise ArgumentError, "invalid ingest source: #{inspect(other)}"
    end
  end

  defp from_alias(value) do
    case Map.fetch(@aliases, value) do
      {:ok, mod} ->
        mod

      :error ->
        if Code.ensure_loaded?(value) and function_exported?(value, :parse, 2) do
          value
        else
          raise ArgumentError,
                "unknown ingest source #{inspect(value)}; known: #{inspect(Map.keys(@aliases))}"
        end
    end
  end
end
