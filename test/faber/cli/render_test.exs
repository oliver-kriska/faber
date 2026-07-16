defmodule Faber.CLI.RenderTest do
  @moduledoc """
  The guarantee under test is **non-TTY degradation**, which is the whole reason the CLI took Owl
  for styling and nothing else. ExUnit captures stdout, so the suite always runs with
  `IO.ANSI.enabled?` false — meaning these assertions run in exactly the mode CI and `faber ... |
  head` run in, and a regression that leaks escape bytes into a pipe fails here.

  The colored branch is reachable too, without a terminal: `IO.ANSI.enabled?` reads `:elixir,
  :ansi_enabled` at call time, so flipping it proves the tag really does emit color rather than
  being plain for some unrelated reason (a broken palette lookup would pass every assertion above).
  That flip is process-global, hence `async: false` — ExUnit runs sync modules serially, so no
  concurrent test can observe the enabled window and render an unexpectedly-colored line.
  """
  use ExUnit.Case, async: false

  alias Faber.CLI.Render

  doctest Faber.CLI.Render

  describe "badge/2" do
    test "carries no escape bytes when output is not a terminal" do
      refute IO.ANSI.enabled?()

      for severity <- [:ok, :bad, :warn, :neutral] do
        badge = Render.badge("PASS", severity)

        assert badge == "PASS"
        refute badge =~ "\e["
      end
    end

    test "the word survives verbatim — a badge styles, it never rewrites" do
      # Every verdict word the CLI renders through it. If one of these came back altered, aligned
      # columns and `assert out =~ "MERGED"` elsewhere would both quietly rot.
      for word <- ~w(PASS REFUSED MERGED DRIFT kept kept-originals error active unused) do
        assert Render.badge(word, :neutral) == word
      end
    end

    test "the same call DOES color when ANSI is on — the plain rendering is degradation, not a no-op" do
      enabled = Application.get_env(:elixir, :ansi_enabled, false)
      Application.put_env(:elixir, :ansi_enabled, true)
      on_exit(fn -> Application.put_env(:elixir, :ansi_enabled, enabled) end)

      # Distinct colors per severity, so a palette that collapsed to one entry would fail here.
      assert Render.badge("PASS", :ok) ==
               IO.ANSI.green() <> "PASS" <> IO.ANSI.default_color() <> IO.ANSI.reset()

      assert Render.badge("REFUSED", :bad) =~ IO.ANSI.red()
      assert Render.badge("DRIFT", :warn) =~ IO.ANSI.yellow()
      assert Render.badge("kept", :neutral) =~ IO.ANSI.cyan()
    end

    test "an unknown severity is a crash, not a silently-unstyled word" do
      # The palette is the vocabulary. A typo'd severity that rendered plain would look correct
      # piped — i.e. in every test — and be wrong only on the terminal nobody tests on.
      assert_raise FunctionClauseError, fn -> Render.badge("PASS", :nope) end
    end
  end
end
