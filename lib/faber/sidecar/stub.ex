defmodule Faber.Sidecar.Stub do
  @moduledoc """
  Deterministic `Faber.Sidecar` for tests — returns `opts[:sidecar_response]` (or a default
  passing score) without spawning Python. Lets `Faber.Eval`/`Faber.Loop` be exercised with no
  interpreter present.
  """

  @behaviour Faber.Sidecar

  @impl Faber.Sidecar
  def call(_command, _request, opts) do
    {:ok,
     Keyword.get(opts, :sidecar_response, %{
       "command" => "score",
       "status" => "ok",
       "result" => %{"composite" => 0.9, "dimensions" => %{}}
     })}
  end
end
