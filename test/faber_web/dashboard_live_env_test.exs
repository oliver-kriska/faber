defmodule FaberWeb.DashboardLiveEnvTest do
  # async: false — these tests mutate application env (:dashboard_scan_opts, :llm) to exercise the
  # empty-state and proposal-failure render paths, so they must not run concurrently with the
  # hermetic async dashboard tests. Each restores the prior value via on_exit.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint FaberWeb.Endpoint

  # See FaberWeb.DashboardLiveTest — `render_async/1`'s 100ms default is too tight for the real
  # scan/propose work on a loaded CI runner.
  @async_timeout 2_000

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
    html = render_async(view, @async_timeout)

    # First-run onboarding, not a bare "none": name where we looked and the one next step.
    assert html =~ "No sessions to rank yet."
    assert html =~ empty
    assert html =~ "coding-agent transcripts"
    assert html =~ "sessions scanned"
    refute html =~ "<table"
  end

  test "a scan crash shows the retry state, not the onboarding copy", %{conn: conn} do
    prev = Application.get_env(:faber, :dashboard_scan_opts)
    # An unknown ingest source makes Scan.run raise inside the async task, driving the {:exit, _}
    # scan handler — the crash path, distinct from a genuinely empty scan.
    Application.put_env(:faber, :dashboard_scan_opts, source: :faber_bogus_source_for_test)
    on_exit(fn -> Application.put_env(:faber, :dashboard_scan_opts, prev) end)

    {:ok, view, _html} = live(conn, "/")
    html = render_async(view, @async_timeout)

    # Crash copy — nothing wrong with the sessions, so point at the logs + Rescan, and NOT the
    # "no sessions to rank yet" onboarding teaching (which would misdiagnose the failure).
    assert html =~ "Something went wrong reading your sessions."
    assert html =~ "Rescan"
    refute html =~ "No sessions to rank yet."
    refute html =~ "<table"
  end

  test "web_allow_propose: false hides the button and rejects the raw event", %{conn: conn} do
    Application.put_env(:faber, :web_allow_propose, false)
    on_exit(fn -> Application.delete_env(:faber, :web_allow_propose) end)

    {:ok, view, _html} = live(conn, "/")
    html = render_async(view, @async_timeout)

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
    render_async(view, @async_timeout)

    # The scan still uses the default fixture sessions, so i=1 is a valid row; only the LLM fails.
    # First select the session to open the detail pane where the error will render.
    render_click(view, "select", %{"i" => "1"})
    render_click(view, "propose", %{"i" => "1"})
    html = render_async(view, @async_timeout)

    # Plain-language failure copy — no raw `inspect` term leaked to the user (that goes to the
    # server logs) — plus an explicit, token-spend-confirmed Retry affordance. (The apostrophe in
    # the static copy renders HTML-escaped, so the asserted fragment avoids it.)
    assert html =~ "draft a skill for this session."
    assert html =~ "An unexpected error stopped it."
    assert html =~ "Try again"
    assert html =~ ~s(class="proposal-error")
    refute html =~ ":llm_unavailable"
    # The LiveView process survived the failed async and still re-renders.
    assert render(view) =~ "session friction"
  end
end
