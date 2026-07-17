defmodule Faber.HazardToHookTest do
  @moduledoc """
  **The whole hook spine, end to end** (plan PF-T3): a real fixture session carrying a seeded
  `pipe_masks_exit` hazard → a hook proposal → the hook eval gate → an installed script with a
  pointer in a throwaway `settings.json`.

  Hermetic: the LLM is `Faber.LLM.Stub`, and both write targets are redirected into `tmp_dir`.

  Every other test in this suite exercises one link. This one exists because the links were built
  in five separate commits against five separate assumptions, and the failure this catches is the
  one no unit test can: a stage whose output the next stage doesn't actually accept.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Faber.CLI

  @fixtures [base: "test/fixtures", min_messages: 0]

  setup %{tmp_dir: tmp_dir} do
    prev = {
      Application.get_env(:faber, :hooks_dir),
      Application.get_env(:faber, :settings_path),
      Application.get_env(:faber, :proposals_dir)
    }

    Application.put_env(:faber, :hooks_dir, Path.join(tmp_dir, "faber-hooks"))
    Application.put_env(:faber, :settings_path, Path.join(tmp_dir, "settings.json"))
    Application.put_env(:faber, :proposals_dir, Path.join(tmp_dir, "proposals"))

    on_exit(fn ->
      {hooks, settings, proposals} = prev
      restore(:hooks_dir, hooks)
      restore(:settings_path, settings)
      restore(:proposals_dir, proposals)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:faber, key)
  defp restore(key, value), do: Application.put_env(:faber, key, value)

  @tag :tmp_dir
  test "a frictionless hazard becomes an installed, executable hook", ctx do
    out =
      capture_io(fn ->
        assert CLI.run(:propose, [hazard: "pipe_masks_exit", install: true] ++ @fixtures) == 0
      end)

    # 1. It found the session by hazard class — and the session it found scores ZERO friction, which
    #    is the entire premise: no ranking would ever have surfaced it.
    assert out =~ "pipe_masks_exit"

    # 2. The eval gated it and it passed. A hook is scored by the hook set (executable/pointer/
    #    safety), never the skill set, which would fail it on shell.
    assert out =~ ~r/PASS/i

    # 3. The script landed, executable, with the shebang the TEMPLATE owns (not the model's).
    script = Path.join([ctx.tmp_dir, "faber-hooks", "no-masked-gate-exit", "hook.sh"])
    assert File.exists?(script), "expected an installed hook script at #{script}\n\n#{out}"

    body = File.read!(script)
    assert String.starts_with?(body, "#!/usr/bin/env bash\n")
    # Exactly one shebang: `#!` is only a shebang on line 1, and two means the file says one thing
    # and runs another.
    assert body |> String.split("\n") |> Enum.count(&String.starts_with?(&1, "#!")) == 1
    assert body =~ "tool_input.command"

    assert {:ok, %File.Stat{mode: mode}} = File.stat(script)
    assert Bitwise.band(mode, 0o100) == 0o100, "hook script is not executable"

    # 4. The pointer — the part Claude Code actually reads — names the script that exists.
    settings = ctx.tmp_dir |> Path.join("settings.json") |> File.read!() |> Jason.decode!()

    assert [%{"matcher" => "Bash", "hooks" => [%{"type" => "command", "command" => ^script}]}] =
             settings["hooks"]["PreToolUse"]

    # 5. Provenance: a hook in a shared dir is never confused for something the user wrote.
    assert File.exists?(Path.join(Path.dirname(script), ".faber.json"))
  end

  # `:jq` — this one EXECUTES the generated script, and the script parses its stdin with `jq` the
  # way a real Claude Code hook does. Same class as `:sidecar` (python3) and `:ccrider` (sqlite3):
  # installable tooling, so it belongs in `mix test.full`, not in the hermetic default run.
  @tag :jq
  @tag :tmp_dir
  test "the hook the pipeline produces actually fires on the hazard, and only on it", ctx do
    # Everything above scores a hook's SHAPE. Nothing proves the script DOES its job, so run it —
    # this is the one assertion that would survive a rewrite of every layer beneath it.
    capture_io(fn ->
      assert CLI.run(:propose, [hazard: "pipe_masks_exit", install: true] ++ @fixtures) == 0
    end)

    script = Path.join([ctx.tmp_dir, "faber-hooks", "no-masked-gate-exit", "hook.sh"])

    # The exact command the fixture session ran → blocked. Exit 2 is Claude Code's "block this
    # call and show the agent my stderr"; any other status would let the hazard through.
    assert {out, 2} = run_hook(ctx, script, "mix verify | tail -5; echo $?")
    assert out =~ "exit code you read is the filter's"

    # The safe forms of the very same command → untouched. A hook fires on EVERY matching tool
    # call, so a false positive here blocks legitimate work on every `mix verify` the user runs.
    assert {_, 0} = run_hook(ctx, script, "mix verify > /tmp/verify.log 2>&1; echo $?")
    assert {_, 0} = run_hook(ctx, script, "set -o pipefail; mix verify | tail -5")
    assert {_, 0} = run_hook(ctx, script, "git log --oneline | head -20")
  end

  # Feed a tool call to the hook the way Claude Code does: the JSON on stdin. Via a file because
  # `System.cmd/3` has no stdin option — the script still reads it with `cat`, unaware.
  defp run_hook(ctx, script, command) do
    payload = Path.join(ctx.tmp_dir, "payload.json")
    File.write!(payload, Jason.encode!(%{tool_name: "Bash", tool_input: %{command: command}}))
    System.cmd("bash", ["-c", "#{script} < #{payload}"], stderr_to_stdout: true)
  end
end
