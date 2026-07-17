defmodule Faber.HazardToHookTest.BlindHook do
  @moduledoc """
  An LLM that drafts a hook which never reads stdin — so it can never see the command it is
  supposed to judge. It is syntactically fine bash and carries nothing dangerous, so the veto is
  happy with it; the only thing that knows it is broken is the eval.

  That is the point of W2's subject: this hook does not fail on *taste*. It fails on a necessary
  condition, and it would fail it while running on every Bash call — exiting 0 blind, i.e. a
  PreToolUse gate that approves everything, silently, forever.
  """
  @behaviour Faber.LLM

  @impl Faber.LLM
  def generate_object(_prompt, _schema, _opts) do
    {:ok,
     %{
       "name" => "blind-gate",
       "description" => "A gate that never looks at its input.",
       "event" => "PreToolUse",
       "matcher" => "Bash",
       "rationale" => "Masked gate exits are invisible in the transcript.",
       "script" => "exit 0\n"
     }}
  end
end

defmodule Faber.HazardToHookTest do
  @moduledoc """
  **The whole hook spine, end to end** (plan PF-T3): a real fixture session carrying a seeded
  `pipe_masks_exit` hazard → a hook proposal → the hook eval gate → an installed script with a
  pointer in a throwaway `settings.json`.

  Hermetic: the LLM is `Faber.LLM.Stub`, and both write targets are redirected into `tmp_dir`.

  Every other test in this suite exercises one link. This one exists because the links were built
  in five separate commits against five separate assumptions, and the failure this catches is the
  one no unit test can: a stage whose output the next stage doesn't actually accept.

  ## What this does NOT prove (PE-T1)

  The script it executes is **hand-authored in `Faber.LLM.Stub`**, not model output. So this proves
  the pipeline does not *mangle* a correct script; it does not prove the pipeline *produces* one.
  Read the `:jq` assertion below with that in mind — "the hook actually blocks a masked gate" is a
  fact about the fixture's bash, not about the proposer.

  That gap is not hypothetical, and it is worth naming precisely because this test looks so
  end-to-end: **B1 hid here**. The stub's `matcher` is the benign `"Bash"`, so no run of this test
  could ever have exercised a payload smuggled through it — and a `matcher` of
  `"Bash\\necho PWNED\\n#"` rendered a live shell line while scoring composite 1.0, vetoed: [].
  A benign stub cannot fail on an input it never sends. The vectors live in
  `Faber.ProposeHookRenderTest` and `Faber.EvalHookTest`, which send them deliberately.
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
        # `yes: true` because this test IS a script: installing a hook now needs a person to confirm
        # the bytes, and a non-tty without `--yes` refuses rather than prompting into the void. That
        # refusal is the feature (see the two tests below); this line is the escape hatch being used
        # exactly as intended, and it is also a fair illustration of how easy the hatch is to reach.
        assert CLI.run(
                 :propose,
                 [hazard: "pipe_masks_exit", install: true, yes: true] ++ @fixtures
               ) ==
                 0
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
      assert CLI.run(:propose, [hazard: "pipe_masks_exit", install: true, yes: true] ++ @fixtures) ==
               0
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

  @tag :tmp_dir
  test "a hook that fails its eval is NOT installed, even with --yes and --force", ctx do
    # W2. The per-kind decision, at the CLI. `--yes` and `--force` are both present deliberately:
    # neither is an override for this. `--yes` says "I have read the script and I accept it" — a
    # human's read is not evidence that the hook can see its stdin, and this script provably can't.
    # `--force` means "replace what is installed", and letting it also mean "install something
    # broken" is how one flag becomes the escape hatch for every gate in the path.
    prev = Application.get_env(:faber, :llm)
    Application.put_env(:faber, :llm, Faber.HazardToHookTest.BlindHook)
    on_exit(fn -> Application.put_env(:faber, :llm, prev) end)

    {status, out} =
      with_io(:stderr, fn ->
        CLI.run(
          :propose,
          [hazard: "pipe_masks_exit", install: true, yes: true, force: true] ++ @fixtures
        )
      end)

    assert status == 1, "a hook that failed its eval reported success"
    assert out =~ "did not pass the hook eval"
    assert out =~ "necessary conditions"
    assert out =~ "--force does not override this"

    refute File.exists?(Path.join([ctx.tmp_dir, "faber-hooks", "blind-gate", "hook.sh"])),
           "a hook that cannot see its own stdin was written to disk and chmod 0755"

    refute File.exists?(Path.join(ctx.tmp_dir, "settings.json")),
           "a hook that failed its eval was pointed at from settings.json"
  end

  @tag :tmp_dir
  test "without --yes and without a terminal, --install REFUSES rather than installing blind",
       ctx do
    # The decided posture, at the CLI: a hook auto-runs on every matching tool call, so nothing
    # installs one with nobody having read it. A pipe or CI has no one to prompt, so the honest
    # answer is to refuse and say how to mean it — not to prompt into a void (hanging the pipeline)
    # and not to install anyway (the unattended write the posture exists to prevent).
    #
    # The test suite is itself a non-tty, which is what makes this reachable here at all.
    {out, err} =
      with_io(:stderr, fn ->
        capture_io(fn ->
          assert CLI.run(:propose, [hazard: "pipe_masks_exit", install: true] ++ @fixtures) == 1
        end)
      end)

    # The script is still drafted, scored and PRINTED — refusing to install is not refusing to work.
    assert out =~ "#!/usr/bin/env bash"
    assert out =~ ~r/PASS/i

    assert err =~ "was NOT installed"
    assert err =~ "--yes"

    refute File.exists?(
             Path.join([ctx.tmp_dir, "faber-hooks", "no-masked-gate-exit", "hook.sh"])
           ),
           "a hook was installed with nobody having confirmed it"

    refute File.exists?(Path.join(ctx.tmp_dir, "settings.json")),
           "a settings.json pointer was written with nobody having confirmed it"
  end

  @tag :tmp_dir
  test "the script is on screen BEFORE the confirm asks", ctx do
    # The posture is "show the bytes, then confirm", not "confirm, then show". Ordering is the whole
    # claim: a confirm for a script you have not seen is a rubber stamp.
    out =
      capture_io(fn ->
        CLI.run(:propose, [hazard: "pipe_masks_exit", install: true, yes: true] ++ @fixtures)
      end)

    script_at = :binary.match(out, "#!/usr/bin/env bash") |> elem(0)
    installed_at = :binary.match(out, "installed →") |> elem(0)

    assert script_at < installed_at, "the script must be printed before anything is written"
    assert File.exists?(Path.join([ctx.tmp_dir, "faber-hooks", "no-masked-gate-exit", "hook.sh"]))
  end
end
