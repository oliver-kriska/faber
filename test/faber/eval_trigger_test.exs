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
    test "perfect routing scores 1.0 with perfect precision and recall" do
      p = proposal(["please GO now"], ["nope, stay quiet"])

      assert %{accuracy: 1.0, precision: 1.0, recall: 1.0, correct: 2, total: 2, tp: 1, tn: 1} =
               Trigger.score(p, llm: PerfectRouter)
    end

    test "an always-fires router half-fails: recall stays 1.0 but precision drops" do
      p = proposal(["please GO now"], ["nope, stay quiet"])
      result = Trigger.score(p, llm: AlwaysYes)
      assert result.accuracy == 0.5
      # Both fixtures fire: the should_not case is a false positive → precision 1/2, recall 1/1.
      assert result.precision == 0.5
      assert result.recall == 1.0
      assert result.fp == 1
    end

    test "no fixtures → skipped" do
      assert {:skipped, :no_fixtures} = Trigger.score(proposal([], []), llm: PerfectRouter)
    end
  end

  describe "Faber.Eval integration (behavioral fold)" do
    test "folds trigger metrics into the composite as the behavioral dimension" do
      p = proposal(["please GO now"], ["nope, stay quiet"])
      {:ok, r} = Faber.Eval.score(p, llm: PerfectRouter, trigger: true)

      assert r.trigger.accuracy == 1.0
      # Behavioral is now a real dimension contributing to the composite + weight_total.
      assert r.dimensions["behavioral"]["score"] == 1.0
      assert r.weight_total == 1.1
    end

    test "a mis-routing skill is dragged toward failing by the behavioral dimension" do
      p = proposal(["please GO now"], ["nope, stay quiet"])

      {:ok, clean} = Faber.Eval.score(p, llm: PerfectRouter, trigger: true)
      {:ok, mis} = Faber.Eval.score(p, llm: AlwaysYes, trigger: true)

      # AlwaysYes fails precision (0.5 < 0.80) → behavioral 2/3 → lower composite than perfect routing.
      assert mis.dimensions["behavioral"]["score"] < clean.dimensions["behavioral"]["score"]
      assert mis.composite < clean.composite
    end

    test "omits trigger unless requested" do
      {:ok, r} = Faber.Eval.score(proposal(["please GO now"], []), llm: PerfectRouter)
      refute Map.has_key?(r, :trigger)
      refute Map.has_key?(r.dimensions, "behavioral")
    end

    test "a skipped trigger (no fixtures) does not add a behavioral dimension" do
      {:ok, r} = Faber.Eval.score(proposal([], []), llm: PerfectRouter, trigger: true)
      assert r.trigger == {:skipped, :no_fixtures}
      refute Map.has_key?(r.dimensions, "behavioral")
    end
  end
end
