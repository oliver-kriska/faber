defmodule Faber.CLI.Render do
  @moduledoc """
  One rendering voice for the CLI: the verdict vocabulary and how it is colored.

  ## Why a badge is a `String.t()`, not iodata

  `Owl.Data.tag/2` answers an `%Owl.Tag{}`, which implements no `String.Chars` — interpolating one
  into a heredoc raises `Protocol.UndefinedError`, and `Enum.join/2` on a list of them raises for
  the same reason. Since every renderer in `Faber.CLI` is a heredoc, `badge/2` resolves the tag to
  a plain string up front with `Owl.Data.to_chardata/1`. Interpolation-safe everywhere, and the
  Owl-iodata footgun never reaches a call site.

  ## Degradation is Owl's, not ours

  `to_chardata/1` consults `IO.ANSI.enabled?`, which Elixir sets at boot from
  `prim_tty:isatty(stdout)`. So a badge carries escape bytes on a terminal and is bare text the
  moment output is piped or redirected — CI logs and `| head` stay clean with no TTY check of our
  own. This is why the CLI took Owl for *styling* only: anything built on `Owl.LiveScreen`
  (progress bars, spinners) does NOT degrade this way. `LiveScreen.init/1` returns `:ignore` when
  it can't read a terminal width, so the process never starts, and `await_render/1` — a `cast` to
  a dead name followed by a bare `receive` — then blocks **forever**. A hung CI job, not a failed
  one. Plain `X of Y` lines are used instead; see the plan's P4-T2 notes.
  """

  alias Faber.Scan.Scope

  @typedoc """
  What a word *means*, not what color it is. Call sites name the meaning; the palette lives here,
  so re-theming is one map rather than a grep across every `render_*`.
  """
  @type severity :: :ok | :bad | :warn | :neutral

  @palette %{ok: :green, bad: :red, warn: :yellow, neutral: :cyan}

  @typedoc "A number the caller may not have. Rendering the absence is this module's job, not theirs."
  @type maybe_number :: number() | nil

  # ── numbers ──────────────────────────────────────────────────────────────────────────────────
  #
  # Named for what the number MEANS, not how many decimals it gets — `score(x)` rather than
  # `fmt4(x)`. Precision is a rendering decision, and putting it in the name is how the CLI ended
  # up printing a composite at one decimal in `render_proposal` and four everywhere else.

  @none "—"

  @doc """
  The marker for a value that does not exist — distinct from zero, which is a measurement.

      iex> Faber.CLI.Render.none()
      "—"
  """
  @spec none() :: String.t()
  def none, do: @none

  @doc """
  A raw friction score: unbounded, one decimal.

  Named `raw_score` rather than `raw` so it does not read as `Phoenix.HTML.raw/1` — this repo
  serves a dashboard, and a bare `raw/1` on a call site trips both human and linter pattern-matching
  for an XSS footgun that is not here.

      iex> Faber.CLI.Render.raw_score(6.785714285714286)
      "6.8"

      iex> Faber.CLI.Render.raw_score(9)
      "9"
  """
  @spec raw_score(number()) :: String.t()
  def raw_score(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 1)
  def raw_score(n), do: to_string(n)

  @doc """
  An eval composite: four decimals, because it is compared against a gate threshold and the
  difference that matters is often in the third.

      iex> Faber.CLI.Render.score(0.8016)
      "0.8016"

      iex> Faber.CLI.Render.score(nil)
      "—"
  """
  @spec score(maybe_number()) :: String.t()
  def score(n) when is_number(n), do: decimals(n, 4)
  def score(_), do: @none

  @doc """
  A 0..1 ratio as a percent.

      iex> Faber.CLI.Render.rate(0.8181818181818182)
      "82%"

      iex> Faber.CLI.Render.rate(nil)
      "—"
  """
  @spec rate(maybe_number()) :: String.t()
  def rate(nil), do: @none
  def rate(rate), do: "#{round(rate * 100)}%"

  @doc """
  A 0..1 friction or opportunity score: two decimals.

      iex> Faber.CLI.Render.friction(0.9999999998308102)
      "1.00"

      iex> Faber.CLI.Render.friction(nil)
      "—"
  """
  @spec friction(maybe_number()) :: String.t()
  def friction(n) when is_number(n), do: decimals(n, 2)
  def friction(_), do: @none

  # `n * 1.0` rather than `n / 1`: float_to_binary/2 raises on an integer, and `/` would too if the
  # value ever arrived as something exotic. Ints reach here — `raw` is 9 in the fixtures.
  defp decimals(n, places), do: :erlang.float_to_binary(n * 1.0, decimals: places)

  # ── scope ────────────────────────────────────────────────────────────────────────────────────

  @doc """
  How a scan announces which sessions it ranked.

  Printed on EVERY scan, scoped or not. A scan that quietly changed which sessions it ranks — and a
  scoped one does, by default — has to say so on the surface the user actually reads, or the count
  in the table is unreadable: 9 sessions out of what?

  Lives here rather than in `Faber.CLI` because the `mix faber.*` tasks scan too, and a scope line
  each surface phrases for itself is how `mix faber.scan` came to say nothing at all while `faber
  scan` explained itself.

      iex> Faber.CLI.Render.scope_line(%Faber.Scan.Scope{kind: :all, reason: :requested})
      "all projects"

      iex> Faber.CLI.Render.scope_line(nil)
      "all projects"
  """
  @spec scope_line(Scope.t() | nil) :: String.t()
  def scope_line(%Scope{kind: :project} = scope),
    do: "project: #{scope.label} (#{scope.root}) — use --all for every project"

  def scope_line(%Scope{kind: :all} = scope), do: "all projects#{all_because(scope)}"
  def scope_line(_scope), do: "all projects"

  # Why we're showing everything, when the user didn't ask for everything. `:unknown_cwd` is the one
  # that must never be silent: it is a scoped scan that FELL BACK, and without a word here the user
  # reads a 60-project table as this project's.
  defp all_because(%Scope{reason: :unknown_cwd}),
    do:
      " — no sessions recorded for this directory, so nothing to scope to " <>
        "(`--base DIR` sets the transcript root explicitly)"

  defp all_because(%Scope{reason: :no_cwd}),
    do: " — the working directory could not be read, so nothing to scope to"

  defp all_because(_scope), do: ""

  # ── verdicts ─────────────────────────────────────────────────────────────────────────────────

  @doc """
  A severity-styled word: colored on a terminal, bare text when piped.

      iex> Faber.CLI.Render.badge("PASS", :ok)
      "PASS"

  That example is the piped answer, and it holds here only because `Faber.CLI.RenderTest` pins
  `:elixir, :ansi_enabled` off for the module. Without the pin this doctest is a coin-flip on how
  `mix test` was launched — the flag is set at VM boot from `isatty(stdout)`, so it is true from a
  terminal and false under a redirect. On a terminal the same call answers the green-wrapped form;
  the test file asserts both directions.
  """
  @spec badge(String.t(), severity()) :: String.t()
  def badge(text, severity) when is_binary(text) and is_map_key(@palette, severity) do
    text
    |> Owl.Data.tag(Map.fetch!(@palette, severity))
    |> Owl.Data.to_chardata()
    |> IO.chardata_to_string()
  end
end
