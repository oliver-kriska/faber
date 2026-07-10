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

    test "loads the migrated detection vocab (contract §4.1)", %{adapter: a} do
      assert length(a.fingerprint_rules) == 3
      assert length(a.opportunity_rules) == 5
      assert a.skill_namespaces == ["phx", "ecto", "lv"]
      assert "example_step" in Map.keys(a.metadata)
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

    test "rejects file_globs / skill_namespaces that can't compile to a regex" do
      bad = %Adapter{
        name: "x",
        version: "1.0.0",
        agent_targets: ["claude-code"],
        # A non-string glob can't compile; a non-string namespace can't be escaped — both must be
        # caught at load (validate/1), not raise later in matches_session?/2 or a scan.
        file_globs: [123],
        skill_namespaces: [456],
        metadata: %{},
        dir: "/tmp/x"
      }

      problems = Adapter.validate(bad)
      assert Enum.any?(problems, &(&1 =~ "file_globs must each compile"))
      assert Enum.any?(problems, &(&1 =~ "skill_namespaces must each compile"))
    end
  end

  describe "load/1 errors" do
    test "missing manifest returns an error tuple" do
      assert {:error, {:yaml_error, _path, _reason}} = Adapter.load("/nonexistent/adapter")
    end
  end

  describe "load/1 detection vocab (contract §4.1)" do
    test "parses fingerprints, opportunities, and skill_namespaces into the struct" do
      detect = """
      signatures: []
      fingerprints:
        - type: maintenance
          commands: ["pip install", "uv add"]
          bonus: 3.0
      opportunities:
        - skill: investigate
          when: retry_loops
          unless_used: false
        - skill: verify
          when: commands
          commands: ["pytest"]
          threshold: 3
        - skill: review
          when: edit_count
          threshold: 10
      skill_namespaces: ["py", "ruff"]
      """

      dir = write_adapter("faber-fixture", detect)
      assert {:ok, a} = Adapter.load(dir)
      assert Adapter.validate(a) == []

      assert a.fingerprint_rules == [
               %{type: "maintenance", commands: ["pip install", "uv add"], tools: [], bonus: 3.0}
             ]

      assert [investigate, verify, review] = a.opportunity_rules

      assert investigate == %{
               skill: "investigate",
               when: :retry_loops,
               commands: [],
               threshold: nil,
               unless_used: false
             }

      assert verify.when == :commands and verify.commands == ["pytest"] and verify.threshold == 3
      assert verify.unless_used == true

      assert review == %{
               skill: "review",
               when: :edit_count,
               commands: [],
               threshold: 10,
               unless_used: true
             }

      assert a.skill_namespaces == ["py", "ruff"]
    end

    test "absent detection-vocab keys default to empty (v0.1 pack stays valid)" do
      dir = write_adapter("faber-fixture", "signatures: []\n")
      assert {:ok, a} = Adapter.load(dir)
      assert a.fingerprint_rules == []
      assert a.opportunity_rules == []
      assert a.skill_namespaces == []
      assert Adapter.validate(a) == []
    end

    test "validates malformed fingerprint/opportunity/namespace entries" do
      detect = """
      signatures: []
      fingerprints:
        - commands: ["x"]
          bonus: "high"
        - type: telemetry
          tools: [42]
          bonus: 1.0
        - type: vacuous
          bonus: 1.0
      opportunities:
        - skill: plan
          when: tool_count
        - skill: bad
          when: nonsense
      skill_namespaces: ["ok", 42]
      """

      dir = write_adapter("faber-fixture", detect)
      assert {:error, {:invalid_adapter, problems}} = Adapter.load(dir)

      assert Enum.any?(problems, &(&1 =~ "fingerprint rule missing type"))
      assert Enum.any?(problems, &(&1 =~ "bonus must be a number"))
      assert Enum.any?(problems, &(&1 =~ "telemetry tools must be a list of strings"))
      assert Enum.any?(problems, &(&1 =~ "vacuous must declare commands or tools"))
      assert Enum.any?(problems, &(&1 =~ "requires an integer threshold"))
      assert Enum.any?(problems, &(&1 =~ "'when' must be one of"))
      assert Enum.any?(problems, &(&1 =~ "skill_namespaces must be a list of strings"))
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

  describe "load/1 template safety (untrusted pack)" do
    test "manifest file entries that escape templates/ are rejected, not read" do
      dir = write_adapter("faber-fixture", "signatures: []")
      tpl = Path.join(dir, "templates")
      File.mkdir_p!(tpl)

      # A "secret" OUTSIDE the pack that a malicious manifest tries to slurp.
      File.write!(Path.join(Path.dirname(dir), "secret.txt"), "TOP-SECRET")

      File.write!(Path.join(tpl, "manifest.yaml"), """
      templates:
        - file: "../../secret.txt"
          produces: skill
        - file: "/etc/hosts"
          produces: agent
        - file: good.md.tmpl
          produces: hook
      """)

      File.write!(Path.join(tpl, "good.md.tmpl"), "legit template")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, a} = Adapter.load(dir)
          # only the in-pack template survives; neither escape is read
          assert a.templates == %{"hook" => "legit template"}
        end)

      assert log =~ "escapes templates/"
    end
  end

  # Write a minimal valid adapter pack into a unique tmp dir (name == dir basename, as the
  # contract requires) with the given `detect/signatures.yaml` body. Auto-removed on exit.
  defp write_adapter(name, detect_yaml) do
    base =
      Path.join(System.tmp_dir!(), "faber-adapter-test-#{System.unique_integer([:positive])}")

    dir = Path.join(base, name)
    File.mkdir_p!(Path.join(dir, "detect"))

    manifest = """
    name: #{name}
    version: 0.1.0
    agent_targets:
      - claude-code
    file_globs:
      - "**/*.py"
    metadata:
      description: "fixture"
    """

    File.write!(Path.join(dir, "faber.adapter.yaml"), manifest)
    File.write!(Path.join(dir, "detect/signatures.yaml"), detect_yaml)
    on_exit(fn -> File.rm_rf!(base) end)
    dir
  end
end
