defmodule FaberWeb.DashboardLiveEnvTest do
  # async: false — these tests mutate application env (:dashboard_scan_opts, :llm) to exercise the
  # empty-state and proposal-failure render paths, so they must not run concurrently with the
  # hermetic async dashboard tests. Each restores the prior value via on_exit.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint FaberWeb.Endpoint

  # An LLM impl that always fails, to drive Faber.Propose down its {:error, _} path.
  defmodule FailingLLM do
    @behaviour Faber.LLM
    @impl Faber.LLM
    def generate_object(_prompt, _schema, _opts), do: {:error, :llm_unavailable}
  end

  setup do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  test "the connected render shows the empty state when no sessions match", %{conn: conn} do
    empty = Path.join(System.tmp_dir!(), "faber_empty_#{System.unique_integer([:positive])}")
    File.mkdir_p!(empty)
    prev = Application.get_env(:faber, :dashboard_scan_opts)
    Application.put_env(:faber, :dashboard_scan_opts, base: empty, min_messages: 0)

    on_exit(fn ->
      Application.put_env(:faber, :dashboard_scan_opts, prev)
      File.rm_rf!(empty)
    end)

    {:ok, view, _html} = live(conn, "/")
    html = render_async(view)

    assert html =~ "No sessions matched."
    assert html =~ "sessions scanned"
    refute html =~ "<table"
  end

  test "web_allow_propose: false hides the button and rejects the raw event", %{conn: conn} do
    Application.put_env(:faber, :web_allow_propose, false)
    on_exit(fn -> Application.delete_env(:faber, :web_allow_propose) end)

    {:ok, view, _html} = live(conn, "/")
    html = render_async(view)

    # UI: no Propose button anywhere in the ranked table.
    refute html =~ "phx-click=\"propose\""

    # Boundary: a client driving the raw event (bypassing the hidden button) is refused —
    # no async proposal starts, and the refusal is surfaced as a flash.
    html = render_click(view, "propose", %{"i" => "1"})
    assert html =~ "Propose is disabled"
    refute render(view) =~ "Proposing a skill"
  end

  test "a proposal failure renders an error panel without crashing the view", %{conn: conn} do
    prev = Application.get_env(:faber, :llm)
    Application.put_env(:faber, :llm, FailingLLM)
    on_exit(fn -> Application.put_env(:faber, :llm, prev) end)

    {:ok, view, _html} = live(conn, "/")
    render_async(view)

    # The scan still uses the default fixture sessions, so i=1 is a valid row; only the LLM fails.
    render_click(view, "propose", %{"i" => "1"})
    html = render_async(view)

    assert html =~ "Proposal failed:"
    # The LiveView process survived the failed async and still re-renders.
    assert render(view) =~ "session friction"
  end
end
