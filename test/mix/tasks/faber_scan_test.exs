defmodule Mix.Tasks.Faber.ScanTest do
  @moduledoc """
  The first tests for `lib/mix/tasks` — there were none, which is how `mix faber.scan` came to
  scan every project on the machine long after `faber scan` had been scoped to one.

  **What is tested here, and what deliberately is not.** The scope *policy* (walk to the git root,
  the slug, the `:unknown_cwd` fallback) belongs to `Faber.Scan.Scope` and is tested against an
  injected format in `Faber.ScanScopeTest`. This task's only job is to **resolve a scope and pass
  it on** — the bug was that it never did — so that is what these assert.

  The default cwd case can't be pinned harder than "a scope exists": `Scope.resolve/1` reads the
  real `~/.claude` unless `--base`/`--all` short-circuit it first, and the answer differs between
  this machine (`:project`) and CI (`:unknown_cwd` → `:all`). Asserting a `kind` would be asserting
  the developer's filesystem. `--all` and `--base` never touch disk, so those are pinned exactly.
  """
  use ExUnit.Case, async: false

  # `as: ScanTask` because a bare `Scan` would read as `Faber.Scan` — the module this task calls —
  # and the whole point of this file is which of the two is under test.
  alias Faber.Scan.Scope
  alias Mix.Tasks.Faber.Scan, as: ScanTask

  setup do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(shell) end)
    :ok
  end

  describe "scan_opts/1 — the scope decision" do
    test "a scope is ALWAYS resolved — its absence is the whole bug" do
      # Not a tautology: this task took `Keyword.take([:limit, :min_messages, :base, :dedupe])` and
      # handed that straight to `Scan.run/1`. No `:scope` key means Scan ranks the entire corpus,
      # which is exactly what the user reported. If this key ever disappears again, so does scoping.
      opts = ScanTask.scan_opts([])

      assert %Scope{} = opts[:scope]
    end

    test "--all is global, and says it was asked for" do
      opts = ScanTask.scan_opts(all: true)

      assert %Scope{kind: :all, reason: :requested} = opts[:scope]
    end

    test "an explicit --base disables cwd scoping" do
      # Same rule as the binary: naming a transcript root explicitly means you meant that root.
      opts = ScanTask.scan_opts(base: "/nonexistent")

      assert %Scope{kind: :all, reason: :explicit_base} = opts[:scope]
    end

    test "the scan options themselves still pass through" do
      opts = ScanTask.scan_opts(limit: 5, min_messages: 0, dedupe: false, all: true)

      assert opts[:limit] == 5
      assert opts[:min_messages] == 0
      assert opts[:dedupe] == false
    end
  end

  describe "run/1" do
    test "announces the scope before the table" do
      # The line is the point: a scan that changed which sessions it ranks has to say so, and this
      # task printed nothing at all. Rendered by `Faber.CLI.Render.scope_line/1`, the same function
      # the binary uses, so the two surfaces cannot drift into phrasing it differently.
      ScanTask.run(["--base", "test/fixtures", "--min-messages", "0"])

      assert_received {:mix_shell, :info, [scope_line]}
      assert scope_line == "all projects"

      assert_received {:mix_shell, :info, [summary]}
      assert summary =~ "non-trivial sessions"
    end

    test "--all parses and reaches the scope" do
      # `--all` is new on this task; if it were missing from @switches, OptionParser would drop it
      # silently and the scan would look scoped-by-default rather than global.
      ScanTask.run(["--all", "--base", "test/fixtures", "--min-messages", "0"])

      assert_received {:mix_shell, :info, ["all projects"]}
    end
  end
end
