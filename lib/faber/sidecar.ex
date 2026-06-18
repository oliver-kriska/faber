defmodule Faber.Sidecar do
  @moduledoc """
  The boundary to the Python eval sidecar (`python -m faber_eval`).

  A behaviour so tests can inject a stub, with `Faber.Sidecar.System` as the default that actually
  shells out. The v1 contract is JSON-in / JSON-out over a subprocess: we hand the request to the
  Python CLI and decode its single JSON response. (The CLI accepts the request on stdin or via
  `--input PATH`; the System impl uses a temp file so it needs no Port stdin plumbing.)
  """

  @callback call(command :: String.t(), request :: map(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @doc "The configured implementation (default `Faber.Sidecar.System`)."
  @spec impl() :: module()
  def impl, do: Application.get_env(:faber, :sidecar, Faber.Sidecar.System)

  @doc "Invoke a sidecar `command` with a JSON `request` via the configured (or overridden) impl."
  @spec call(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def call(command, request, opts \\ []) do
    {mod, opts} = Keyword.pop(opts, :sidecar, impl())
    mod.call(command, request, opts)
  end
end
