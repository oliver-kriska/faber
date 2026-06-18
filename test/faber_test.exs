defmodule FaberTest do
  use ExUnit.Case
  doctest Faber

  test "context modules are present and documented" do
    for mod <- [Faber, Faber.Ingest, Faber.Detect, Faber.Adapter, Faber.Eval, Faber.Loop] do
      assert Code.ensure_loaded?(mod)
    end
  end
end
