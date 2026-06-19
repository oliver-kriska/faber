defmodule Faber.OptimizeTest do
  use ExUnit.Case, async: true

  alias Faber.{Optimize, Proposal}

  # Sidecar doubles — no python3 spawn, so this stays in the hermetic suite.
  defmodule NotImplStub do
    @behaviour Faber.Sidecar
    @impl true
    def call("optimize", _request, _opts) do
      {:ok,
       %{"command" => "optimize", "status" => "not_implemented", "reason" => "needs dspy + key"}}
    end
  end

  defmodule OkStub do
    @behaviour Faber.Sidecar
    @impl true
    # Simulates a future wired GEPA, and echoes back the request so we can assert the shape.
    def call("optimize", request, _opts) do
      {:ok, %{"status" => "ok", "result" => %{"best" => request}}}
    end
  end

  defmodule ErrorStub do
    @behaviour Faber.Sidecar
    @impl true
    def call("optimize", _request, _opts), do: {:error, :enoent}
  end

  describe "run/2" do
    test "reports not_implemented (the v1 reality: GEPA is a stub)" do
      assert {:error, {:not_implemented, reason}} =
               Optimize.run("# skill\n", sidecar: NotImplStub)

      assert reason =~ "dspy"
    end

    test "passes the rendered skill + eval through and returns the optimizer result when wired" do
      assert {:ok, %{"best" => req}} =
               Optimize.run("# skill\n", sidecar: OkStub, eval: %{"mode" => "vendored"})

      assert req["skill_md"] == "# skill\n"
      assert req["eval"] == %{"mode" => "vendored"}
    end

    test "renders a %Proposal{} before optimizing" do
      p = %Proposal{name: "x", description: "d", iron_laws: ["a", "b", "c"]}
      assert {:ok, %{"best" => req}} = Optimize.run(p, sidecar: OkStub)
      assert req["skill_md"] =~ "name: x"
    end

    test "surfaces a sidecar transport error" do
      assert {:error, :enoent} = Optimize.run("# skill\n", sidecar: ErrorStub)
    end
  end
end
