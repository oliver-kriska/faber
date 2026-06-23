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

  Resolution mirrors `Faber.Ingest.Format`: `opts[:source]` → `config :faber, :ingest_source` → the
  `:files` default. So the whole engine (dashboard included) can be switched to ccrider with one
  config line, or per-call with `source: :ccrider`, while the default stays self-contained.
  """

  alias Faber.Ingest.Event

  @type handle :: term()

  @callback discover(opts :: keyword()) :: [handle()]
  @callback parse(handle(), opts :: keyword()) :: {[Event.t()], [map()]}
  @callback label(handle()) :: String.t()

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
