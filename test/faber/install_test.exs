defmodule Faber.InstallTest do
  use ExUnit.Case, async: true

  alias Faber.{Install, Proposal}

  describe "install/2" do
    @tag :tmp_dir
    test "writes a {name, md} pair to <dir>/<name>/SKILL.md", %{tmp_dir: dir} do
      assert {:ok, path} = Install.install({"my-skill", "# hi\n"}, dir: dir)
      assert path == Path.join([dir, "my-skill", "SKILL.md"])
      assert File.read!(path) == "# hi\n"
    end

    @tag :tmp_dir
    test "refuses to overwrite an existing skill unless force: true", %{tmp_dir: dir} do
      {:ok, path} = Install.install({"s", "v1"}, dir: dir)

      assert {:error, {:exists, ^path}} = Install.install({"s", "v2"}, dir: dir)
      assert File.read!(path) == "v1"

      assert {:ok, ^path} = Install.install({"s", "v2"}, dir: dir, force: true)
      assert File.read!(path) == "v2"
    end

    @tag :tmp_dir
    test "rejects a name that isn't a safe path segment (no traversal/absolute escape)", %{
      tmp_dir: dir
    } do
      assert {:error, {:invalid_name, _}} = Install.install({"../../etc/evil", "x"}, dir: dir)
      assert {:error, {:invalid_name, _}} = Install.install({"/etc/evil", "x"}, dir: dir)
      assert {:error, {:invalid_name, _}} = Install.install({"has spaces", "x"}, dir: dir)
      assert {:error, {:invalid_name, _}} = Install.install({"Upper", "x"}, dir: dir)
      refute File.exists?(Path.join(dir, "etc"))
    end

    @tag :tmp_dir
    test "renders and installs a %Proposal{}", %{tmp_dir: dir} do
      p = %Proposal{
        name: "tidy-thing",
        description: "A focused skill.",
        rationale: "because",
        iron_laws: ["one", "two", "three"]
      }

      assert {:ok, path} = Install.install(p, dir: dir)
      assert File.read!(path) =~ "name: tidy-thing"
    end

    @tag :tmp_dir
    test "drops a .faber.json provenance marker beside the SKILL.md", %{tmp_dir: dir} do
      {:ok, path} = Install.install({"marked", "# hi\n"}, dir: dir)
      marker = Path.join(Path.dirname(path), ".faber.json")

      assert File.exists?(marker)
      assert %{"installed_by" => "faber", "name" => "marked"} = Jason.decode!(File.read!(marker))
    end

    @tag :tmp_dir
    test "a %Proposal{} marker carries its source provenance (never the transcript path)", %{
      tmp_dir: dir
    } do
      p = %Proposal{
        name: "from-session",
        description: "d",
        rationale: "r",
        iron_laws: ["a", "b", "c"],
        adapter: "faber-elixir",
        source: %{session_id: "abc123", fingerprint: "bug-fix", path: "/Users/x/secret.jsonl"}
      }

      {:ok, path} = Install.install(p, dir: dir)
      data = path |> Path.dirname() |> Path.join(".faber.json") |> File.read!() |> Jason.decode!()

      assert data["adapter"] == "faber-elixir"
      assert data["source_session"] == "abc123"
      assert data["fingerprint"] == "bug-fix"
      # The internal transcript location is provenance the privacy boundary keeps out.
      refute Map.has_key?(data, "path")
      refute File.read!(path) =~ "secret.jsonl"
    end

    @tag :tmp_dir
    test "an empty-source %Proposal{} writes no nil provenance keys (drop_nils)", %{tmp_dir: dir} do
      p = %Proposal{
        name: "no-source",
        description: "d",
        rationale: "r",
        iron_laws: ["a", "b", "c"],
        source: %{}
      }

      {:ok, path} = Install.install(p, dir: dir)
      data = path |> Path.dirname() |> Path.join(".faber.json") |> File.read!() |> Jason.decode!()

      # adapter/source_session/fingerprint were all nil → dropped; only the always-present keys remain.
      assert Enum.sort(Map.keys(data)) == ["installed_at", "installed_by", "name"]
      assert {:ok, _, _} = DateTime.from_iso8601(data["installed_at"])
    end
  end

  describe "list_faber_installed/1" do
    @tag :tmp_dir
    test "returns only skills Faber installed, not the user's own", %{tmp_dir: dir} do
      {:ok, _} =
        Install.install({"faber-one", "---\nname: faber-one\ndescription: Mine.\n---\n"},
          dir: dir
        )

      write_unmanaged_skill(dir, "users-own", "Theirs.")

      names = Install.list_faber_installed(dir) |> Enum.map(& &1.name)
      assert names == ["faber-one"]

      # The generic primitive still sees both (membership, not a sort-order-coupled equality).
      all = Install.list_installed(dir) |> Enum.map(& &1.name)
      assert "faber-one" in all
      assert "users-own" in all
    end
  end

  describe "provenance/1" do
    # THE marker reader — the dashboard reads `"source_session"` off this to show a session as
    # already-installed after a browser refresh, and `installed_at/1` reads its timestamp off it.
    @tag :tmp_dir
    test "returns the decoded marker install/2 wrote", %{tmp_dir: dir} do
      p = %Proposal{
        name: "from-session",
        description: "d",
        rationale: "r",
        iron_laws: ["a", "b", "c"],
        adapter: "faber-elixir",
        source: %{session_id: "sess-abc", fingerprint: "bug-fix"}
      }

      {:ok, path} = Install.install(p, dir: dir)
      data = Install.provenance(path)

      assert data["installed_by"] == "faber"
      assert data["source_session"] == "sess-abc"
      assert data["adapter"] == "faber-elixir"
    end

    @tag :tmp_dir
    test "empty map for a skill with no marker (the user's own) or unreadable JSON", %{
      tmp_dir: dir
    } do
      write_unmanaged_skill(dir, "users-own", "Theirs.")
      assert Install.provenance(Path.join([dir, "users-own", "SKILL.md"])) == %{}

      {:ok, path} = Install.install({"corrupt", "---\nname: corrupt\n---\n"}, dir: dir)
      path |> Path.dirname() |> Path.join(".faber.json") |> File.write!("{not json")
      assert Install.provenance(path) == %{}
    end
  end

  describe "installed_at/1" do
    # THE marker-timestamp reader — Faber.Feedback delegates here, so this pins the write→read
    # round-trip that used to be two independently-hardcoded copies of the marker convention.
    @tag :tmp_dir
    test "reads back the timestamp install/2 wrote", %{tmp_dir: dir} do
      before = DateTime.utc_now() |> DateTime.add(-1, :second)
      {:ok, path} = Install.install({"stamped", "---\nname: stamped\n---\n"}, dir: dir)

      assert %DateTime{} = at = Install.installed_at(path)
      assert DateTime.compare(at, before) in [:gt, :eq]
    end

    @tag :tmp_dir
    test "nil for a skill without a marker (user's own) or an old-shape marker", %{tmp_dir: dir} do
      write_unmanaged_skill(dir, "users-own", "Theirs.")
      assert Install.installed_at(Path.join([dir, "users-own", "SKILL.md"])) == nil

      {:ok, path} = Install.install({"legacy", "---\nname: legacy\n---\n"}, dir: dir)
      marker = path |> Path.dirname() |> Path.join(".faber.json")
      File.write!(marker, ~s({"installed_by":"faber","name":"legacy"}\n))
      assert Install.installed_at(path) == nil
    end
  end

  describe "cross-agent pointers (managed block)" do
    setup %{tmp_dir: dir} do
      skills = Path.join(dir, "skills")
      ctx = Path.join(dir, "CLAUDE.md")
      install_skill(skills, "alpha", "Alpha triages bugs.")
      %{skills: skills, ctx: ctx}
    end

    @tag :tmp_dir
    test "list_installed/1 summarizes each skill's name + description", %{skills: skills} do
      install_skill(skills, "beta", "Beta tunes queries.")

      assert [%{name: "alpha", description: "Alpha triages bugs."}, %{name: "beta"}] =
               Install.list_installed(skills)
    end

    @tag :tmp_dir
    test "sync_pointer writes a managed block and is idempotent", %{skills: skills, ctx: ctx} do
      assert {:ok, :written} = Install.sync_pointer("claude", file: ctx, dir: skills)

      body = File.read!(ctx)
      assert body =~ "FABER:BEGIN"
      assert body =~ "**alpha** — Alpha triages bugs."

      # Re-running with the same installed set changes nothing.
      assert {:ok, :unchanged} = Install.sync_pointer("claude", file: ctx, dir: skills)
      assert File.read!(ctx) == body
    end

    @tag :tmp_dir
    test "sync_pointer preserves the user's surrounding text", %{skills: skills, ctx: ctx} do
      File.write!(ctx, "# My global rules\n\nBe nice.\n")
      assert {:ok, :written} = Install.sync_pointer("claude", file: ctx, dir: skills)

      out = File.read!(ctx)
      assert out =~ "# My global rules"
      assert out =~ "Be nice."
      assert out =~ "FABER:BEGIN"
    end

    @tag :tmp_dir
    test "check_pointer reports absent → in_sync → drift as the skill set changes", %{
      skills: skills,
      ctx: ctx
    } do
      assert Install.check_pointer("claude", file: ctx, dir: skills) == :absent

      Install.sync_pointer("claude", file: ctx, dir: skills)
      assert Install.check_pointer("claude", file: ctx, dir: skills) == :in_sync

      # A newly installed skill makes the on-disk block stale.
      install_skill(skills, "gamma", "Gamma checks safety.")
      assert Install.check_pointer("claude", file: ctx, dir: skills) == :drift
    end

    @tag :tmp_dir
    test "a hand-edited block is detected and not overwritten without force", %{
      skills: skills,
      ctx: ctx
    } do
      Install.sync_pointer("claude", file: ctx, dir: skills)
      File.write!(ctx, String.replace(File.read!(ctx), "Alpha triages bugs.", "HAND EDITED"))

      assert Install.check_pointer("claude", file: ctx, dir: skills) == :modified
      assert {:error, :block_modified} = Install.sync_pointer("claude", file: ctx, dir: skills)
      # force overwrites the tampered block with the regenerated one.
      assert {:ok, :written} = Install.sync_pointer("claude", file: ctx, dir: skills, force: true)
      assert File.read!(ctx) =~ "Alpha triages bugs."
    end

    @tag :tmp_dir
    test "unknown agent without an explicit file is an error", %{skills: skills} do
      assert {:error, {:unknown_agent, "borg"}} = Install.sync_pointer("borg", dir: skills)
      assert {:error, {:unknown_agent, "borg"}} = Install.check_pointer("borg", dir: skills)
    end

    @tag :tmp_dir
    test "the pointer lists only Faber-installed skills, never the user's own in a shared dir", %{
      skills: skills,
      ctx: ctx
    } do
      # `alpha` was installed via install/2 (marked); this one is the user's, sitting in the same dir.
      write_unmanaged_skill(skills, "users-own", "User wrote this themselves.")

      assert {:ok, :written} = Install.sync_pointer("claude", file: ctx, dir: skills)
      body = File.read!(ctx)

      assert body =~ "**alpha** — Alpha triages bugs."
      refute body =~ "users-own"
      refute body =~ "User wrote this themselves."

      # And the user's own skill being present must not register as drift.
      assert Install.check_pointer("claude", file: ctx, dir: skills) == :in_sync
    end
  end

  describe "agent_context_file/1" do
    test "expands known agents and returns nil for unknown" do
      assert Install.agent_context_file("claude") |> String.ends_with?("/.claude/CLAUDE.md")
      assert Install.agent_context_file("codex") |> String.ends_with?("/.codex/AGENTS.md")
      assert Install.agent_context_file("nope") == nil
    end
  end

  defp install_skill(dir, name, description) do
    md = "---\nname: #{name}\ndescription: #{description}\n---\n\n# #{name}\n"
    {:ok, _} = Install.install({name, md}, dir: dir, force: true)
  end

  # A skill the user wrote themselves — a SKILL.md with NO `.faber.json` marker, sharing the dir.
  defp write_unmanaged_skill(dir, name, description) do
    skill_dir = Path.join(dir, name)
    File.mkdir_p!(skill_dir)
    md = "---\nname: #{name}\ndescription: #{description}\n---\n\n# #{name}\n"
    File.write!(Path.join(skill_dir, "SKILL.md"), md)
  end
end
