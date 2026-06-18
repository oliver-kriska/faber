defmodule FaberWeb.DashboardLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint FaberWeb.Endpoint

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

    html = render_async(view)
    assert html =~ "Friction"
    assert html =~ "sessions scanned"
    # The dashboard scans test/fixtures (see config/test.exs), so the project column shows it.
    assert html =~ "fixtures/"

    assert render_click(view, "rescan") =~ "Faber"
  end
end
