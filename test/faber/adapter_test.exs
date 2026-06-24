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

  describe "matches_session?/2 — stack gating against the reference adapter" do
    setup do
      assert {:ok, adapter} = Adapter.load(@reference_adapter)
      %{adapter: adapter}
    end

    test "matches a session that edited Elixir files", %{adapter: a} do
      assert Adapter.matches_session?(a, ["/Users/x/Projects/demo/lib/demo/accounts.ex"])
      assert Adapter.matches_session?(a, ["/Users/x/Projects/demo/test/demo_test.exs"])
      assert Adapter.matches_session?(a, ["/Users/x/Projects/demo/mix.exs"])
      assert Adapter.matches_session?(a, ["config/runtime.exs"])
    end

    test "does NOT match a Next.js / JS session (the Codex cross-stack case)", %{adapter: a} do
      js = [
        "/Users/x/Projects/naostro/app/page.tsx",
        "/Users/x/Projects/naostro/components/Hero.jsx",
        "/Users/x/Projects/naostro/package.json",
        "/Users/x/Projects/naostro/styles.css"
      ]

      refute Adapter.matches_session?(a, js)
    end

    test "no referenced paths → no match (safe default)", %{adapter: a} do
      refute Adapter.matches_session?(a, [])
    end

    test "matches if ANY path is in-stack, even amid foreign files", %{adapter: a} do
      assert Adapter.matches_session?(a, ["/x/readme.md", "/x/lib/a/b/c.ex", "/x/notes.txt"])
    end
  end

  describe "glob_regex/1" do
    test "extension brace glob matches .ex and .exs anywhere" do
      re = Adapter.glob_regex("**/*.{ex,exs}")
      assert Regex.match?(re, "/a/b/c.ex")
      assert Regex.match?(re, "lib/foo.exs")
      refute Regex.match?(re, "/a/b/c.tsx")
    end

    test "root-marker glob matches the file at any depth or bare" do
      re = Adapter.glob_regex("mix.exs")
      assert Regex.match?(re, "/Users/x/proj/mix.exs")
      assert Regex.match?(re, "mix.exs")
      refute Regex.match?(re, "/Users/x/proj/notmix.exs")
    end

    test "single * stays within a path segment" do
      re = Adapter.glob_regex("config/*.exs")
      assert Regex.match?(re, "/x/config/runtime.exs")
      refute Regex.match?(re, "/x/config/sub/runtime.exs")
    end
  end
end
