defmodule Faber.ScanScopeTest do
  # `async: false` is load-bearing: these tests change the VM-wide working directory, and ExUnit
  # runs sync cases only after every async one has finished. An async module here would move the cwd
  # out from under unrelated tests.
  use ExUnit.Case, async: false

  alias Faber.Ingest.Format
  alias Faber.Scan
  alias Faber.Scan.Result
  alias Faber.Scan.Scope

  # A format that partitions by project, pointed at a tmp root instead of the real `~/.claude`.
  # Scoping has to be provable without reading (or depending on the shape of) the developer's own
  # transcripts, and `Format.resolve/1` takes a module directly, so the seam is already here.
  defmodule PartitionedFormat do
    @behaviour Faber.Ingest.Format

    alias Faber.Ingest.Format.Claude

    @impl true
    def default_base, do: Process.get(:test_base) || "/nonexistent"

    @impl true
    def project_base(base, cwd), do: Claude.project_base(base, cwd)

    @impl true
    def discover(base), do: Claude.discover(base)

    @impl true
    def stream_file!(path), do: Claude.stream_file!(path)

    @impl true
    def normalize(map), do: Claude.normalize(map)
  end

  # Same, minus `project_base/2` — the Codex/Gemini/OpenCode shape, where transcripts are not laid
  # out per project and only the `cwd` filter can scope.
  defmodule FlatFormat do
    @behaviour Faber.Ingest.Format

    alias Faber.Ingest.Format.Claude

    @impl true
    def default_base, do: Process.get(:test_base) || "/nonexistent"

    @impl true
    def discover(base), do: Claude.discover(base)

    @impl true
    def stream_file!(path), do: Claude.stream_file!(path)

    @impl true
    def normalize(map), do: Claude.normalize(map)
  end

  setup do
    cwd = File.cwd!()
    on_exit(fn -> File.cd!(cwd) end)
    :ok
  end

  # cd into `dir` and hand back the *resolved* cwd — on macOS the tmp dir arrives via /var, a symlink
  # to /private/var, and `File.cwd!/0` reports what the kernel resolved. That resolved form is what
  # Claude Code records and therefore what the slug must be built from.
  defp cd!(dir) do
    File.mkdir_p!(dir)
    File.cd!(dir)
    File.cwd!()
  end

  # A scratch root outside any git repository, for the cases that need "no repo above me".
  defp isolated_root! do
    root = Path.join(System.tmp_dir!(), "faber_scope_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp transcript_dir!(base, project) do
    {:ok, dir} = Format.Claude.project_base(base, project)
    File.mkdir_p!(dir)
    dir
  end

  describe "Claude.project_base/2 (the slug)" do
    test "flattens every non-alphanumeric character to a dash, preserving case" do
      # Verified against a real ~/.claude/projects — the rule is wider than "slashes become
      # dashes", and getting it wrong scopes to a directory that does not exist.
      assert {:ok, dir} = Format.Claude.project_base("/base", "/Users/o/Projects/faber")
      assert Path.basename(dir) == "-Users-o-Projects-faber"

      assert {:ok, under} =
               Format.Claude.project_base("/base", "/Users/o/Projects/andrej_skolenia")

      assert Path.basename(under) == "-Users-o-Projects-andrej-skolenia"

      assert {:ok, dot} = Format.Claude.project_base("/base", "/Users/o/.supacode/repos/x")
      assert Path.basename(dot) == "-Users-o--supacode-repos-x"

      assert {:ok, caps} = Format.Claude.project_base("/base", "/Users/o/webSerialCommunication")
      assert Path.basename(caps) == "-Users-o-webSerialCommunication"
    end

    test "joins onto the expanded base" do
      assert {:ok, dir} = Format.Claude.project_base("~/.claude/projects", "/tmp/x")
      assert dir == Path.join(Path.expand("~/.claude/projects"), "-tmp-x")
    end

    test "is pure — it reports where a directory would be, not whether it exists" do
      assert {:ok, _} = Format.Claude.project_base("/base", "/definitely/not/a/real/path")
    end

    test "rejects a non-binary cwd rather than raising" do
      assert :error = Format.Claude.project_base("/base", nil)
    end
  end

  describe "Format.project_base/3" do
    test "delegates to a format that implements it" do
      assert {:ok, _} = Format.project_base(PartitionedFormat, "/base", "/tmp/x")
    end

    test "answers :error for a format that does not partition by project" do
      assert :error = Format.project_base(FlatFormat, "/base", "/tmp/x")
      assert :error = Format.project_base(Format.Codex, "/base", "/tmp/x")
    end
  end

  describe "resolve/1 — explicit overrides" do
    test "all: true is the whole corpus" do
      assert %Scope{kind: :all, reason: :requested, root: nil, base: nil} =
               Scope.resolve(all: true)
    end

    test "an explicit base wins over the cwd" do
      # `--base` already names the files to read; narrowing it to the cwd's project on top would
      # make the flag unable to express "scan exactly this root".
      assert %Scope{kind: :all, reason: :explicit_base} = Scope.resolve(base: "/some/root")
    end
  end

  describe "resolve/1 — cwd" do
    @describetag :tmp_dir

    test "scopes to the cwd when it has a transcript directory", %{tmp_dir: tmp} do
      base = Path.join(tmp, "transcripts")
      cwd = cd!(Path.join(tmp, "proj"))
      Process.put(:test_base, base)
      dir = transcript_dir!(base, cwd)

      assert %Scope{kind: :project, root: ^cwd, label: "proj", base: ^dir, reason: nil} =
               Scope.resolve(format: PartitionedFormat)
    end

    test "walks up to the git root, so a subdirectory scopes to its repo", %{tmp_dir: tmp} do
      base = Path.join(tmp, "transcripts")
      repo = Path.join(tmp, "repo")
      File.mkdir_p!(repo)
      File.write!(Path.join(repo, ".git"), "gitdir: elsewhere")
      root = File.cd!(repo, &File.cwd!/0)
      dir = transcript_dir!(base, root)

      cd!(Path.join(repo, "lib/faber"))
      Process.put(:test_base, base)

      assert %Scope{kind: :project, root: ^root, base: ^dir} =
               Scope.resolve(format: PartitionedFormat)
    end

    test "stops at the git root instead of climbing to an ancestor's transcripts", %{tmp_dir: tmp} do
      # The bound that keeps `faber scan` honest. Unbounded, the walk reaches $HOME — which on a
      # real machine DOES have a transcript directory — and a scan inside a repo with no sessions
      # would silently claim to be scoped to whatever was once run in the home directory.
      base = Path.join(tmp, "transcripts")
      outer = cd!(tmp)
      transcript_dir!(base, outer)

      repo = Path.join(tmp, "repo")
      File.mkdir_p!(Path.join(repo, ".git"))
      cd!(Path.join(repo, "sub"))
      Process.put(:test_base, base)

      assert %Scope{kind: :all, reason: :unknown_cwd} = Scope.resolve(format: PartitionedFormat)
    end

    @tag tmp_dir: false
    test "outside a repo, only the cwd itself counts" do
      # Deliberately NOT the ExUnit tmp_dir: that lives inside *this* repo, so a walk from it always
      # finds faber's own `.git` and the no-repo-above-me case cannot be staged there at all.
      root = isolated_root!()
      base = Path.join(root, "transcripts")
      outer = cd!(Path.join(root, "outer"))
      transcript_dir!(base, outer)

      # `outer` has transcripts and is the direct parent — with no repo to bound it, an unbounded
      # walk would climb into it. Only the cwd may count here.
      cd!(Path.join([root, "outer", "plain"]))
      Process.put(:test_base, base)

      assert %Scope{kind: :all, reason: :unknown_cwd} = Scope.resolve(format: PartitionedFormat)
    end

    test "falls back to :all — never to empty — when the cwd is unknown", %{tmp_dir: tmp} do
      base = Path.join(tmp, "transcripts")
      File.mkdir_p!(base)
      cd!(Path.join(tmp, "nowhere"))
      Process.put(:test_base, base)

      assert %Scope{kind: :all, reason: :unknown_cwd, base: nil} =
               Scope.resolve(format: PartitionedFormat)
    end

    test "a format that doesn't partition still scopes, just without narrowing", %{tmp_dir: tmp} do
      cwd = cd!(Path.join(tmp, "proj"))
      Process.put(:test_base, Path.join(tmp, "transcripts"))

      # `base: nil` means "read everything and let member?/2 decide" — same ranking, no speedup.
      assert %Scope{kind: :project, root: ^cwd, base: nil, reason: nil} =
               Scope.resolve(format: FlatFormat)
    end
  end

  describe "to_opts/1" do
    test "narrows the scan base when the scope knows the project's directory" do
      assert Scope.to_opts(%Scope{kind: :project, base: "/t/-proj"}) == [base: "/t/-proj"]
    end

    test "narrows nothing for :all, an un-narrowable scope, or no scope" do
      assert Scope.to_opts(%Scope{kind: :all}) == []
      assert Scope.to_opts(%Scope{kind: :project, base: nil}) == []
      assert Scope.to_opts(nil) == []
    end
  end

  describe "member?/2" do
    test "nil (unscoped) and :all admit everything" do
      assert Scope.member?(nil, %{cwd: "/anywhere"})
      assert Scope.member?(%Scope{kind: :all}, %{cwd: "/anywhere"})
    end

    test "a project scope admits exactly its own root" do
      scope = %Scope{kind: :project, root: "/p/faber", base: "/t/-p-faber"}

      assert Scope.member?(scope, %{cwd: "/p/faber"})
      refute Scope.member?(scope, %{cwd: "/p/faber-site"})
      refute Scope.member?(scope, %{cwd: "/p/other"})
    end

    test "rejects a sibling that shares the lossy directory" do
      # `foo_bar` and `foo-bar` flatten to ONE directory, so narrowing alone would merge two
      # projects' sessions. This is why the cwd filter exists on top of the narrowing.
      scope = %Scope{kind: :project, root: "/p/foo_bar", base: "/t/-p-foo-bar"}

      assert Scope.member?(scope, %{cwd: "/p/foo_bar"})
      refute Scope.member?(scope, %{cwd: "/p/foo-bar"})
    end

    test "a session with no recorded cwd falls back to the directory it was found in" do
      narrowed = %Scope{kind: :project, root: "/p/faber", base: "/t/-p-faber"}
      unnarrowed = %Scope{kind: :project, root: "/p/faber", base: nil}

      # Narrowed: the directory is evidence. Un-narrowed: there is nothing to go on.
      assert Scope.member?(narrowed, %{cwd: nil})
      refute Scope.member?(unnarrowed, %{cwd: nil})
    end
  end

  describe "Scan.run/1 with :scope" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp} do
      base = Path.join(tmp, "transcripts")

      for {project, id} <- [{"/p/faber", "in"}, {"/p/other", "out"}] do
        dir = transcript_dir!(base, project)

        File.write!(
          Path.join(dir, "#{id}.jsonl"),
          ~s({"type":"user","sessionId":"#{id}","cwd":"#{project}","message":{"role":"user","content":"hi"}}\n)
        )
      end

      {:ok, base: base}
    end

    test "no scope keeps the historical whole-corpus behavior", %{base: base} do
      ids = base |> scan_ids(nil) |> Enum.sort()
      assert ids == ["in", "out"]
    end

    test "an :all scope keeps every session", %{base: base} do
      assert base |> scan_ids(%Scope{kind: :all}) |> Enum.sort() == ["in", "out"]
    end

    test "a narrowed project scope reads only that project's directory", %{base: base} do
      {:ok, dir} = Format.Claude.project_base(base, "/p/faber")
      scope = %Scope{kind: :project, root: "/p/faber", label: "faber", base: dir}

      # `base: nil` in the opts proves the narrowing did the work: without Scope.to_opts/1 feeding
      # the directory through, there is no root to discover under at all.
      assert Scan.run(scope: scope, min_messages: 0, cache: false) |> ids() == ["in"]
    end

    test "an un-narrowed project scope filters by cwd instead", %{base: base} do
      scope = %Scope{kind: :project, root: "/p/faber", label: "faber", base: nil}
      assert base |> scan_ids(scope) == ["in"]
    end
  end

  defp scan_ids(base, scope) do
    [base: base, scope: scope, min_messages: 0, cache: false] |> Scan.run() |> ids()
  end

  defp ids(results), do: Enum.map(results, fn %Result{session_id: id} -> id end)
end
