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
end
