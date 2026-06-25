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

  # status:"error" with an error message in the body (a sidecar-reported failure, not transport).
  defmodule StatusErrorStub do
    @behaviour Faber.Sidecar
    @impl true
    def call("optimize", _request, _opts),
      do: {:ok, %{"status" => "error", "error" => "gepa exploded"}}
  end

  # status:"error" with NO message → the wrapper supplies the :sidecar_error fallback.
  defmodule StatusErrorNoMsgStub do
    @behaviour Faber.Sidecar
    @impl true
    def call("optimize", _request, _opts), do: {:ok, %{"status" => "error"}}
  end

  # A well-formed response the wrapper doesn't recognize (e.g. a future/typo'd status).
  defmodule UnexpectedStub do
    @behaviour Faber.Sidecar
    @impl true
    def call("optimize", _request, _opts), do: {:ok, %{"status" => "surprise"}}
  end

  describe "run/2" do
    test "maps a not_implemented sidecar response to {:error, {:not_implemented, reason}}" do
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

    test "surfaces a sidecar-reported status:error with its message" do
      assert {:error, "gepa exploded"} = Optimize.run("# skill\n", sidecar: StatusErrorStub)
    end

    test "falls back to :sidecar_error when status:error carries no message" do
      assert {:error, :sidecar_error} = Optimize.run("# skill\n", sidecar: StatusErrorNoMsgStub)
    end

    test "wraps an unrecognized response as :unexpected_response" do
      assert {:error, {:unexpected_response, %{"status" => "surprise"}}} =
               Optimize.run("# skill\n", sidecar: UnexpectedStub)
    end

    test "passes :budget through into the optimizer request" do
      assert {:ok, %{"best" => req}} =
               Optimize.run("# skill\n", sidecar: OkStub, budget: %{"rollouts" => 20})

      assert req["budget"] == %{"rollouts" => 20}
      # absent by default — put_present omits nil keys
      assert {:ok, %{"best" => bare}} = Optimize.run("# skill\n", sidecar: OkStub)
      refute Map.has_key?(bare, "budget")
    end
  end

  describe "run/2 against the real python sidecar" do
    @describetag :sidecar

    # End-to-end over the real subprocess (python -m faber_eval optimize) — validates the live
    # boundary without stubs. The base sidecar never installs the optional `dspy` (`gepa` extra), so
    # the capability gate trips and this returns not_implemented — FREE: no key, no provider call,
    # no token spend. Wiring GEPA live is then a Python-side change only; the seam is proven here.
    test "degrades to not_implemented without the gepa extra (no spend)" do
      assert {:error, {:not_implemented, reason}} =
               Optimize.run("# skill\n",
                 eval: %{"mode" => "vendored"},
                 budget: %{"rollouts" => 3}
               )

      assert reason =~ "dspy" or reason =~ "API key"
    end
  end
end
