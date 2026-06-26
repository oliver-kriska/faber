defmodule Faber.FaberPythonTest do
  @moduledoc """
  Phase 2: prove Faber's engine is **domain-free** by driving the whole pipeline with the
  hand-curated `faber-python` adapter on a real Python session fixture — scan → detect →
  propose → eval — and showing the output is Python-flavored, while the same engine produces
  Elixir-flavored output under `faber-elixir`. The only `lib/faber` code involved is the
  generic adapter-awareness from Phase 0 (asserted by the zero-diff test in P2-T3).
  """
  use ExUnit.Case, async: true

  alias Faber.{Adapter, Detect, Eval, Ingest, Propose, Scan}

  @python_adapter Path.expand("../../adapters/faber-python", __DIR__)
  @elixir_adapter Path.expand("../../adapters/faber-elixir", __DIR__)
  # In its own dir (like fixtures_dedup) so the shared `test/fixtures` dir-scans in scan_test /
  # cli_test stay Elixir-only — this high-friction Python session would otherwise out-rank them.
  @fixture Path.expand("../fixtures_python/python_session.jsonl", __DIR__)

  setup_all do
    assert {:ok, py} = Adapter.load(@python_adapter)
    assert {:ok, ex} = Adapter.load(@elixir_adapter)
    {events, []} = Ingest.parse_file(@fixture)
    %{py: py, ex: ex, events: events}
  end

  describe "the pack itself" do
    test "loads and validates with zero problems", %{py: py} do
      assert py.name == "faber-python"
      assert py.contract == "0.2"
      assert Adapter.validate(py) == []
      assert length(py.laws) == 15
      assert length(py.playbooks) == 7
      assert Map.has_key?(py.templates, "skill")
    end

    test "carries Python detection vocab, not Elixir", %{py: py} do
      assert py.skill_namespaces == ["py"]
      assert Enum.any?(py.fingerprint_rules, &("pip install" in &1.commands))
      verify = Enum.find(py.opportunity_rules, &(&1.skill == "verify"))
      assert "pytest" in verify.commands
    end
  end

  describe "stack gating (matches_session?/2)" do
    test "matches the Python session, not the Elixir adapter", %{py: py, ex: ex, events: events} do
      paths = referenced_paths(events)
      assert paths == ["/Users/x/Projects/pyapp/src/parser.py"]
      assert Adapter.matches_session?(py, paths)
      refute Adapter.matches_session?(ex, paths)
    end
  end

  describe "detection is Python-flavored via the adapter" do
    test "fingerprint: maintenance under the adapter, bug-fix adapter-free", %{py: py, events: e} do
      # The python adapter's `pip install → maintenance` bonus + "update" keyword tips the
      # classification to maintenance; adapter-free the engine has no such rule, so the
      # bash-heavy session reads as bug-fix. Same engine, different vocab.
      assert %{type: "maintenance"} = Detect.fingerprint(e, py)
      assert %{type: "bug-fix"} = Detect.fingerprint(e)
    end

    test "opportunity: pytest drives verify, py: namespace extracts the used skill", %{
      py: py,
      events: e
    } do
      assert %{missed: missed, used: used} = Detect.opportunity(e, py)
      # `verify` comes from the adapter's pytest rule (the engine default keys on `mix test`).
      assert "verify" in missed
      assert "investigate" in missed
      # `/py:lint` is extracted because this adapter's namespace is `py` (not phx|ecto|lv).
      assert "lint" in used

      # Adapter-free, neither the pytest-verify rule nor the py: namespace applies.
      assert %{missed: default_missed, used: []} = Detect.opportunity(e)
      refute "verify" in default_missed
    end
  end

  describe "scan path threads the adapter" do
    test "Scan.score_session/2 produces a Python-flavored Result", %{py: py} do
      r = Scan.score_session(@fixture, adapter: py)
      assert %Scan.Result{} = r
      assert r.fingerprint == "maintenance"
      assert "verify" in r.missed
      assert "lint" in r.skills_used
      # Friction is real (repeated pip/pytest failures), so the session is worth mining.
      assert r.raw > 0.0
    end
  end

  describe "propose + eval produce a valid, eval-passing Python skill" do
    test "the rendered skill passes the native structural eval", %{py: py} do
      result = Scan.score_session(@fixture, adapter: py)

      {:ok, proposal} =
        Propose.propose(result, py, llm: Faber.LLM.Stub, stub_response: python_skill())

      md = Propose.render_skill_md(proposal, py)

      # The Python template renders the worked example in a ```python fence.
      assert md =~ "```python"
      assert md =~ "## Iron Laws"
      assert md =~ "pytest"

      assert {:ok, score} = Eval.score(md, engine: :native, threshold: 0.75)
      assert score.passed, "expected the python skill to pass native eval, got #{inspect(score)}"
    end
  end

  # A complete, Python-idiomatic stub proposal (what a real LLM would return for this session).
  defp python_skill do
    %{
      "name" => "pytest-isolate-failure",
      "description" =>
        "Isolate a failing pytest test before editing — run the single node id, read the " <>
          "assertion diff, form one hypothesis. Use when pytest is rerun after a failure. NOT " <>
          "for collection errors.",
      "effort" => "low",
      "rationale" =>
        "The session reran pytest on the same failing test three times before reading the " <>
          "code — isolating the failure first would have cut the loop.",
      "iron_laws" => [
        "Run the single failing node id with `pytest path::test -x`, never the whole suite blind.",
        "Read the assertion diff (`-vv`) before changing code.",
        "Change exactly one thing per attempt so the result is attributable."
      ],
      "usage" => "Triggered when pytest is rerun after a failure on the same test.",
      "example" => "pytest tests/test_parser.py::test_parse -x -vv   # isolate + full diff",
      "workflow" => [
        "Run the failing test in isolation with `pytest path/to/test.py::test_name -x`",
        "Read the assertion diff with `-vv` and form one hypothesis",
        "Change one thing, rerun the single test, then the module"
      ],
      "patterns" => [
        "Isolation: run the single node id, not the whole suite, while debugging",
        "Lazy logging: pass args to logging, do not f-string in hot paths"
      ],
      "should_trigger" => [
        "the same pytest test keeps failing and I keep rerunning it",
        "this assertion error won't go away"
      ],
      "should_not_trigger" => [
        "run the full test suite once",
        "what does this function do"
      ]
    }
  end

  defp referenced_paths(events) do
    events
    |> Enum.flat_map(& &1.tool_uses)
    |> Enum.flat_map(fn
      %{input: input} when is_map(input) -> [input["file_path"], input["path"]]
      _ -> []
    end)
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end
end
