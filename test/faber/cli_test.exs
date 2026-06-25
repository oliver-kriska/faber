defmodule Faber.CLITest do
  # Not async: exercises run/2 which scans fixtures; also captures IO.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Faber.CLI

  @fixtures [base: "test/fixtures", min_messages: 0]

  describe "parse/1" do
    test "maps argv to {command, opts}" do
      assert CLI.parse([]) == {:help, []}
      assert CLI.parse(["help"]) == {:help, []}
      assert CLI.parse(["--version"]) == {:version, []}

      assert CLI.parse(["scan", "--limit", "5", "--rank-by", "rate"]) ==
               {:scan, [limit: 5, rank_by: "rate"]}

      assert CLI.parse(["propose", "--rank", "2", "--install"]) ==
               {:propose, [rank: 2, install: true]}

      assert CLI.parse(["serve", "--port", "9000", "--no-open"]) ==
               {:serve, [port: 9000, open: false]}

      assert CLI.parse(["bogus"]) == {:unknown, arg: "bogus"}
    end
  end

  describe "command/0" do
    test "returns nil outside a release (dev/test) so the normal app boot is unaffected" do
      assert CLI.command() == nil
    end
  end

  describe "run/2" do
    test "scan prints a ranked table" do
      out = capture_io(fn -> assert CLI.run(:scan, @fixtures ++ [limit: 5]) == 0 end)
      assert out =~ "friction"
      assert out =~ "sessions shown"
    end

    test "scan labels a codex session by its cwd project, not the rollout date dir" do
      opts = [base: "test/fixtures/codex", format: :codex, min_messages: 0]
      out = capture_io(fn -> assert CLI.run(:scan, opts) == 0 end)

      # session_meta cwd is /Users/x/Projects/demo → "demo/"; never the date-dir basename "codex".
      assert out =~ "demo/"
      refute out =~ "codex/codex-se"
    end

    test "propose drafts + evals a skill (stub LLM, native eval)" do
      out = capture_io(fn -> assert CLI.run(:propose, @fixtures ++ [rank: 1]) == 0 end)
      assert out =~ "composite"
      assert out =~ "Iron Laws"
    end

    test "propose --install writes the rendered skill into the skills dir" do
      tmp =
        Path.join(System.tmp_dir!(), "faber-cli-install-#{System.unique_integer([:positive])}")

      prev = Application.get_env(:faber, :skills_dir)
      Application.put_env(:faber, :skills_dir, tmp)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:faber, :skills_dir, prev),
          else: Application.delete_env(:faber, :skills_dir)

        File.rm_rf(tmp)
      end)

      out =
        capture_io(fn -> assert CLI.run(:propose, @fixtures ++ [rank: 1, install: true]) == 0 end)

      assert out =~ "installed → "

      # The stub proposal's name is "investigate-retry-loops"; the file must actually exist on disk.
      installed = Path.wildcard(Path.join([tmp, "*", "SKILL.md"]))
      assert [path] = installed
      assert File.read!(path) =~ "name:"
    end

    test "propose refuses a stack-mismatched session, and --force overrides" do
      opts = [base: "test/fixtures/nonelixir", min_messages: 0, rank: 1]

      err = capture_io(:stderr, fn -> assert CLI.run(:propose, opts) == 1 end)
      assert err =~ "stack mismatch"
      assert err =~ "--force"

      # --force skips the gate → the stub LLM drafts + native eval scores the skill.
      out = capture_io(fn -> assert CLI.run(:propose, opts ++ [force: true]) == 0 end)
      assert out =~ "composite"
    end

    test "help and version exit 0" do
      assert capture_io(fn -> assert CLI.run(:help, []) == 0 end) =~ "Usage:"
      assert capture_io(fn -> assert CLI.run(:version, []) == 0 end) =~ "faber"
    end

    test "unknown command exits 1 with usage" do
      err = capture_io(:stderr, fn -> assert CLI.run(:unknown, arg: "wat") == 1 end)
      assert err =~ "unknown command 'wat'"
    end
  end

  describe "serve via dispatch (opener injected)" do
    test "prints the URL and invokes the opener unless --no-open" do
      test_pid = self()
      opener = fn url -> send(test_pid, {:opened, url}) end

      out = capture_io(fn -> CLI.dispatch({:serve, opener: opener}) end)
      assert out =~ "Faber UI"
      assert_received {:opened, "http://localhost:" <> _}
    end

    test "--no-open does not invoke the opener" do
      test_pid = self()
      opener = fn url -> send(test_pid, {:opened, url}) end

      capture_io(fn -> CLI.dispatch({:serve, open: false, opener: opener}) end)
      refute_received {:opened, _}
    end
  end

  describe "maybe_apply_port/1" do
    test "overrides the endpoint http port for serve --port" do
      original = Application.get_env(:faber, FaberWeb.Endpoint)
      on_exit(fn -> Application.put_env(:faber, FaberWeb.Endpoint, original) end)

      CLI.maybe_apply_port({:serve, port: 9911})
      assert get_in(Application.get_env(:faber, FaberWeb.Endpoint), [:http, :port]) == 9911
    end

    test "is a no-op for non-serve commands" do
      assert CLI.maybe_apply_port({:scan, []}) == :ok
      assert CLI.maybe_apply_port(nil) == :ok
    end
  end
end
