defmodule Faber.LLMTest do
  use ExUnit.Case, async: true

  # A namespaced double (defining a module inside a test body pollutes the global atom table and can
  # collide across async runs). It echoes its arguments so we can assert exactly what the dispatch
  # layer forwarded.
  defmodule EchoLLM do
    @behaviour Faber.LLM
    @impl true
    def generate_object(prompt, _schema, opts), do: {:ok, %{"prompt" => prompt, "opts" => opts}}
  end

  describe "impl/0" do
    test "returns the configured implementation (Stub in the test env)" do
      assert Faber.LLM.impl() == Faber.LLM.Stub
    end
  end

  describe "generate_object/3 dispatch" do
    test "routes to the :llm-overridden module and pops :llm before forwarding" do
      assert {:ok, %{"prompt" => "p", "opts" => opts}} =
               Faber.LLM.generate_object("p", [a: 1], llm: EchoLLM, temperature: 0.3)

      # The override is consumed by the dispatcher, never leaked to the backend...
      refute Keyword.has_key?(opts, :llm)
      # ...while the rest of the opts pass through untouched.
      assert opts[:temperature] == 0.3
    end

    test "falls back to the configured impl (Stub) when no :llm override is given" do
      assert {:ok, obj} = Faber.LLM.generate_object("p", name: [type: :string])
      # Stub.default_proposal/0 — proves the call actually reached the configured backend.
      assert obj["name"] == "investigate-retry-loops"
    end
  end
end
