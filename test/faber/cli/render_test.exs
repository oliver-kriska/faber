defmodule Faber.CLI.RenderTest do
  @moduledoc """
  The guarantee under test is **non-TTY degradation**, which is the whole reason the CLI took Owl
  for styling and nothing else.

  **Both modes are pinned explicitly, and that is the point.** An earlier version of this file
  asserted `refute IO.ANSI.enabled?()` as a *precondition*, on the stated theory that "ExUnit
  captures stdout, so the suite always runs with ANSI off". That theory is wrong. `capture_io` is
  irrelevant here: Elixir sets `:elixir, :ansi_enabled` **once at VM boot** from
  `prim_tty:isatty(stdout)`, so the value follows how `mix test` was *launched* — false when piped
  or redirected to a log, true from a terminal. The suite therefore passed for anyone whose runner
  redirects output and failed the moment it was run from a real terminal, on three tests that were
  measuring the harness rather than the badge.

  So `setup` forces the flag off rather than assuming it, and the colored branch forces it on. The
  flag is read at call time, so both directions are reachable with no terminal involved. That makes
  the doctest deterministic too — `badge("PASS", :ok) === "PASS"` only holds with ANSI off, and
  without the pin it is a coin-flip on the launcher.

  Process-global state, hence `async: false` — ExUnit runs sync modules serially, so no concurrent
  test can observe the enabled window and render an unexpectedly-colored line.
  """
  use ExUnit.Case, async: false

  alias Faber.CLI.Render

  doctest Faber.CLI.Render

  setup do
    # `fetch_env` rather than `get_env(…, false)`: restoring an unset key by writing `false` would
    # leave the VM in a state boot never produces, and this key is read by ExUnit's own formatter.
    prev = Application.fetch_env(:elixir, :ansi_enabled)
    Application.put_env(:elixir, :ansi_enabled, false)

    on_exit(fn ->
      case prev do
        {:ok, v} -> Application.put_env(:elixir, :ansi_enabled, v)
        :error -> Application.delete_env(:elixir, :ansi_enabled)
      end
    end)

    :ok
  end

  describe "badge/2" do
    test "carries no escape bytes when output is not a terminal" do
      # Established by `setup`, not inherited from the launcher — see the moduledoc.
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
      # This is the terminal case: what you get running `faber feedback` by hand. `setup` pinned the
      # flag off and restores whatever it found, so this only has to turn it on.
      Application.put_env(:elixir, :ansi_enabled, true)

      # Distinct colors per severity, so a palette that collapsed to one entry would fail here.
      assert Render.badge("PASS", :ok) ==
               IO.ANSI.green() <> "PASS" <> IO.ANSI.default_color() <> IO.ANSI.reset()

      assert Render.badge("REFUSED", :bad) =~ IO.ANSI.red()
      assert Render.badge("DRIFT", :warn) =~ IO.ANSI.yellow()
      assert Render.badge("kept", :neutral) =~ IO.ANSI.cyan()
    end

    test "an unknown severity is a crash, not a silently-unstyled word" do
      # The palette is the vocabulary. A typo'd severity that rendered plain would look correct
      # piped and be wrong only on a terminal — the exact split that made three tests in this file
      # pass under a redirect and fail from a real shell, so it is not hypothetical.
      assert_raise FunctionClauseError, fn -> Render.badge("PASS", :nope) end
    end
  end
end
