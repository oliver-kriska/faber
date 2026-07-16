defmodule Mix.Tasks.Faber.ProposeTest do
  @moduledoc """
  `mix faber.propose` spends a real LLM call, and it aimed that call by ranking **every session on
  the machine** — so standing in one project and asking for "the worst session" drafted a skill for
  a different project, and charged you for it. That is the defect these pin.

  Scope *policy* (the walk to the git root, the slug, the `:unknown_cwd` fallback) is
  `Faber.ScanScopeTest`'s; this asserts only that the task resolves a scope and hands it to the
  scan. See `Mix.Tasks.Faber.ScanTest` for why the default cwd case is asserted as "a scope exists"
  rather than a specific `kind`.

  Nothing here reaches the LLM: every `run/1` case is steered into an error before `propose/2`.
  """
  use ExUnit.Case, async: false

  # `as: ProposeTask` because a bare `Propose` would read as `Faber.Propose` — the module this task
  # calls — and the whole point of this file is which of the two is under test.
  alias Faber.Scan.Scope
  alias Mix.Tasks.Faber.Propose, as: ProposeTask

  setup do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(shell) end)
    :ok
  end

  describe "scan_opts/1 — what `--rank N` indexes into" do
    test "a scope is ALWAYS resolved — rank 1 must mean this project's worst, not the machine's" do
      opts = ProposeTask.scan_opts([])

      assert %Scope{} = opts[:scope]
    end

    test "--all opts back into the machine-wide ranking" do
      opts = ProposeTask.scan_opts(all: true)

      assert %Scope{kind: :all, reason: :requested} = opts[:scope]
    end

    test "an explicit --base disables cwd scoping" do
      opts = ProposeTask.scan_opts(base: "/nonexistent")

      assert %Scope{kind: :all, reason: :explicit_base} = opts[:scope]
    end

    test "no default :limit — --rank indexes the true ranking, not an even sample" do
      # `:limit` samples a spread across the corpus (see Faber.Scan), which would silently change
      # WHICH session `--rank 2` names — and this task pays for that choice. Absent unless asked.
      opts = ProposeTask.scan_opts(all: true)

      refute Keyword.has_key?(opts, :limit)
      assert ProposeTask.scan_opts(limit: 5, all: true)[:limit] == 5
    end
  end

  describe "run/1 announces the corpus before spending anything" do
    test "the scope line precedes session selection" do
      # Ordering is the point, not the string: the user has to be told which corpus `--rank` indexed
      # BEFORE the call is made, not in a summary afterwards. Rendered by
      # `Faber.CLI.Render.scope_line/1` — the same function the binary uses — so the two surfaces
      # cannot drift into phrasing it differently. `--rank 999` stops the run at selection.
      #
      # This does NOT pin the scoping itself: `scope_line(nil)` degrades to "all projects" on
      # purpose, so this assertion reads the same whether the scope resolved to `:all` or was never
      # resolved at all. `scan_opts/1` above is what fails if scoping is removed (verified by
      # mutation — dropping the `:scope` key kills those three and leaves this one green).
      ProposeTask.run(["--base", "test/fixtures", "--rank", "999"])

      assert_received {:mix_shell, :info, ["all projects"]}
      assert_received {:mix_shell, :error, [msg]}
      assert msg =~ "no_session_at_rank"
    end
  end

  describe "the dev extras survive (they are why this task is not a thin CLI wrapper)" do
    test "--adapter still selects a pack" do
      # GUIDE §6 documents `mix faber.propose --adapter adapters/faber-python`, and that flag is how
      # the second adapter is exercised — i.e. how Faber shows its engine is domain-free. `faber
      # propose` has no such flag, which is exactly why delegating this task to Faber.CLI would have
      # deleted the capability. Asserted through argv, not by reading @switches.
      ProposeTask.run([
        "--adapter",
        "adapters/faber-python",
        "--base",
        "test/fixtures",
        "--rank",
        "999"
      ])

      # The pack loaded: `run/1` loads the adapter BEFORE picking a session, so reaching
      # `:no_session_at_rank` proves `adapters/faber-python` parsed and validated. A rejected
      # `--adapter` fails earlier, with a different error and no scope line at all (next test).
      assert_received {:mix_shell, :info, ["all projects"]}
      assert_received {:mix_shell, :error, [msg]}
      assert msg =~ "no_session_at_rank"
    end

    test "an unknown --adapter fails on the adapter, proving the flag is read rather than ignored" do
      ProposeTask.run(["--adapter", "adapters/does-not-exist", "--rank", "999"])

      assert_received {:mix_shell, :error, [msg]}
      assert msg =~ "faber.propose failed"
      refute msg =~ "no_session_at_rank"

      # Never got as far as scanning — which is what makes the previous test's pass meaningful.
      refute_received {:mix_shell, :info, ["all projects"]}
    end
  end
end
