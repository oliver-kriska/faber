defmodule Faber.CLITest do
  # Not async: exercises run/2 which scans fixtures; also captures IO.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Faber.CLI
  alias Faber.Proposal.Store

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
    @subcommands ~w(scan propose refine consolidate feedback serve sync proposals show install)

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

  describe "propose --top N absorbs consolidate" do
    test "the batch flags parse on propose" do
      assert CLI.parse(["propose", "--top", "3", "--cluster-threshold", "0.4"]) ==
               {:propose, [top: 3, cluster_threshold: 0.4]}
    end

    test "--rank and --top together is a refusal, not a silent precedence rule" do
      # Both name "which session(s) to propose for", and they disagree. Picking a winner would make
      # the loser vanish without a word; the user gets told instead.
      assert CLI.parse(["propose", "--rank", "3", "--top", "5"]) ==
               {:conflicting_opts, :propose, ["--rank", "--top"]}
    end

    test "either one alone is fine" do
      assert CLI.parse(["propose", "--rank", "3"]) == {:propose, [rank: 3]}
      assert CLI.parse(["propose", "--top", "5"]) == {:propose, [top: 5]}
    end

    test "the conflict names both flags on stderr and exits non-zero" do
      stderr =
        capture_io(:stderr, fn ->
          assert CLI.run(:conflicting_opts, subcommand: :propose, invalid: ["--rank", "--top"]) ==
                   1
        end)

      assert stderr =~ "--rank"
      assert stderr =~ "--top"
      assert stderr =~ "faber propose"
    end

    test "--hazard and --top together is a refusal too" do
      # Same reason as --rank/--top: both name what to propose for, and --hazard draws a HOOK from
      # one session while --top batches SKILLS across many. There is no coherent merge.
      assert CLI.parse(["propose", "--hazard", "pipe_masks_exit", "--top", "5"]) ==
               {:conflicting_opts, :propose, ["--hazard", "--top"]}
    end

    test "consolidate still parses every flag it used to" do
      # The alias is deprecated, not broken: a script that pins the old spelling keeps working.
      assert CLI.parse(["consolidate", "--top", "4", "--cluster-threshold", "0.6"]) ==
               {:consolidate, [top: 4, cluster_threshold: 0.6]}
    end
  end

  describe "propose --hazard KIND (a hook, not a skill)" do
    test "the flag parses, and takes the hazard class as its value" do
      assert CLI.parse(["propose", "--hazard", "pipe_masks_exit"]) ==
               {:propose, [hazard: "pipe_masks_exit"]}

      assert CLI.parse(["propose", "--hazard", "pipe_masks_exit", "--install"]) ==
               {:propose, [hazard: "pipe_masks_exit", install: true]}
    end

    test "--hazard combines with neither ranking flag" do
      # A hazard is orthogonal to the friction ranking by construction, so honouring `--rank`
      # alongside it would silently discard whichever the user meant.
      for ranking <- [["--rank", "3"], ["--top", "5"]] do
        assert {:conflicting_opts, :propose, flags} =
                 CLI.parse(["propose", "--hazard", "pipe_masks_exit"] ++ ranking)

        assert "--hazard" in flags
        assert hd(ranking) in flags
      end
    end

    test "a scan with no such hazard exits non-zero, and says what a clean scan does NOT mean" do
      # These sessions carry no hazard. The distinction the message has to carry: Faber detects ONE
      # class today, so "not found" means that class was absent — not that the sessions are safe.
      stderr =
        capture_io(:stderr, fn ->
          assert CLI.run(:propose, hazard: "pipe_masks_exit", base: "test/fixtures/nonelixir") ==
                   1
        end)

      assert stderr =~ "no session in this scan carries a `pipe_masks_exit` hazard"
      assert stderr =~ "Known hazard classes: pipe_masks_exit"
      assert stderr =~ "ONE class of frictionless hazard today"
    end

    test "a typo'd class is reported as not-found, with the known list to correct it against" do
      # No id-minting means no id to typo — but the class name is still typed by hand, and a bare
      # "not found" would leave no way to tell a typo from a genuinely absent hazard.
      stderr =
        capture_io(:stderr, fn ->
          assert CLI.run(:propose, [hazard: "pipe_masks_exti"] ++ @fixtures) == 1
        end)

      assert stderr =~ "`pipe_masks_exti`"
      assert stderr =~ "Known hazard classes: pipe_masks_exit"
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

  # The plan's centerpiece, and a real loss event: a live `consolidate --top 10` spent ~10 LLM calls,
  # produced 4 eval-passing skills (two merges at composite 0.8016), printed a 7-line summary, and
  # lost every byte. The merges especially — drawn from several sessions at once, so no
  # `propose --rank N` can reproduce them.
  #
  # The suite runs with the store OFF (config/test.exs) so async tests that propose stay
  # independent; these turn it on against a per-test dir, which is also what proves the CLI is a
  # writer at all — it wasn't, before Phase 2. Only the dashboard was.
  describe "artifacts are written for every paid outcome" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp_dir} do
      Application.put_env(:faber, :proposal_store, true)
      Application.put_env(:faber, :proposals_dir, Path.join(tmp_dir, "proposals"))

      on_exit(fn ->
        Application.put_env(:faber, :proposal_store, false)
        Application.delete_env(:faber, :proposals_dir)
      end)

      :ok
    end

    test "propose files its draft before printing it" do
      out = capture_io(fn -> assert CLI.run(:propose, @fixtures ++ [force: true]) == 0 end)

      assert [record] = Store.list()
      assert record.outcome == :single
      assert record.md =~ "investigate-retry-loops"
      assert record.eval[:composite]

      # ...and tells the user the id, or the artifact may as well not exist.
      assert out =~ record.id
      assert out =~ "faber show"
    end

    test "refine files its best" do
      out =
        capture_io(fn ->
          assert CLI.run(:refine, @fixtures ++ [force: true, iterations: 1]) == 0
        end)

      assert [record] = Store.list()
      assert record.outcome == :single
      assert record.eval[:composite]
      assert out =~ record.id
    end

    # THE regression test for the live loss.
    test "consolidate files the merge, with every session that fed it" do
      out =
        capture_io(fn ->
          assert CLI.run(:consolidate, @fixtures ++ [top: 2, force: true]) == 0
        end)

      assert [record] = Store.list()
      assert record.outcome == :merged
      assert record.md =~ "investigate-retry-loops"

      # The merge's own eval — the number the gate passed it on — not a guess.
      assert record.eval[:composite]

      # Provenance is the whole point: a merge spans sessions, and `session_key` names only one.
      refute record.source_sessions == []
      assert out =~ record.id
      assert out =~ "artifact"
    end

    # `--top 1` used to mean "cluster one proposal with nothing": filed `:kept`, never gated. It
    # routes to the plain propose path now, so the same command files `:single` WITH an eval — the
    # degenerate cluster-of-one is gone rather than reproduced.
    test "top: 1 is plain propose, and is gated like it" do
      capture_io(fn -> assert CLI.run(:propose, @fixtures ++ [top: 1, force: true]) == 0 end)

      assert [record] = Store.list()
      assert record.outcome == :single
      assert record.eval[:composite]
    end

    # NO CLI-level test for a filed `:kept` singleton, deliberately. It used to ride on
    # `consolidate --top 1` — one proposal clustered with nothing — and that degenerate path is
    # gone. It cannot be reconstructed here either: the Stub answers every fixture session with the
    # SAME draft, so Jaccard is 1.0 and `>= threshold` merges them at any threshold a float can
    # hold. `{:kept, _}` stays covered where it can be built honestly (consolidate_test.exs, over
    # dissimilar proposals), and the filing helper it shares with `:merged` is covered above.

    # A store that cannot write must not deny the user output they already paid for.
    test "a disabled store never fails the command" do
      Application.put_env(:faber, :proposal_store, false)

      out = capture_io(fn -> assert CLI.run(:propose, @fixtures ++ [force: true]) == 0 end)

      assert out =~ "investigate-retry-loops"
      refute out =~ "artifact"
    end
  end

  describe "proposals / show" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp_dir} do
      Application.put_env(:faber, :proposal_store, true)
      Application.put_env(:faber, :proposals_dir, Path.join(tmp_dir, "proposals"))

      on_exit(fn ->
        Application.put_env(:faber, :proposal_store, false)
        Application.delete_env(:faber, :proposals_dir)
      end)

      capture_io(fn -> CLI.run(:propose, @fixtures ++ [force: true]) end)
      [record] = Store.list()
      {:ok, record: record}
    end

    test "proposals lists what was kept, with the engine that scored it", %{record: record} do
      out = capture_io(fn -> assert CLI.run(:proposals, []) == 0 end)

      assert out =~ record.id
      assert out =~ record.name
      assert out =~ "single"
      # The engine separates the adapter's verdict from a native:fallback — it must be visible
      # without opening the artifact.
      assert out =~ to_string(record.eval[:engine])
    end

    test "show renders the full SKILL.md and the eval breakdown", %{record: record} do
      out = capture_io(fn -> assert CLI.run(:show, id: record.id) == 0 end)

      assert out =~ record.md
      assert out =~ "dimensions:"
      assert out =~ "sessions"
      assert out =~ record.id
    end

    test "show accepts an unambiguous prefix", %{record: record} do
      prefix = String.slice(record.id, 0, 20)
      out = capture_io(fn -> assert CLI.run(:show, id: prefix) == 0 end)
      assert out =~ record.name
    end

    # Ids are <session>-<content>, so every proposal from ONE session shares the first segment —
    # a short prefix is ambiguous exactly where it's most used, and must never resolve to a guess.
    test "an ambiguous prefix lists the candidates instead of picking one" do
      capture_io(fn -> CLI.run(:propose, @fixtures ++ [force: true, rank: 2]) end)
      records = Store.list()
      assert length(records) >= 2

      err =
        capture_io(:stderr, fn ->
          capture_io(fn -> assert CLI.run(:show, id: "") == 1 end)
        end)

      assert err =~ "matches"
      for r <- records, do: assert(err =~ r.id)
    end

    test "an unknown id says so and points at proposals" do
      err =
        capture_io(:stderr, fn ->
          capture_io(fn -> assert CLI.run(:show, id: "ffffffffffff-ffffffffffff") == 1 end)
        end)

      assert err =~ "no proposal with that id"
      assert err =~ "faber proposals"
    end

    test "--prune names what it removed", %{record: record} do
      capture_io(fn -> CLI.run(:propose, @fixtures ++ [force: true, rank: 2]) end)
      assert length(Store.list()) >= 2

      out = capture_io(fn -> assert CLI.run(:proposals, prune: true, keep: 1) == 0 end)

      # "pruned 12 proposals" with no names is indistinguishable from having deleted the wrong 12.
      assert out =~ "Pruned"
      assert out =~ "kept the 1 newest"
      assert length(Store.list()) == 1
      refute is_nil(record)
    end

    test "--prune with nothing to remove says so instead of claiming a prune" do
      out = capture_io(fn -> assert CLI.run(:proposals, prune: true, keep: 50) == 0 end)

      assert out =~ "Nothing to prune"
      assert length(Store.list()) == 1
    end

    test "show without an id refuses rather than running" do
      assert CLI.parse(["show"]) == {:missing_id, :show}

      err = capture_io(:stderr, fn -> assert CLI.run(:missing_id, subcommand: :show) == 1 end)
      assert err =~ "needs an artifact id"
    end

    # `faber install a b` must not quietly install only `a`.
    test "a second positional is an error, not a silent drop" do
      assert CLI.parse(["install", "abc", "def"]) == {:extra_args, :install, ["abc", "def"]}

      err =
        capture_io(:stderr, fn ->
          assert CLI.run(:extra_args, subcommand: :install, extra: ["abc", "def"]) == 1
        end)

      assert err =~ "exactly one artifact id"
    end
  end

  describe "install <id> — diff first, never a blind overwrite" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp_dir} do
      Application.put_env(:faber, :proposal_store, true)
      Application.put_env(:faber, :proposals_dir, Path.join(tmp_dir, "proposals"))

      on_exit(fn ->
        Application.put_env(:faber, :proposal_store, false)
        Application.delete_env(:faber, :proposals_dir)
      end)

      capture_io(fn -> CLI.run(:propose, @fixtures ++ [force: true]) end)
      [record] = Store.list()
      {:ok, record: record, dir: Path.join(tmp_dir, "skills")}
    end

    test "installs an artifact by id", %{record: record, dir: dir} do
      out = capture_io(fn -> assert CLI.run(:install, id: record.id, dir: dir) == 0 end)

      assert out =~ "installed →"
      path = Path.join([dir, record.name, "SKILL.md"])
      assert File.read!(path) == record.md
    end

    test "installs by an unambiguous prefix too", %{record: record, dir: dir} do
      prefix = String.slice(record.id, 0, 20)

      assert capture_io(fn -> assert CLI.run(:install, id: prefix, dir: dir) == 0 end) =~
               "installed"
    end

    # The centrepiece of P2-T3: an existing skill is never silently replaced.
    test "a hand-edited skill gets a diff and a refusal, not an overwrite", %{
      record: record,
      dir: dir
    } do
      capture_io(fn -> CLI.run(:install, id: record.id, dir: dir) end)

      path = Path.join([dir, record.name, "SKILL.md"])

      edited =
        String.replace(record.md, "## Iron Laws", "## Iron Laws\n\n- MY OWN HAND-EDITED LAW")

      File.write!(path, edited)

      err =
        capture_io(:stderr, fn ->
          capture_io(fn -> assert CLI.run(:install, id: record.id, dir: dir) == 1 end)
        end)

      assert err =~ "already installed"
      assert err =~ "--force"
      assert err =~ "faber refine"

      # The diff shows what WOULD be lost, which is the whole point of showing it.
      assert err =~ "- - MY OWN HAND-EDITED LAW"

      # And the edit is still on disk: refusing means refusing.
      assert File.read!(path) == edited
    end

    # The diff says WHAT changed; drift says WHOSE change it is. Only one of those is destructive.
    test "drift is called out when the user's own edits are at stake", %{record: record, dir: dir} do
      capture_io(fn -> CLI.run(:install, id: record.id, dir: dir) end)
      path = Path.join([dir, record.name, "SKILL.md"])
      refute Faber.Install.drift?(path), "a freshly-installed skill has not drifted"

      File.write!(path, record.md <> "\n- my own law\n")
      assert Faber.Install.drift?(path)

      err =
        capture_io(:stderr, fn ->
          capture_io(fn -> assert CLI.run(:install, id: record.id, dir: dir) == 1 end)
        end)

      assert err =~ "DRIFT"
      assert err =~ "hand-edited"
    end

    # Unknown must read as not-drifted: a warning that fires on skills it cannot verify teaches
    # people to --force past it, which is worse than not warning.
    test "a skill with no recorded hash is not accused of drifting", %{record: record, dir: dir} do
      capture_io(fn -> CLI.run(:install, id: record.id, dir: dir) end)
      path = Path.join([dir, record.name, "SKILL.md"])

      # Simulate a skill installed before skill_sha256 was tracked.
      marker = Path.join([dir, record.name, ".faber.json"])
      data = marker |> File.read!() |> Jason.decode!() |> Map.delete("skill_sha256")
      File.write!(marker, Jason.encode!(data))
      File.write!(path, "# totally different\n")

      refute Faber.Install.drift?(path)

      err =
        capture_io(:stderr, fn ->
          capture_io(fn -> assert CLI.run(:install, id: record.id, dir: dir) == 1 end)
        end)

      # Still refuses (it exists) and still diffs — it just doesn't claim to know who edited it.
      assert err =~ "already installed"
      refute err =~ "DRIFT"
    end

    test "--force replaces it", %{record: record, dir: dir} do
      capture_io(fn -> CLI.run(:install, id: record.id, dir: dir) end)
      path = Path.join([dir, record.name, "SKILL.md"])
      File.write!(path, "# clobber me\n")

      out =
        capture_io(fn -> assert CLI.run(:install, id: record.id, dir: dir, force: true) == 0 end)

      assert out =~ "installed →"
      assert File.read!(path) == record.md
    end

    test "re-installing the identical skill says so rather than printing a diff of nothing", %{
      record: record,
      dir: dir
    } do
      capture_io(fn -> CLI.run(:install, id: record.id, dir: dir) end)

      err =
        capture_io(:stderr, fn ->
          capture_io(fn -> assert CLI.run(:install, id: record.id, dir: dir) == 1 end)
        end)

      assert err =~ "byte-identical"
    end

    test "a long unchanged run collapses instead of reprinting the file", %{
      record: record,
      dir: dir
    } do
      capture_io(fn -> CLI.run(:install, id: record.id, dir: dir) end)

      path = Path.join([dir, record.name, "SKILL.md"])
      File.write!(path, record.md <> "\n\nA TRAILING HAND-EDIT\n")

      err =
        capture_io(:stderr, fn ->
          capture_io(fn -> CLI.run(:install, id: record.id, dir: dir) end)
        end)

      assert err =~ "unchanged lines"
      assert err =~ "A TRAILING HAND-EDIT"
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

      # test/fixtures spans fixtures/, nonelixir/, codex/ and the hazard fixture's own cwd — a count
      # of 1 would mean the project label collapsed, which is what made the scribe-run scope
      # surprise invisible.
      assert out =~ ~r/5 sessions across 4 projects/
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

    test "W1 — a refused --install exits NON-ZERO (it used to exit 0)" do
      # `propose_hazard/2` and `propose/2` both discarded the installer's return and answered a
      # constant `0`, so a vetoed skill, a hand-edited pointer or an unreadable settings.json all
      # reported success. `faber propose --install` in a script or CI therefore said "fine" while
      # having installed nothing — the exact false-green this project exists to detect, in the tool
      # that detects it. Flagged independently by elixir-reviewer AND codex.
      #
      # Driven through the REAL refusal (an existing skill on disk that --install must not clobber)
      # rather than a mocked error, so it fails if the plumbing regresses anywhere along the path.
      tmp = Path.join(System.tmp_dir!(), "faber-cli-w1-#{System.unique_integer([:positive])}")
      prev = Application.get_env(:faber, :skills_dir)
      Application.put_env(:faber, :skills_dir, tmp)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:faber, :skills_dir, prev),
          else: Application.delete_env(:faber, :skills_dir)

        File.rm_rf(tmp)
      end)

      # First install succeeds → exit 0. The clean half of the assertion: this must not become a
      # blanket non-zero.
      capture_io(fn -> assert CLI.run(:propose, @fixtures ++ [rank: 1, install: true]) == 0 end)

      # Second install hits the never-blind-overwrite guard and refuses. Nothing was installed, so
      # the exit code must say so.
      capture_io(fn ->
        assert CLI.run(:propose, @fixtures ++ [rank: 1, install: true]) == 1,
               "a refused --install still exited 0 — W1"
      end)
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

  describe "--json" do
    test "scan emits raw values and the full signal vector, not the table's rounded ones" do
      json = json_out(:scan, @fixtures ++ [limit: 5])

      assert json["count"] == 5
      assert length(json["sessions"]) == 5
      assert json["scope"]["kind"] == "all"
      assert is_integer(json["elapsed_ms"])

      session = hd(json["sessions"])
      assert is_map(session["friction"]["signals"])
      # The table rounds `raw` to one decimal and prints the sigmoid nowhere; both are here whole.
      assert is_float(session["friction"]["raw"])
      assert is_float(session["friction"]["score"])
      assert Map.has_key?(session["fingerprint"], "confidence")
      assert Map.has_key?(session["counts"], "turns")
    end

    # `--hazard KIND` has to be discoverable, and the table can't carry hazards: it is sorted by
    # friction, and a hazard is orthogonal to that (the fixture below scores 0.0 raw and still has
    # one). --json is therefore the only surface that lists them, which the help text points at.
    test "scan lists each session's hazards, as a sibling of friction rather than a signal" do
      json = json_out(:scan, @fixtures ++ [limit: 20])

      session = Enum.find(json["sessions"], &(&1["session_id"] == "hazard"))
      assert session, "the seeded hazard fixture did not survive the scan"

      assert [hazard] = session["hazards"]
      assert hazard["kind"] == "pipe_masks_exit"
      assert hazard["count"] == 1
      assert hazard["evidence"] =~ "mix verify | tail -5"
      # The pointer the hazard implies — what `propose --hazard` turns into a hook.
      assert hazard["suggested_event"] == "PreToolUse"
      assert hazard["matcher"] == "Bash"

      # Never folded into the score: this session struggled with nothing, and must not be ranked as
      # though it did. `hazards` is a sibling key, and no signal named it.
      assert session["friction"]["raw"] == 0.0
      refute Map.has_key?(session["friction"], "hazards")
      refute Enum.any?(Map.keys(session["friction"]["signals"]), &(&1 =~ "hazard"))

      # And a session without one says so with an empty list, not a missing key.
      assert Enum.all?(json["sessions"], &is_list(&1["hazards"]))
    end

    # `ctx` renders as "—" in the table for a session with no reading. A dash is not a number, and a
    # script must not have to parse one — it gets null.
    test "scan renders an unknown context as null rather than the table's dash" do
      json = json_out(:scan, @fixtures ++ [limit: 5])
      assert Enum.any?(json["sessions"], &is_nil(&1["max_ctx_pct"]))
      refute Enum.any?(json["sessions"], &(&1["max_ctx_pct"] == "—"))
    end

    test "an empty scan is a valid answer (count 0), not an error or a prose explanation" do
      json = json_out(:scan, base: "test/fixtures", min_messages: 99_999, json: true)

      assert json["count"] == 0
      assert json["sessions"] == []
      refute inspect(json) =~ "No sessions matched"
    end

    test "scan reports the scope it actually used" do
      json = json_out(:scan, @fixtures ++ [limit: 1])
      # `--base` was given, so the scan is global and says why.
      assert json["scope"] == %{"kind" => "all", "reason" => "explicit_base"}
    end

    test "parse accepts --json only on the read-only surfaces" do
      assert {:scan, [json: true]} = CLI.parse(["scan", "--json"])
      assert {:proposals, [json: true]} = CLI.parse(["proposals", "--json"])
      assert {:show, opts} = CLI.parse(["show", "abc", "--json"])
      assert opts[:json] == true
      assert {:feedback, [json: true]} = CLI.parse(["feedback", "--json"])

      # A command whose output is a paid artifact has no --json shape yet; it must say so rather
      # than silently ignoring the flag.
      assert {:parse_error, :propose, ["--json"]} = CLI.parse(["propose", "--json"])
    end
  end

  describe "--json over the proposal store" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp_dir} do
      Application.put_env(:faber, :proposal_store, true)
      Application.put_env(:faber, :proposals_dir, Path.join(tmp_dir, "proposals"))

      on_exit(fn ->
        Application.put_env(:faber, :proposal_store, false)
        Application.delete_env(:faber, :proposals_dir)
      end)

      :ok
    end

    test "proposals: an empty store is an empty list, not the how-to-get-one prose" do
      json = json_out(:proposals, json: true)

      assert json["count"] == 0
      assert json["proposals"] == []
    end

    test "proposals and show carry the eval breakdown and the skill body" do
      capture_io(fn -> CLI.run(:propose, @fixtures ++ [force: true]) end)
      [record] = Store.list()

      listed = json_out(:proposals, json: true)
      assert listed["count"] == 1
      assert [entry] = listed["proposals"]
      assert entry["id"] == record.id
      assert entry["installed"] == false
      assert is_float(entry["eval"]["composite"])
      assert map_size(entry["eval"]["dimensions"]) > 0

      # The list stays a summary; only `show` pays for the full body.
      refute Map.has_key?(entry, "md")

      shown = json_out(:show, id: record.id, json: true)
      assert shown["md"] == record.md
      assert shown["eval"]["dimensions"] == entry["eval"]["dimensions"]
    end
  end

  describe "--quiet" do
    test "silences status lines and keeps the result" do
      # propose narrates a "Proposing for …" pre-flight line to stderr, because one LLM call is a
      # minute of silence. `--quiet` is for the script that neither reads nor wants it.
      out =
        capture_io(:stderr, fn ->
          assert capture_io(fn ->
                   assert CLI.run(:propose, @fixtures ++ [rank: 1, quiet: true]) == 0
                 end) =~ "composite"
        end)

      assert out == ""
    end

    test "without it, the status line is still there" do
      out =
        capture_io(:stderr, fn ->
          capture_io(fn -> CLI.run(:propose, @fixtures ++ [rank: 1]) end)
        end)

      assert out =~ "Proposing for"
    end

    test "every subcommand accepts it, including ones that emit no status at all" do
      # A global flag that errors on half the commands is not global — a script should be able to
      # pass it uniformly without first learning which commands narrate.
      for argv <- [
            ["scan"],
            ["propose"],
            ["refine"],
            ["consolidate"],
            ["proposals"],
            ["feedback"],
            ["serve"],
            ["sync"]
          ] do
        assert {_cmd, opts} = CLI.parse(argv ++ ["--quiet"])
        assert opts[:quiet] == true, "#{hd(argv)} rejected --quiet"
      end

      assert {:show, opts} = CLI.parse(["show", "abc", "--quiet"])
      assert opts[:quiet] == true
    end
  end

  describe "--dry-run" do
    setup do
      # The whole promise of --dry-run is "no LLM calls", and the ordinary Stub cannot tell a run
      # that skipped the call from one that made it and got a canned answer back. This spy makes the
      # difference observable, so the test asserts the promise instead of the output.
      Process.register(self(), :faber_llm_spy)
      Application.put_env(:faber, :llm, Faber.CLITest.SpyLLM)

      on_exit(fn ->
        Application.put_env(:faber, :llm, Faber.LLM.Stub)
      end)

      :ok
    end

    test "propose --dry-run spends nothing" do
      out =
        capture_io(fn ->
          assert CLI.run(:propose, @fixtures ++ [rank: 1, dry_run: true]) == 0
        end)

      refute_received :llm_called

      assert out =~ "DRY RUN"
      assert out =~ "no LLM calls were spent"
      assert out =~ "LLM calls: 1 (the draft)"
      assert out =~ "Re-run without --dry-run"
    end

    # The control for the test above: without it, `refute_received` would pass just as happily
    # against a propose that never called an LLM for some unrelated reason.
    test "without --dry-run, the call is made" do
      capture_io(:stderr, fn ->
        capture_io(fn -> assert CLI.run(:propose, @fixtures ++ [rank: 1]) == 0 end)
      end)

      assert_received :llm_called
    end

    test "it reports the real decision — session, adapter, and the engine that would score" do
      out = capture_io(fn -> CLI.run(:propose, @fixtures ++ [rank: 1, dry_run: true]) end)

      assert out =~ "faber-elixir"

      # Named by asking Eval what it WOULD route to, not by retyping a guess here — if the routing
      # changes, this moves with it instead of asserting a stale literal.
      assert out =~ Faber.Eval.planned_engine(adapter: adapter!())

      # The backend named is the one CONFIGURED right now (this describe swaps in the spy), which is
      # the point: a dry run reporting a backend other than the one that would be called is a lie.
      assert out =~ "SpyLLM"
    end

    test "--trigger changes the quoted cost, and still spends nothing" do
      out =
        capture_io(fn ->
          assert CLI.run(:propose, @fixtures ++ [rank: 1, dry_run: true, trigger: true]) == 0
        end)

      refute_received :llm_called
      assert out =~ "one per fixture in it for --trigger"
    end

    test "consolidate --dry-run lists every session it would draft, and spends nothing" do
      # `--force` means nothing is stack-skipped, so there is no stderr notice to swallow here.
      out =
        capture_io(fn ->
          assert CLI.run(:consolidate, @fixtures ++ [top: 2, dry_run: true, force: true]) == 0
        end)

      refute_received :llm_called

      assert out =~ "sessions to draft (2)"
      assert out =~ "one draft each"
    end

    test "propose --top N reaches the same batch pipeline consolidate did" do
      out =
        capture_io(fn ->
          assert CLI.run(:propose, @fixtures ++ [top: 2, dry_run: true, force: true]) == 0
        end)

      refute_received :llm_called
      assert out =~ "sessions to draft (2)"
    end

    test "the deprecated alias forwards to it, and says so on stderr" do
      # stderr, so a script piping `faber consolidate` into something keeps getting only the
      # artifact. The pointer is for the human watching, not for the pipe.
      err =
        capture_io(:stderr, fn ->
          capture_io(fn ->
            assert CLI.run(:consolidate, @fixtures ++ [top: 2, dry_run: true, force: true]) == 0
          end)
        end)

      assert err =~ "deprecated"
      assert err =~ "faber propose --top"
    end

    test "bare `consolidate` IS `propose --top 5` — the default is pinned, not just present" do
      # Bare `consolidate` drafted several sessions and clustered them; forwarding it to a plain
      # one-session propose would quietly change what the command does.
      #
      # Asserting equality against an EXPLICIT `--top 5` rather than matching a literal "(5)":
      # the literal would also have to track the fixture count (min(top, available)), so it would
      # break when a fixture is added for unrelated reasons. Equality pins the only claim that
      # matters — the default IS 5 — and stays true whatever the corpus size. Verified by mutation:
      # `@default_top 3` leaves every other test in this file green and fails only this one.
      bare =
        capture_io(fn ->
          capture_io(:stderr, fn ->
            assert CLI.run(:consolidate, @fixtures ++ [dry_run: true, force: true]) == 0
          end)
        end)

      explicit =
        capture_io(fn ->
          assert CLI.run(:propose, @fixtures ++ [top: 5, dry_run: true, force: true]) == 0
        end)

      assert bare =~ "sessions to draft"
      assert bare == explicit
    end

    test "parse accepts --dry-run on the commands that spend" do
      assert {:propose, opts} = CLI.parse(["propose", "--dry-run"])
      assert opts[:dry_run] == true

      assert {:consolidate, c_opts} = CLI.parse(["consolidate", "--dry-run", "--top", "3"])
      assert c_opts[:dry_run] == true
    end
  end

  describe "--dry-run files nothing" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp_dir} do
      Application.put_env(:faber, :proposal_store, true)
      Application.put_env(:faber, :proposals_dir, Path.join(tmp_dir, "proposals"))

      on_exit(fn ->
        Application.put_env(:faber, :proposal_store, false)
        Application.delete_env(:faber, :proposals_dir)
      end)

      :ok
    end

    test "no artifact is written for a run that drafted nothing" do
      capture_io(fn -> assert CLI.run(:propose, @fixtures ++ [rank: 1, dry_run: true]) == 0 end)
      assert Store.list() == []
    end
  end

  defp adapter!, do: elem(Faber.Adapter.load(Faber.adapter_dir()), 1)

  defp json_out(command, opts) do
    fn -> assert CLI.run(command, Keyword.put(opts, :json, true)) == 0 end
    |> capture_io()
    |> Jason.decode!()
  end
end

defmodule Faber.CLITest.SpyLLM do
  @moduledoc false
  @behaviour Faber.LLM

  # Reports the call to the registered test process, then defers to the ordinary Stub so behavior
  # is unchanged — this observes, it does not simulate. Registered by name rather than captured as
  # a pid so it works even if the proposer ever moves the call off the caller's process.
  @impl Faber.LLM
  def generate_object(prompt, schema, opts) do
    send(:faber_llm_spy, :llm_called)
    Faber.LLM.Stub.generate_object(prompt, schema, opts)
  end
end
