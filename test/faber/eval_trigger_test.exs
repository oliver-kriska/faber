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

  # A deliberately noisy router: alternates true/false on successive calls via a shared counter, so
  # repeated samples of the same fixture disagree — the stochastic objective N-sample pooling targets.
  defmodule FlakyRouter do
    @behaviour Faber.LLM
    @impl true
    def generate_object(_prompt, _schema, _opts) do
      n = Agent.get_and_update(__MODULE__, fn c -> {c, c + 1} end)
      {:ok, %{triggers: rem(n, 2) == 0}}
    end
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

  describe "N-sample averaging (trigger_samples)" do
    test "default (samples=1) keeps the original single-pass shape — no extra keys" do
      r = Trigger.score(proposal(["GO now"], []), llm: PerfectRouter)
      refute Map.has_key?(r, :samples)
      refute Map.has_key?(r, :accuracy_stdev)
    end

    test "pools N samples of a noisy router into a stable estimate and surfaces the stdev" do
      start_supervised!(%{
        id: FlakyRouter,
        start: {Agent, :start_link, [fn -> 0 end, [name: FlakyRouter]]}
      })

      # One should-fire fixture; FlakyRouter alternates true/false, so over 4 samples it's right
      # exactly twice. Pooling keeps correct/total consistent with accuracy, and σ exposes the noise.
      r = Trigger.score(proposal(["GO now"], []), llm: FlakyRouter, trigger_samples: 4)

      assert r.samples == 4
      assert r.total == 4
      assert r.correct == 2
      assert r.accuracy == 0.5
      assert r.accuracy_stdev == 0.5
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

      # AlwaysYes: accuracy 0.5, precision 0.5, recall 1.0 → continuous mean 0.667 < perfect's 1.0.
      assert mis.dimensions["behavioral"]["score"] < clean.dimensions["behavioral"]["score"]
      assert mis.composite < clean.composite
    end

    test "behavioral score is continuous: clears every threshold yet scores < 1.0 (loop gradient)" do
      # PerfectRouter fires iff "GO": 2/3 should-fire hit (one FN), 3/3 should-not held.
      # → accuracy 0.833, precision 1.0, recall 0.667 — all three thresholds (0.75/0.80/0.60)
      # cleared, so the OLD `passed/total` score was a flat 1.0 with no gradient. The continuous
      # mean is 0.833, so the composite sits below the ceiling and the reflective loop can climb.
      p = proposal(["GO a", "GO b", "do c"], ["quiet x", "quiet y", "quiet z"])
      {:ok, r} = Faber.Eval.score(p, llm: PerfectRouter, trigger: true)

      b = r.dimensions["behavioral"]
      assert b["passed"] == 3 and b["failed"] == 0
      assert_in_delta b["score"], 0.8333, 0.001
      assert b["score"] < 1.0
      assert b["metrics"]["precision"] == 1.0
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
