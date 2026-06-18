defmodule Faber.AdapterTest do
  use ExUnit.Case, async: true

  alias Faber.Adapter

  @reference_adapter Path.expand("../../adapters/faber-elixir", __DIR__)

  describe "load/1 on the reference adapter" do
    setup do
      assert {:ok, adapter} = Adapter.load(@reference_adapter)
      %{adapter: adapter}
    end

    test "reads and validates the manifest", %{adapter: a} do
      assert a.name == "faber-elixir"
      assert Regex.match?(~r/^\d+\.\d+\.\d+$/, a.version)
      assert a.agent_targets == ["claude-code"]
      assert "mix.exs" in a.file_globs
      assert is_map(a.metadata)
    end

    test "loads the bulk knowledge files", %{adapter: a} do
      assert length(a.laws) == 26
      assert length(a.signatures) == 6
      assert length(a.playbooks) == 6

      law = Enum.find(a.laws, &(&1.id == "ecto-no-float-for-money"))
      assert law.severity == "high"
      assert law.check["kind"] == "regex"
    end

    test "reads the exec-in-place eval reference", %{adapter: a} do
      assert a.eval["mode"] == "exec-in-place"
      assert a.eval["entrypoints"]["score"] =~ "lab.eval.scorer"
    end

    test "the reference adapter has zero validation problems", %{adapter: a} do
      assert Adapter.validate(a) == []
    end
  end

  describe "validate/1" do
    test "collects required-field, format, and uniqueness problems" do
      bad = %Adapter{
        name: "x",
        version: "1.0",
        agent_targets: [],
        file_globs: [],
        metadata: %{},
        dir: "/tmp/wrongname",
        laws: [
          %{id: "dup", category: "c", severity: "huge", statement: "s", check: nil},
          %{id: "dup", category: "c", severity: "high", statement: "s2", check: nil}
        ]
      }

      problems = Adapter.validate(bad)

      assert Enum.any?(problems, &(&1 =~ "agent_targets"))
      assert Enum.any?(problems, &(&1 =~ "file_globs"))
      assert Enum.any?(problems, &(&1 =~ "MAJOR.MINOR.PATCH"))
      assert Enum.any?(problems, &(&1 =~ "directory name"))
      assert Enum.any?(problems, &(&1 =~ "severity"))
      assert Enum.any?(problems, &(&1 =~ "duplicate law ids"))
    end
  end

  describe "load/1 errors" do
    test "missing manifest returns an error tuple" do
      assert {:error, {:yaml_error, _path, _reason}} = Adapter.load("/nonexistent/adapter")
    end
  end
end
