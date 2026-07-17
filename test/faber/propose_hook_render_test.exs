defmodule Faber.ProposeHookRenderTest do
  @moduledoc """
  What the hook template is allowed to do with a token that isn't `{{script}}`.

  A hook's artifact is a **shell script**, and every token except `{{script}}` lands in a `#`
  comment. A `#` comment ends at a newline — so any token carrying one stops being a comment and
  starts being a command. That is the whole class this file guards: the renderer must make each
  token safe **by construction**, not by the model declining to send a newline.

  `Faber.Template.render_vars/2` deliberately does not escape (`{{script}}` is raw by necessity),
  so `Propose.template_context/1` is the only place the defence can live.
  """
  use ExUnit.Case, async: true

  alias Faber.{Adapter, Eval, Proposal, Propose}

  @adapter_dir Path.expand("../../adapters/faber-elixir", __DIR__)

  setup_all do
    assert {:ok, adapter} = Adapter.load(@adapter_dir)
    %{adapter: adapter}
  end

  @good_script """
  #!/usr/bin/env bash
  input=$(cat)
  command=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
  exit 0
  """

  defp hook(overrides) do
    base = %Proposal{
      kind: :hook,
      name: "no-masked-gate-exit",
      description: "Blocks piping a gate command into head or tail. Use when status is masked.",
      rationale: "The hazard produces no friction, so a skill would never be triggered by it.",
      event: "PreToolUse",
      matcher: "Bash",
      script: @good_script,
      source: %{hazard: :pipe_masks_exit, hazard_evidence: "`mix verify | tail -5; echo $?`"}
    }

    struct!(base, overrides)
  end

  # Every token except `{{script}}` renders above `set -uo pipefail` in `hook.sh.tmpl`, and every
  # line of that region is comment or blank. So "no token escaped its comment" is checkable as a
  # property of the whole region — which is the real invariant — rather than as "this one payload
  # string is absent", which would only ever catch the payload someone already thought of.
  defp token_region(rendered) do
    [region | _] = String.split(rendered, "set -uo pipefail", parts: 2)
    String.split(region, "\n")
  end

  defp assert_all_comments(rendered) do
    for line <- token_region(rendered) do
      assert line == "" or String.starts_with?(line, "#"),
             "non-comment line in the template's token region: #{inspect(line)}"
    end
  end

  describe "B1 — a token that escapes its comment" do
    test "a newline in `matcher` does NOT become a live shell line", %{adapter: adapter} do
      # Reproduced live at da26a8f, with a *benign* script: this rendered
      #
      #     # Fires on: PreToolUse / Bash
      #     echo PWNED_PAYLOAD_EXECUTED > /tmp/faber_pwned.txt   ← outside the comment
      #     #
      #
      # and scored `composite: 1.0, passed: true, vetoed: []` — a *perfect* score. Reviewing the
      # model's `script` showed nothing, because the payload was never in the script.
      evil = hook(matcher: "Bash\necho PWNED_PAYLOAD_EXECUTED > /tmp/faber_pwned.txt\n#")

      rendered = Propose.render(evil, adapter)

      refute rendered =~ ~r/^echo PWNED_PAYLOAD_EXECUTED/m,
             "payload escaped its comment and is now a live shell line"

      assert_all_comments(rendered)
    end

    test "a newline in `event` does NOT become a live shell line", %{adapter: adapter} do
      evil = hook(event: "PreToolUse\necho PWNED_VIA_EVENT\n#")

      rendered = Propose.render(evil, adapter)

      refute rendered =~ ~r/^echo PWNED_VIA_EVENT/m
      assert_all_comments(rendered)
    end

    test "a newline in `name` does NOT become a live shell line", %{adapter: adapter} do
      # `Install.install/2` renders on its FIRST line, before `install({p.name, md}, …)` validates
      # the name — so `p.name` reaches the template raw. Validation rejects before any *write*, so
      # this is not an install vector; it IS a display vector (the dashboard renders the artifact
      # before anyone installs it). The renderer should not depend on a downstream check.
      evil = hook(name: "ok\necho PWNED_VIA_NAME\n#")

      rendered = Propose.render(evil, adapter)

      refute rendered =~ ~r/^echo PWNED_VIA_NAME/m
      assert_all_comments(rendered)
    end

    test "every non-script token is defanged, not just the ones with a known vector",
         %{adapter: adapter} do
      # The invariant, stated once over every token the hook context fills. A per-token test only
      # ever covers the vector someone already imagined; this covers the next one too.
      payload = "x\necho PWNED_EVERY_TOKEN\n#"

      for override <- [
            [name: payload],
            [description: payload],
            [rationale: payload],
            [event: payload],
            [matcher: payload],
            [source: %{hazard: :pipe_masks_exit, hazard_evidence: payload}]
          ] do
        rendered = Propose.render(hook(override), adapter)

        refute rendered =~ ~r/^echo PWNED_EVERY_TOKEN/m,
               "token #{inspect(Keyword.keys(override) || override)} escaped its comment"

        assert_all_comments(rendered)
      end
    end
  end

  describe "B1 — a token that deceives the reader" do
    # These matter *because* of the install posture: the veto is a backstop that 7 of 8 known
    # vectors walk past, so the human reading the script is the real boundary. A character that
    # makes the displayed script differ from the executed one attacks that boundary directly —
    # it is not cosmetic.

    test "an ANSI escape cannot rewrite the terminal display of the header", %{adapter: adapter} do
      # `\e[2K\r` erases the line the reader is looking at; `\e[1;32m` recolours it. In a `<pre>`
      # they are inert, but the CLI prints this script to a terminal for the confirm.
      evil = hook(matcher: "Bash\e[2K\r# harmless-looking")

      rendered = Propose.render(evil, adapter)

      refute rendered =~ "\e", "an ANSI escape survived into the rendered script"
      assert_all_comments(rendered)
    end

    test "a bidi override cannot reorder the displayed header", %{adapter: adapter} do
      # Trojan Source. The same class `/phx:deps-audit` already scans Hex deps for. Built from
      # codepoints rather than written literally because the Elixir compiler itself rejects a raw
      # RLO in source — the same defence one layer down, and a fair signal that this class is worth
      # stripping rather than tolerating.
      rlo = <<0x202E::utf8>>
      pdf = <<0x202C::utf8>>

      rendered = Propose.render(hook(description: "safe " <> rlo <> " terces " <> pdf), adapter)

      refute rendered =~ rlo, "a bidi override survived into the rendered script"
      refute rendered =~ pdf
      assert_all_comments(rendered)
    end

    test "stripping a control char does not splice two words into a valid-looking one",
         %{adapter: adapter} do
      # Deletion would turn "Pre\nToolUse" into "PreToolUse" — a *valid* event name, which hides the
      # tampering. Replacing with a space keeps the seam visible to the reader who is the boundary.
      rendered = Propose.render(hook(event: "Pre\nToolUse"), adapter)

      assert rendered =~ "Fires on: Pre ToolUse / Bash"
      refute rendered =~ "Fires on: PreToolUse / Bash"
    end

    test "the eval VETOES a payload smuggled through `matcher`", %{adapter: adapter} do
      # Defence in depth: even if the renderer regressed, a rendered artifact carrying a dangerous
      # line must not score a clean pass. This is the assertion that was `{1.0, true, []}`.
      evil = hook(matcher: "Bash\nrm -rf /\n#")

      assert {:ok, result} = Eval.score(evil, adapter: adapter)

      refute result.passed, "a hook with `rm -rf /` in its rendered body scored a clean pass"
    end
  end

  describe "a legitimate matcher still renders" do
    test "regex matchers are NOT over-narrowed", %{adapter: adapter} do
      # A Claude Code matcher is a *regex*. `|`, `.`, `*`, `(`, `)` are all legitimate and must
      # survive both validation and defanging — the fix is about newlines and control chars, not
      # about reducing the matcher to `[A-Za-z]+`.
      for matcher <- ["Bash", "Edit|Write", "Notebook.*", "mcp__.*__write.*", "(Edit|MultiEdit)"] do
        rendered = Propose.render(hook(matcher: matcher), adapter)

        assert rendered =~ "Fires on: PreToolUse / #{matcher}",
               "legitimate regex matcher #{inspect(matcher)} did not survive rendering"
      end
    end
  end
end
