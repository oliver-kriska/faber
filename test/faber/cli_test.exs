defmodule Faber.CLITest do
  # Not async: exercises run/2 which scans fixtures; also captures IO.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Faber.CLI

  @fixtures [base: "test/fixtures", min_messages: 0]

  describe "parse/1" do
    test "maps argv to {command, opts}" do
      assert CLI.parse([]) == {:help, nil}
      assert CLI.parse(["help"]) == {:help, nil}
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

      assert CLI.parse(["consolidate", "--top", "3", "--cluster-threshold", "0.5", "--force"]) ==
               {:consolidate, [top: 3, cluster_threshold: 0.5, force: true]}

      assert CLI.parse(["feedback", "--dir", "/tmp/skills", "--format", "codex"]) ==
               {:feedback, [dir: "/tmp/skills", format: "codex"]}

      assert CLI.parse(["serve", "--port", "9000", "--no-open"]) ==
               {:serve, [port: 9000, open: false]}

      assert CLI.parse(["sync", "--target", "claude,codex", "--check"]) ==
               {:sync, [target: "claude,codex", check: true]}

      assert CLI.parse(["bogus"]) == {:unknown, arg: "bogus"}
    end
  end

  # F4 (2026-07-15 audit): every clause discarded OptionParser's invalid list (`{opts, _, _}`), so
  # `faber propose --help` parsed to a valid `{:propose, []}` and spent ~1min on a real LLM call.
  # The audit reproduced exactly that. parse/1 stays pure — it returns the outcome as data.
  describe "parse/1 refuses to run a command it didn't understand" do
    # Every subcommand with a parse clause — a new one must be added here too [codex #9].
    @subcommands ~w(scan propose refine consolidate feedback serve sync)

    test "an unknown switch never yields a runnable command, for any subcommand" do
      for sub <- @subcommands do
        assert CLI.parse([sub, "--definitely-not-a-flag"]) ==
                 {:parse_error, String.to_existing_atom(sub), ["--definitely-not-a-flag"]},
               "#{sub} accepted an unknown switch"
      end
    end

    test "--help after any subcommand asks for help, and runs nothing" do
      for sub <- @subcommands, flag <- ["--help", "-h"] do
        assert CLI.parse([sub, flag]) == {:help, String.to_existing_atom(sub)},
               "#{sub} #{flag} did not resolve to help"
      end
    end

    test "propose --help does NOT parse as a propose (the audited regression)" do
      refute match?({:propose, _}, CLI.parse(["propose", "--help"]))
      assert CLI.parse(["propose", "--help"]) == {:help, :propose}
    end

    test "--help wins even alongside an invalid flag" do
      # Someone unsure enough about a flag to ask for help should get help, not a complaint.
      assert CLI.parse(["propose", "--bogus", "--help"]) == {:help, :propose}
    end

    test "a bare `help` asks for help only as the first token" do
      assert CLI.parse(["propose", "help"]) == {:help, :propose}
    end

    test "an option VALUE of `help` is a value, not a help request" do
      # This scanned every token for "help", so a directory or ref legitimately named `help` printed
      # usage instead of being used. `--help`/`-h` stay position-free; a bare `help` does not.
      assert CLI.parse(["scan", "--base", "help"]) == {:scan, [base: "help"]}
      assert CLI.parse(["feedback", "--dir", "help"]) == {:feedback, [dir: "help"]}
      assert CLI.parse(["scan", "--format", "help"]) == {:scan, [format: "help"]}
    end

    test "a valid flag next to an invalid one still fails — no partial run" do
      assert CLI.parse(["scan", "--limit", "5", "--nope"]) == {:parse_error, :scan, ["--nope"]}
    end

    test "every invalid switch is reported, not just the first" do
      assert {:parse_error, :scan, invalid} = CLI.parse(["scan", "--nope", "--also-nope"])
      assert Enum.sort(invalid) == ["--also-nope", "--nope"]
    end

    test "a wrongly-typed value is a parse error, not a silent drop" do
      # --limit is :integer; "abc" can't be one. OptionParser reports it as invalid.
      assert {:parse_error, :scan, ["--limit"]} = CLI.parse(["scan", "--limit", "abc"])
    end

    test "valid invocations are unaffected" do
      assert CLI.parse(["scan", "--limit", "5"]) == {:scan, [limit: 5]}

      assert CLI.parse(["propose", "--rank", "2", "--install"]) ==
               {:propose, [rank: 2, install: true]}

      assert CLI.parse(["serve", "--port", "9000"]) == {:serve, [port: 9000]}
    end
  end

  describe "run/2 renders the non-running outcomes" do
    test "a parse error prints usage to stderr and exits non-zero" do
      # stderr, not stdout: this is the error path, and stdout stays clean for piped output.
      stderr =
        capture_io(:stderr, fn ->
          assert CLI.run(:parse_error, subcommand: :propose, invalid: ["--bogus"]) == 1
        end)

      assert stderr =~ "unrecognized option for 'propose': --bogus"
      assert stderr =~ "faber propose"
    end

    test "multiple invalid switches are pluralized and all listed" do
      stderr =
        capture_io(:stderr, fn ->
          CLI.run(:parse_error, subcommand: :scan, invalid: ["--a", "--b"])
        end)

      assert stderr =~ "unrecognized options for 'scan': --a, --b"
    end

    test "help for a subcommand shows that subcommand, not the whole manual" do
      # This used to assert only `out =~ "faber propose"` — which the FULL usage satisfies too, so
      # it passed happily while run/2 ignored the subcommand entirely. The absence of the other
      # commands is the part that discriminates.
      out = capture_io(fn -> assert CLI.run(:help, subcommand: :propose) == 0 end)

      assert out =~ "faber propose"
      assert out =~ "--trigger"
      refute out =~ "faber sync"
      refute out =~ "faber serve"
    end

    test "help for a --source-taking subcommand keeps the sources/formats footer" do
      out = capture_io(fn -> CLI.run(:help, subcommand: :scan) end)
      assert out =~ "Sources (--source)"

      # ...and one that takes neither isn't padded with flags it doesn't accept.
      serve = capture_io(fn -> CLI.run(:help, subcommand: :serve) end)
      refute serve =~ "Sources (--source)"
    end

    test "top-level help still lists every subcommand" do
      out = capture_io(fn -> assert CLI.run(:help, []) == 0 end)
      for sub <- @subcommands, do: assert(out =~ "faber #{sub}", "top-level help omitted #{sub}")
    end

    test "every subcommand slices a non-empty help block naming itself" do
      # usage/1 slices per-subcommand help out of the single usage/0 heredoc instead of keeping a
      # second copy, which couples it to that text's layout. Reformat the heredoc and this fails
      # loudly, rather than `faber scan --help` quietly going blank or dumping the whole manual.
      for sub <- @subcommands do
        out = capture_io(fn -> CLI.run(:help, subcommand: String.to_existing_atom(sub)) end)

        assert out =~ "faber #{sub}", "#{sub} help did not name itself"

        refute out =~ "local-first improvement engine",
               "#{sub} help fell back to the full manual — usage/0's layout probably moved"
      end
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

  describe "humanize_error/1" do
    test "names the fix, not the tuple, for a missing claude CLI" do
      msg = CLI.humanize_error({:claude_cli_unavailable, "claude"})

      assert msg =~ "isn't on PATH"
      assert msg =~ ":claude_bin"
      refute msg =~ "claude_cli_unavailable"
    end

    test "a timeout reports the bound that was exceeded and how to raise it" do
      msg = CLI.humanize_error({:claude_cli_timeout, 300_000})

      assert msg =~ "300000ms"
      assert msg =~ ":claude_timeout_ms"
    end

    # The exact case from GUIDE §21 / the plan: an already-installed skill must offer the three
    # ways out rather than dumping {:exists, path}.
    test "an already-installed skill offers --force and refine" do
      msg = CLI.humanize_error({:exists, "/tmp/skills/foo/SKILL.md"})

      assert msg =~ "/tmp/skills/foo/SKILL.md"
      assert msg =~ "--force"
      assert msg =~ "faber refine"
    end

    test "an invalid adapter lists each reason on its own line" do
      msg = CLI.humanize_error({:invalid_adapter, ["missing name", "no file_globs"]})

      assert msg =~ "  - missing name"
      assert msg =~ "  - no file_globs"
    end

    # Derived from Install's registry, so adding an agent can't leave this message behind.
    test "an unknown sync agent lists the known ones from Install's registry" do
      msg = CLI.humanize_error({:unknown_agent, "emacs"})

      assert msg =~ ~s("emacs")

      for agent <- Map.keys(Faber.Install.agent_context_files()) do
        assert msg =~ agent
      end
    end

    test "multi-line subprocess output collapses to its first line" do
      msg =
        CLI.humanize_error({:claude_cli_exit, 2, "boom: bad flag\nstack line 1\nstack line 2"})

      assert msg =~ "exited 2"
      assert msg =~ "boom: bad flag"
      refute msg =~ "stack line 1"
    end

    # The fallback is deliberate: an unrecognized shape must stay honest rather than get a
    # confidently-wrong sentence invented for it.
    test "an unknown shape falls back to inspect/1" do
      assert CLI.humanize_error({:some_future_error, 42}) == "{:some_future_error, 42}"
    end
  end

  describe "run/2" do
    test "scan prints a ranked table" do
      out = capture_io(fn -> assert CLI.run(:scan, @fixtures ++ [limit: 5]) == 0 end)
      assert out =~ "friction"
      assert out =~ ~r/\d+ sessions? across \d+ projects? in \d+ms/
    end

    # Parity with the mix task and the dashboard, which have shown these signals all along — the
    # release CLI ranked on friction while hiding every input that produced it.
    test "scan shows the signal columns, not just the score" do
      out = capture_io(fn -> assert CLI.run(:scan, @fixtures ++ [limit: 5]) == 0 end)

      for column <- ["friction(raw)", "tools", "errs", "ctx", "opp"] do
        assert out =~ column, "scan table is missing the #{column} column"
      end

      # The friction column says which scale it's on; a bare "friction" invites reading a raw
      # weighted score as a normalized one.
      refute out =~ ~r/\bfriction\s+fingerprint/
    end

    test "scan's header counts sessions AND distinct projects" do
      out = capture_io(fn -> assert CLI.run(:scan, @fixtures ++ [limit: 5]) == 0 end)

      # test/fixtures spans fixtures/, nonelixir/ and codex/ — a count of 1 would mean the project
      # label collapsed, which is what made the scribe-run scope surprise invisible.
      assert out =~ ~r/5 sessions across 3 projects/
    end

    # The first-run outcome for anyone whose transcripts aren't where faber looked. "No sessions
    # matched." named none of the three things that cause it.
    test "an empty scan names the three causes instead of just reporting nothing" do
      out =
        capture_io(fn ->
          assert CLI.run(:scan, base: "test/fixtures", min_messages: 99_999) == 0
        end)

      assert out =~ "No sessions matched"
      assert out =~ "--min-messages"
      assert out =~ "--base"
      assert out =~ "--format"
      # The known-format list is derived from the ingest registry, not retyped here.
      assert out =~ "claude"
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

    test "consolidate drafts top-N proposals, merges the cluster, and prints outcomes" do
      # The stub LLM proposes the identical canned skill for every session, so the top-2
      # proposals form one cluster; the (stub) merge passes the native eval gate → one MERGED
      # outcome line plus the summary. --force skips the stack gate (the smooth fixture has no
      # file_paths to match).
      out =
        capture_io(fn ->
          assert CLI.run(:consolidate, @fixtures ++ [top: 2, force: true]) == 0
        end)

      assert out =~ "MERGED"
      assert out =~ "investigate-retry-loops"
      assert out =~ "1 cluster(s): 1 merged, 0 kept, 0 kept-originals, 0 errors."
    end

    # The first-run failure this fixes: faber pointed at an empty or wrong root answered "no session
    # at rank 1", which sends a new user to fix a rank that was never the problem.
    test "propose on an empty corpus blames the corpus, not the rank" do
      empty =
        Path.join(System.tmp_dir!(), "faber-cli-prop-#{System.unique_integer([:positive])}")

      File.mkdir_p!(empty)
      on_exit(fn -> File.rm_rf(empty) end)

      err =
        capture_io(:stderr, fn ->
          capture_io(fn -> assert CLI.run(:propose, base: empty, min_messages: 0) == 1 end)
        end)

      assert err =~ "no sessions found under #{empty}"
      assert err =~ "--min-messages"
      refute err =~ "rank"
    end

    test "refine on an empty corpus blames the corpus too" do
      empty =
        Path.join(System.tmp_dir!(), "faber-cli-ref-#{System.unique_integer([:positive])}")

      File.mkdir_p!(empty)
      on_exit(fn -> File.rm_rf(empty) end)

      err =
        capture_io(:stderr, fn ->
          capture_io(fn -> assert CLI.run(:refine, base: empty, min_messages: 0) == 1 end)
        end)

      assert err =~ "no sessions found under #{empty}"
      refute err =~ "rank"
    end

    # ...but a rank past the end of a REAL corpus is genuinely about the rank, and says so with the
    # count that makes it obvious.
    test "propose past the end of a real corpus still names the rank" do
      err =
        capture_io(:stderr, fn ->
          capture_io(fn -> assert CLI.run(:propose, @fixtures ++ [rank: 99]) == 1 end)
        end)

      assert err =~ "no session at rank 99"
      assert err =~ ~r/only \d+ sessions matched/
      refute err =~ "no sessions found"
    end

    test "consolidate on an empty corpus blames the corpus, not the proposals" do
      # An empty transcript base yields no sessions → actionable failure (1). It must NOT say "no
      # proposals to consolidate": nothing was ever drafted, because nothing was found, and the
      # user's real problem is the root faber searched.
      empty =
        Path.join(System.tmp_dir!(), "faber-cli-cons-#{System.unique_integer([:positive])}")

      File.mkdir_p!(empty)
      on_exit(fn -> File.rm_rf(empty) end)

      err =
        capture_io(:stderr, fn ->
          capture_io(fn ->
            assert CLI.run(:consolidate, base: empty, min_messages: 0) == 1
          end)
        end)

      assert err =~ "no sessions found under #{empty}"
      assert err =~ "--min-messages"
      refute err =~ "no proposals to consolidate"
    end

    test "consolidate reports when there is nothing to consolidate" do
      # The other way to reach zero candidates, and the one that IS about proposals: sessions were
      # found, but every one of them failed the stack gate (no --force), so none was ever drafted.
      err =
        capture_io(:stderr, fn ->
          capture_io(fn ->
            assert CLI.run(:consolidate, base: "test/fixtures/nonelixir", min_messages: 0) == 1
          end)
        end)

      assert err =~ "no proposals to consolidate"
    end

    # A pipe has no width to fit, so there is nothing to truncate FOR — and clipping here would
    # corrupt the output for the only consumer that can use the full label. Truncation exists to
    # stop a terminal wrapping a row; captured IO (like a pipe or a file) is not a tty.
    test "piped output keeps full session labels" do
      out = capture_io(fn -> assert CLI.run(:scan, @fixtures ++ [limit: 5]) == 0 end)

      assert out =~ "fixtures/malformed_session"
      refute out =~ "…"
    end

    test "feedback truncates an over-long skill name instead of wrapping the row" do
      dir = Path.join(System.tmp_dir!(), "faber-cli-fb-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(dir) end)

      long = "investigate-retry-loops-before-escalating-to-a-rewrite"
      {:ok, path} = Faber.Install.install({long, "---\nname: #{long}\n---\n# D\n"}, dir: dir)

      marker = path |> Path.dirname() |> Path.join(".faber.json")
      data = marker |> File.read!() |> Jason.decode!()

      File.write!(
        marker,
        Jason.encode!(Map.put(data, "installed_at", "2000-01-01T00:00:00Z")) <> "\n"
      )

      out = capture_io(fn -> assert CLI.run(:feedback, @fixtures ++ [dir: dir]) == 0 end)
      lines = String.split(out, "\n")
      header = Enum.find(lines, &(&1 =~ "verdict"))
      row = Enum.find(lines, &(&1 =~ "investigate-retry-loops-before-"))

      # Clipped to the 32-wide column, and visibly so — a silent clip reads as a real name.
      assert row =~ "…"
      refute row =~ long

      # The row still lines up: an untruncated 53-char name would push every column past the header.
      assert String.length(row) <= String.length(header)

      # The hint below the table is prose, not a column, and names the skill in full — truncating
      # there would leave the user unable to act on what it tells them to do.
      assert out =~ "unused: #{long}"
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
