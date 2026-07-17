defmodule FaberWeb.DashboardHookTest do
  @moduledoc """
  The dashboard's hook surface: a session's hazards in the detail pane, and the Propose-a-hook →
  install path from there.

  **Not in the ranked table, deliberately** — a hazard is a frictionless success, so it contributes
  nothing to the score the table sorts by, and the fixture that carries one scores `0.0`. A column
  would say hazards are part of the ranking; they are the thing the ranking cannot see. The detail
  pane is where a fact *about the session you opened* belongs, so that is where they are, and the
  first test below pins that distinction rather than trusting it.
  """
  # async: false — scopes :dashboard_scan_opts to the hazard fixture and redirects both hook write
  # targets into a tmp dir. Both are application env, restored on exit.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint FaberWeb.Endpoint

  # See FaberWeb.DashboardLiveTest — the async scan walks real fixture transcripts.
  @async_timeout 2_000

  setup %{tmp_dir: tmp_dir} do
    prev = %{
      scan: Application.get_env(:faber, :dashboard_scan_opts),
      propose: Application.get_env(:faber, :web_allow_propose),
      install: Application.get_env(:faber, :web_allow_install),
      hooks: Application.get_env(:faber, :hooks_dir),
      settings: Application.get_env(:faber, :settings_path),
      proposals: Application.get_env(:faber, :proposals_dir)
    }

    Application.put_env(:faber, :dashboard_scan_opts, base: "test/fixtures", min_messages: 0)
    Application.put_env(:faber, :web_allow_propose, true)
    Application.put_env(:faber, :web_allow_install, true)
    Application.put_env(:faber, :hooks_dir, Path.join(tmp_dir, "faber-hooks"))
    Application.put_env(:faber, :settings_path, Path.join(tmp_dir, "settings.json"))
    Application.put_env(:faber, :proposals_dir, Path.join(tmp_dir, "proposals"))

    on_exit(fn -> Enum.each(prev, fn {k, v} -> restore(key(k), v) end) end)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  defp key(:scan), do: :dashboard_scan_opts
  defp key(:propose), do: :web_allow_propose
  defp key(:install), do: :web_allow_install
  defp key(:hooks), do: :hooks_dir
  defp key(:settings), do: :settings_path
  defp key(:proposals), do: :proposals_dir

  defp restore(k, nil), do: Application.delete_env(:faber, k)
  defp restore(k, v), do: Application.put_env(:faber, k, v)

  # Open the detail pane on the session carrying the seeded hazard, and hand back the view + html.
  defp open_hazard_session(conn) do
    {:ok, view, _} = live(conn, "/")
    html = render_async(view, @async_timeout)

    i = hazard_row(html)
    {view, render_click(view, "select", %{"i" => to_string(i)}), i}
  end

  # The row index of the hazard fixture, from the table itself — never a hardcoded rank. It scores
  # 0.0 friction, so where it lands among the other zero-friction fixtures is not something this
  # test should be asserting on.
  defp hazard_row(html) do
    idx =
      Regex.scan(~r/id="session-(\d+)"[^>]*>(.*?)(?=id="session-\d+"|\z)/s, html)
      |> Enum.find_value(fn [_, i, body] -> if body =~ "hazard", do: String.to_integer(i) end)

    assert idx, "the hazard fixture is not in the rendered table — this test has lost its subject"
    idx
  end

  @tag :tmp_dir
  test "the ranked table shows no hazards; the detail pane does", %{conn: conn} do
    {:ok, view, _} = live(conn, "/")
    overview = render_async(view, @async_timeout)

    # The table is sorted by friction, and this hazard has none. Naming it there would imply it is
    # part of the score — the one thing the whole design says it isn't.
    refute overview =~ "pipe_masks_exit"
    refute overview =~ "Hazards"

    {_view, detail, _i} = open_hazard_session(conn)

    assert detail =~ "Hazards"
    assert detail =~ "pipe masks exit"
    assert detail =~ "mix verify | tail -5"
    # The hook pointer the hazard implies.
    assert detail =~ "PreToolUse"
    # And it says WHY a hook rather than a skill, since the session looks clean.
    assert detail =~ "without struggling"
    assert detail =~ "Propose a hook"
  end

  @tag :tmp_dir
  test "a session with no hazard says nothing — not that it is clean", %{conn: conn} do
    # Faber detects one class. An "all clear" on a session it scanned would be a claim it cannot
    # support, so the block is presence-gated rather than showing an empty state.
    {:ok, view, _} = live(conn, "/")
    render_async(view, @async_timeout)

    detail = render_click(view, "select", %{"i" => "1"})

    refute detail =~ "Hazards"
    refute detail =~ "No hazards"
  end

  @tag :tmp_dir
  test "Propose a hook drafts, evals, and installs — script plus pointer", %{conn: conn} do
    {view, _detail, i} = open_hazard_session(conn)

    card =
      view
      |> render_click("propose_hook", %{"i" => to_string(i), "kind" => "pipe_masks_exit"})
      |> then(fn _ -> render_async(view, @async_timeout) end)

    # A hook, scored and labelled as one — not a skill card with shell in it.
    assert card =~ "no-masked-gate-exit"
    assert card =~ "hook"
    assert card =~ "#!/usr/bin/env bash"
    assert card =~ "Install hook"
    # No agent picker: a hook is a Claude Code mechanism, so there is nothing to ask.
    refute card =~ ~s(phx-click="install")

    render_click(view, "install_hook", %{"i" => to_string(i)})

    script =
      Path.join([Application.get_env(:faber, :hooks_dir), "no-masked-gate-exit", "hook.sh"])

    assert File.exists?(script)
    assert script |> Path.dirname() |> Path.join(".faber.json") |> File.exists?()

    settings =
      Application.get_env(:faber, :settings_path) |> File.read!() |> Jason.decode!()

    assert [%{"matcher" => "Bash", "hooks" => [%{"command" => ^script}]}] =
             settings["hooks"]["PreToolUse"]
  end

  @tag :tmp_dir
  test "propose_hook is refused server-side when the flag is off — the hidden button is not a gate",
       %{conn: conn} do
    {view, _detail, i} = open_hazard_session(conn)
    Application.put_env(:faber, :web_allow_propose, false)

    html = render_click(view, "propose_hook", %{"i" => to_string(i), "kind" => "pipe_masks_exit"})

    assert html =~ "web_allow_propose"
    refute html =~ "Proposing a hook"
  end

  @tag :tmp_dir
  test "an unknown hazard class from a raw client event is ignored, not crashed on", %{conn: conn} do
    {view, _detail, i} = open_hazard_session(conn)

    # `kind` is client-supplied. A value naming no hazard on this session must be a no-op — the
    # LiveView process staying alive is the assertion.
    html = render_click(view, "propose_hook", %{"i" => to_string(i), "kind" => "made_up"})

    refute html =~ "Proposing"
    assert render(view) =~ "Hazards"
  end
end
