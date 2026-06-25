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
end
