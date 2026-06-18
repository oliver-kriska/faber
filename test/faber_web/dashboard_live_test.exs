defmodule FaberWeb.DashboardLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint FaberWeb.Endpoint

  setup do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  test "mounts and renders the ranked friction table", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")

    assert html =~ "Faber"
    assert html =~ "session friction"
    assert html =~ "Friction"
    assert html =~ "sessions scanned"

    # The dashboard scans test/fixtures (see config/test.exs), so the project column shows it.
    assert render(view) =~ "fixtures/"
  end

  test "rescan re-runs the scan and re-renders", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    assert render_click(view, "rescan") =~ "Faber"
  end
end
