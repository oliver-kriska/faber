defmodule FaberWeb.DashboardLiveTest do
  # Safe to run async: no shared global state (server: false endpoint, no DB, no put_env). The
  # install tests deliberately never drive a *valid* agent, so nothing is written to ~/.claude.
  use ExUnit.Case, async: true

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint FaberWeb.Endpoint

  # `render_async/1` defaults to ExUnit's `assert_receive_timeout` (100ms). The awaited work here
  # is real — the scan walks the fixture transcripts, and Propose additionally loads the adapter
  # pack off disk, scores it, and renders. That is ~20ms on a warm dev machine, but a loaded CI
  # runner with a cold file cache overruns 100ms and fails the test on timing alone. Wait
  # explicitly instead: still fails fast if the async genuinely hangs.
  @async_timeout 2_000

  setup do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  test "the disconnected (first-paint) render shows a loading state, no table", %{conn: conn} do
    html = conn |> get("/") |> html_response(200)
    assert html =~ "Faber"
    assert html =~ "scanning sessions"
    refute html =~ "<table"
  end

  test "the connected render runs the scan and lands on the overview table", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")

    # The connected mount shows the loading state first; the scan runs asynchronously.
    assert html =~ "scanning sessions"

    html = render_async(view, @async_timeout)
    # Overview mode: the full ranked table, no detail pane open yet.
    assert html =~ ~s(class="stage")
    assert html =~ ~s(data-mode="overview")
    assert html =~ ~s(<table class="ranked")
    assert html =~ "sessions scanned"
    # The dashboard scans test/fixtures (see config/test.exs), so a row shows it (a name span
    # plus a muted id span).
    assert html =~ ~s(<span class="proj-name">fixtures</span>)

    # Every metric header carries its explanation (Errs/Ctx/Tools no longer bare), and the filter
    # combo advertises collapsed/expanded state to assistive tech.
    assert html =~ "Peak context-window usage"
    assert html =~ ~s(aria-expanded="false")

    # The header cells scope to their column for SR table nav, and the tipped ones are keyboard
    # focusable so their hover definition is reachable without a pointer (WCAG 1.4.13).
    assert html =~ ~s(<th scope="col" tabindex="0" class="col-friction)

    assert render_click(view, "rescan") =~ "Faber"
  end

  test "the overview leads with a hero for the top session and keyboard-operable rows", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, "/")
    html = render_async(view, @async_timeout)

    # The opinionated landing: a hero featuring the single highest-friction session, with the one
    # action that matters — Propose — as an explicit, token-spend-confirmed click. It must NOT
    # auto-propose on load (that would spend LLM tokens on every page view).
    assert html =~ ~s(class="hero")
    assert html =~ "highest-friction session"
    assert html =~ ~s(phx-click="propose" phx-value-i="1")
    assert html =~ "spends tokens"

    # The hero's friction score is keyboard-focusable and carries the definition as an accessible
    # name, so a screen-reader user gets the "what is friction" explanation the tooltip shows.
    assert html =~ ~s(aria-label="Friction )

    # Every ranked row is a focusable, button-role control (Enter activates it server-side via
    # phx-keydown); the caption advertises the keyboard model up front.
    assert html =~ ~s(tabindex="0")
    assert html =~ ~s(role="button")
    assert html =~ ~s(phx-keydown="select")
    assert html =~ ~s(class="ranked-caption")

    # The hero is the overview lead only: opening a session swaps it for the detail pane.
    detail = render_click(view, "select", %{"i" => "1"})
    assert detail =~ ~s(data-mode="detail")
    refute detail =~ ~s(class="hero")
  end

  test "Enter on a focused row opens it (keyboard parity with click)", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    render_async(view, @async_timeout)

    # The row binds `phx-keydown="select"` with `phx-key="Enter"` and carries `phx-value-i`, so an
    # Enter press is delivered as the same select event a click is — opening the detail pane.
    html = render_keydown(view, "select", %{"key" => "Enter", "i" => "2"})
    assert html =~ ~s(data-mode="detail")
    assert html =~ ~s(id="session-2" class="srow selected")
  end

  test "the facet filters narrow the table and can be cleared", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    html = render_async(view, @async_timeout)

    # The filter bar renders three custom combo dropdowns (project is searchable).
    assert html =~ ~s(class="filters")
    assert html =~ ~s(data-combo-toggle)
    assert html =~ ~s(phx-value-facet="project")
    assert html =~ ~s(phx-value-facet="type")
    assert html =~ ~s(phx-value-facet="signal")
    assert html =~ ~s(data-combo-search)

    # The combo is a menu of mutually-exclusive choices (menuitemradio + aria-checked), NOT the old
    # `role="listbox"` that announced as an empty listbox (it never had `option` children). The
    # trigger names its facet so a screen reader doesn't hear a bare "All projects".
    assert html =~ ~s(aria-haspopup="menu")
    assert html =~ ~s(role="menuitemradio")
    assert html =~ ~s(aria-label="Project filter:)
    refute html =~ ~s(role="listbox")

    # The chosen value MUST ride on `phx-value-choice`, never the reserved `phx-value-value`: on a
    # <button>, LiveView's client overwrites the `value` key with the element's own (empty) `.value`,
    # so a `value`-named payload reaches the server blank and every pick silently no-ops. Guard the
    # wiring so nobody "simplifies" it back to the colliding key.
    assert html =~ ~s(phx-value-choice=)
    refute html =~ ~s(phx-value-value=)

    # Drive the pick through the *rendered* combo button (element/2 reads its phx-value-* straight
    # from the DOM), not a hand-built payload — the hand-built form is exactly what masked the
    # collision. A real project keeps a populated table.
    choice =
      Regex.run(~r/phx-value-choice="([^"]+)"/, html, capture: :all_but_first) |> hd()

    narrowed =
      view
      |> element(~s(#combo-project button[phx-value-choice="#{choice}"]))
      |> render_click()

    assert narrowed =~ ~s(<table class="ranked")

    # Picking a project that matches nothing filters the table out → the filtered-empty state, not
    # the "no scan results" one, and the table is gone.
    filtered =
      render_click(view, "pick_filter", %{"facet" => "project", "choice" => "does-not-exist"})

    assert filtered =~ "No sessions match these filters"
    refute filtered =~ ~s(<table class="ranked")

    # An unknown facet is a safe no-op (guard falls through).
    assert render_click(view, "pick_filter", %{"facet" => "bogus", "choice" => "x"}) =~
             "No sessions match these filters"

    # Clearing restores the full table.
    assert render_click(view, "clear_filters") =~ ~s(<table class="ranked")
  end

  test "clicking a row collapses to detail mode and opens that session in the pane", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    render_async(view, @async_timeout)

    html = render_click(view, "select", %{"i" => "2"})
    assert html =~ ~s(data-mode="detail")
    assert html =~ ~s(class="detail")
    assert html =~ ~s(id="session-2" class="srow selected")
    # The pane is a labelled region headed by an <h2>, so a screen reader can find and name it.
    assert html =~ ~s(<h2 class="detail-id" id="detail-heading">)
    assert html =~ ~s(aria-labelledby="detail-heading")
    # The pane explains the row in prose (the "explain the row" affordance).
    assert html =~ "Friction here"

    # Escape returns to the overview table; a malformed/out-of-range select is a safe no-op.
    assert render_click(view, "nav", %{"key" => "Escape"}) =~ ~s(data-mode="overview")
    render_click(view, "select", %{"i" => "2"})

    assert render_click(view, "select", %{"i" => "999"}) =~
             ~s(id="session-2" class="srow selected")

    assert render_click(view, "select", %{"i" => "abc"}) =~
             ~s(id="session-2" class="srow selected")
  end

  test "Propose (from the open detail pane) shows a loading state, then the skill card", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, "/")
    render_async(view, @async_timeout)
    render_click(view, "select", %{"i" => "1"})

    # The click sets the in-flight state synchronously (before the async resolves), so the inline
    # "Proposing…" line + progress bar render immediately — the loading feedback.
    loading = render_click(view, "propose", %{"i" => "1"})
    assert loading =~ "Proposing"
    assert loading =~ ~s(class="progress")

    # When the async completes (stub LLM + native eval — hermetic), the result card shows the
    # skill, its eval verdict, and the act-in-place controls (copy + install menu).
    html = render_async(view, @async_timeout)
    assert html =~ "composite"
    assert html =~ "Iron Laws"
    assert html =~ "Copy skill"
    assert html =~ ~s(class="proposal-card")
    assert html =~ ~s(data-install-toggle)
    assert html =~ "Claude Code"
    assert html =~ "Codex"
  end

  test "an install with an unknown agent is a safe no-op (writes nothing)", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    render_async(view, @async_timeout)
    render_click(view, "select", %{"i" => "1"})
    render_click(view, "propose", %{"i" => "1"})
    assert render_async(view, @async_timeout) =~ "proposal-card"

    # An agent Faber has no context file for is rejected by the handler's guard — no crash, no
    # write, the card is still there. (The happy-path write is covered by Faber.Install's tests,
    # which sandbox the skills dir; the LiveView test never drives a real agent.)
    assert render_click(view, "install", %{"agent" => "bogus", "i" => "1"}) =~ "proposal-card"
  end

  test "Rescan clears a shown proposal and returns to the overview table", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    render_async(view, @async_timeout)
    render_click(view, "select", %{"i" => "1"})

    render_click(view, "propose", %{"i" => "1"})
    assert render_async(view, @async_timeout) =~ "proposal-card"

    # Rescanning re-ranks the rows, so the detail pane (and its card) must drop immediately.
    html = render_click(view, "rescan")
    refute html =~ "proposal-card"
    assert html =~ "Faber"
  end

  test "the ranked table renders rows in descending friction order", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    html = render_async(view, @async_timeout)

    # Each row carries `data-friction="<raw>"` — pull that out and confirm the view preserves
    # Scan's friction-descending order (decoupled from the row's styling).
    frictions =
      ~r/data-friction="([\d.]+)"/
      |> Regex.scan(html, capture: :all_but_first)
      |> List.flatten()
      |> Enum.map(&String.to_float/1)

    assert length(frictions) >= 2
    assert frictions == Enum.sort(frictions, :desc)
  end

  test "a malformed or out-of-range propose index is a safe no-op", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    render_async(view, @async_timeout)
    render_click(view, "select", %{"i" => "1"})

    # Out-of-range index → Enum.at/2 yields nil; non-integer → Integer.parse fails. Both must fall
    # through the `else` clause without starting a proposal or crashing the LiveView.
    html = render_click(view, "propose", %{"i" => "999"})
    refute html =~ "Proposing a skill"
    refute html =~ "composite"

    html = render_click(view, "propose", %{"i" => "abc"})
    refute html =~ "Proposing a skill"

    # The process survived both bad clicks and still re-renders.
    assert render(view) =~ "session friction"
  end
end
