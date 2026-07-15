defmodule FaberWeb.DashboardLiveTest do
  # Safe to run async: no shared global state (server: false endpoint, no DB, no put_env).
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

  test "the disconnected (first-paint) render shows a loading state, no scan", %{conn: conn} do
    html = conn |> get("/") |> html_response(200)
    assert html =~ "Faber"
    assert html =~ "scanning sessions"
    refute html =~ "<table"
  end

  test "the connected render runs the scan and renders the ranked table", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")

    # The connected mount shows the loading state first; the scan runs asynchronously.
    assert html =~ "scanning sessions"

    html = render_async(view, @async_timeout)
    assert html =~ "Friction"
    assert html =~ "sessions scanned"
    # The dashboard scans test/fixtures (see config/test.exs), so the project column shows it.
    assert html =~ "fixtures/"

    assert render_click(view, "rescan") =~ "Faber"
  end

  test "the Propose action presents a generated skill and its eval verdict", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    render_async(view, @async_timeout)

    # Propose for the top-ranked session (stub LLM + native eval — hermetic).
    render_click(view, "propose", %{"i" => "1"})
    html = render_async(view, @async_timeout)

    assert html =~ "composite"
    assert html =~ "Iron Laws"
  end

  test "the ranked table renders rows in descending friction order", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    html = render_async(view, @async_timeout)

    # Each row is `<td muted>#</td><td num>friction</td>` — pull the friction column out and
    # confirm the view preserves Scan's friction-descending order.
    frictions =
      ~r|<td class="muted">\d+</td>\s*<td class="num">([\d.]+)</td>|
      |> Regex.scan(html, capture: :all_but_first)
      |> List.flatten()
      |> Enum.map(&String.to_float/1)

    assert length(frictions) >= 2
    assert frictions == Enum.sort(frictions, :desc)
  end

  test "a malformed or out-of-range propose index is a safe no-op", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    render_async(view, @async_timeout)

    # Out-of-range index → Enum.at/2 yields nil; non-integer → Integer.parse fails. Both must
    # fall through the `else` clause without opening a panel or crashing the LiveView.
    html = render_click(view, "propose", %{"i" => "999"})
    refute html =~ "Proposing a skill"
    refute html =~ "composite"

    html = render_click(view, "propose", %{"i" => "abc"})
    refute html =~ "Proposing a skill"

    # The process survived both bad clicks and still re-renders.
    assert render(view) =~ "session friction"
  end
end
