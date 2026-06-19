defmodule Faber.Eval.TriggerTest do
  use ExUnit.Case, async: true

  alias Faber.Eval.Trigger
  alias Faber.Proposal

  # Deterministic routing doubles (namespaced; no inline-in-test defmodule).
  defmodule PerfectRouter do
    @behaviour Faber.LLM
    @impl true
    # Activates iff the request contains "GO" — matches the fixtures used below exactly.
    def generate_object(prompt, _schema, _opts),
      do: {:ok, %{triggers: String.contains?(prompt, "GO")}}
  end

  defmodule AlwaysYes do
    @behaviour Faber.LLM
    @impl true
    def generate_object(_prompt, _schema, _opts), do: {:ok, %{triggers: true}}
  end

  defp proposal(should_trigger, should_not_trigger) do
    %Proposal{
      name: "demo-skill",
      description: "A demo skill for exercising the trigger scorer deterministically.",
      iron_laws: [],
      should_trigger: should_trigger,
      should_not_trigger: should_not_trigger
    }
  end

  describe "score/2" do
    test "perfect routing scores 1.0" do
      p = proposal(["please GO now"], ["nope, stay quiet"])
      assert %{accuracy: 1.0, correct: 2, total: 2} = Trigger.score(p, llm: PerfectRouter)
    end

    test "an always-fires router half-fails (activates when it should not)" do
      p = proposal(["please GO now"], ["nope, stay quiet"])
      assert %{accuracy: acc, correct: 1, total: 2} = Trigger.score(p, llm: AlwaysYes)
      assert acc == 0.5
    end

    test "no fixtures → skipped" do
      assert {:skipped, :no_fixtures} = Trigger.score(proposal([], []), llm: PerfectRouter)
    end
  end

  describe "Faber.Eval integration" do
    test "folds trigger accuracy into the result when trigger: true" do
      p = proposal(["please GO now"], ["nope, stay quiet"])
      {:ok, r} = Faber.Eval.score(p, llm: PerfectRouter, trigger: true)
      assert r.trigger.accuracy == 1.0
    end

    test "omits trigger unless requested" do
      {:ok, r} = Faber.Eval.score(proposal(["please GO now"], []), llm: PerfectRouter)
      refute Map.has_key?(r, :trigger)
    end
  end
end
