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

      assert CLI.parse(["scan", "--format", "opencode"]) ==
               {:scan, [format: "opencode"]}

      assert CLI.parse(["propose", "--rank", "2", "--install"]) ==
               {:propose, [rank: 2, install: true]}

      assert CLI.parse(["propose", "--rank", "1", "--trigger"]) ==
               {:propose, [rank: 1, trigger: true]}

      # --base / --min-messages reach the scan opts (run/2 Keyword.take's them) — a strict
      # OptionParser silently DROPS unknown switches, so these must stay in the parser lists.
      assert CLI.parse(["scan", "--base", "/tmp/x", "--min-messages", "3"]) ==
               {:scan, [base: "/tmp/x", min_messages: 3]}

      assert CLI.parse(["propose", "--limit", "10", "--base", "/tmp/x", "--min-messages", "3"]) ==
               {:propose, [limit: 10, base: "/tmp/x", min_messages: 3]}

      assert CLI.parse([
               "refine",
               "--iterations",
               "3",
               "--trigger",
               "--holdout",
               "--min-improvement",
               "0.05"
             ]) ==
               {:refine, [iterations: 3, trigger: true, holdout: true, min_improvement: 0.05]}

      assert CLI.parse(["feedback", "--dir", "/tmp/skills", "--format", "codex"]) ==
               {:feedback, [dir: "/tmp/skills", format: "codex"]}

      assert CLI.parse(["serve", "--port", "9000", "--no-open"]) ==
               {:serve, [port: 9000, open: false]}

      assert CLI.parse(["sync", "--target", "claude,codex", "--check"]) ==
               {:sync, [target: "claude,codex", check: true]}

      assert CLI.parse(["bogus"]) == {:unknown, arg: "bogus"}
    end
  end

  describe "command/0" do
    test "returns nil outside a release (dev/test) so the normal app boot is unaffected" do
      assert CLI.command() == nil
    end
  end

  describe "guarded/1 (the dispatch halt-guard)" do
    test "passes a clean status through" do
      assert CLI.guarded(fn -> 0 end) == 0
    end

    test "a raise becomes exit status 1" do
      err = capture_io(:stderr, fn -> assert CLI.guarded(fn -> raise "boom" end) == 1 end)
      assert err =~ "faber: boom"
    end

    # Faber.Subprocess re-raises abnormal task exits via exit/1 — rescue alone would let these
    # escape the dispatch process, so System.halt/1 would never run and a scripted `faber scan`
    # would hang the VM instead of failing fast.
    test "an exit becomes exit status 1" do
      err = capture_io(:stderr, fn -> assert CLI.guarded(fn -> exit(:boom) end) == 1 end)
      assert err =~ "uncaught exit"
    end

    test "a throw becomes exit status 1" do
      err = capture_io(:stderr, fn -> assert CLI.guarded(fn -> throw(:boom) end) == 1 end)
      assert err =~ "uncaught throw"
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

    test "propose --trigger adds the behavioral dimension without breaking the run" do
      # The trigger eval degrades gracefully under the stub judge (a non-`triggers` reply counts as
      # a routing miss, never a crash), so the run still completes and renders the eval.
      out =
        capture_io(fn -> assert CLI.run(:propose, @fixtures ++ [rank: 1, trigger: true]) == 0 end)

      assert out =~ "composite"
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

    test "refine loops propose → eval → keep and renders the history (stub LLM)" do
      # The Stub LLM re-proposes an identical skill each iteration, so every candidate is a
      # "no improvement" rejection — the run still completes, renders the per-iteration history
      # (reflect strategy → "reflect: <dimension>" descriptions), and prints the final best.
      # target 1.1 is unreachable, or the stub's perfect seed would end the loop at 0 iterations.
      opts = @fixtures ++ [rank: 1, iterations: 2, target: 1.1]
      out = capture_io(fn -> assert CLI.run(:refine, opts) == 0 end)

      assert out =~ "refined"
      assert out =~ "reflect:"
      assert out =~ "no improvement"
      assert out =~ "Iron Laws"
    end

    test "feedback reports installed-skill usage across scanned sessions" do
      dir = Path.join(System.tmp_dir!(), "faber-cli-fb-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(dir) end)

      {:ok, path} =
        Faber.Install.install({"demo-skill", "---\nname: demo-skill\n---\n# D\n"}, dir: dir)

      # Pin the install into the past so the (old) fixture transcripts count as post-install.
      marker = path |> Path.dirname() |> Path.join(".faber.json")
      data = marker |> File.read!() |> Jason.decode!()

      File.write!(
        marker,
        Jason.encode!(Map.put(data, "installed_at", "2000-01-01T00:00:00Z")) <> "\n"
      )

      out = capture_io(fn -> assert CLI.run(:feedback, @fixtures ++ [dir: dir]) == 0 end)
      assert out =~ "demo-skill"
      assert out =~ "verdict"

      # An empty skills dir reports the no-skills hint instead of an empty table.
      empty = Path.join(dir, "none")
      File.mkdir_p!(empty)
      out2 = capture_io(fn -> assert CLI.run(:feedback, @fixtures ++ [dir: empty]) == 0 end)
      assert out2 =~ "No Faber-installed skills"
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

    test "sync writes the managed pointer block and --check reports drift" do
      dir = Path.join(System.tmp_dir!(), "faber-cli-sync-#{System.unique_integer([:positive])}")
      skills = Path.join(dir, "skills")
      ctx = Path.join(dir, "CLAUDE.md")
      on_exit(fn -> File.rm_rf(dir) end)

      {:ok, _} =
        Faber.Install.install(
          {"demo-skill", "---\nname: demo-skill\ndescription: Demo does things.\n---\n# Demo\n"},
          dir: skills
        )

      out =
        capture_io(fn ->
          assert CLI.run(:sync, target: "claude", file: ctx, dir: skills) == 0
        end)

      assert out =~ "claude: pointer updated"
      assert File.read!(ctx) =~ "**demo-skill** — Demo does things."

      # --check on an up-to-date file exits 0; after a new skill it reports drift and exits 1.
      assert capture_io(fn ->
               assert CLI.run(:sync, target: "claude", file: ctx, dir: skills, check: true) == 0
             end) =~ "in sync"

      {:ok, _} =
        Faber.Install.install(
          {"new-one", "---\nname: new-one\ndescription: New thing.\n---\n# New\n"},
          dir: skills
        )

      err_out =
        capture_io(fn ->
          assert CLI.run(:sync, target: "claude", file: ctx, dir: skills, check: true) == 1
        end)

      assert err_out =~ "DRIFT"
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
