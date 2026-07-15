defmodule FaberWeb.DashboardInstalledTest do
  # async: false — it mutates the global `:skills_dir` config so the dashboard's mount-time disk
  # read sees a *seeded* skills dir. A sync module never overlaps the async ones, so the put_env is
  # safe; the backstop in config/test.exs keeps every other test reading an empty dir.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint FaberWeb.Endpoint

  # See dashboard_live_test.exs — the fixture scan + propose path can overrun the 100ms default.
  @async_timeout 2_000

  # The top fixture session (rank #1, raw 9.0). Its id is what we stamp into the seeded skill's
  # provenance marker, and what the dashboard matches on to mark the row/detail as installed.
  @source_session "s"

  setup do
    tmp = Path.join(System.tmp_dir!(), "faber_skills_#{System.unique_integer([:positive])}")
    prev = Application.fetch_env(:faber, :skills_dir)
    Application.put_env(:faber, :skills_dir, tmp)

    on_exit(fn ->
      case prev do
        {:ok, dir} -> Application.put_env(:faber, :skills_dir, dir)
        :error -> Application.delete_env(:faber, :skills_dir)
      end

      File.rm_rf(tmp)
    end)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  # Seed a Faber-installed skill on disk (SKILL.md + `.faber.json` marker) carrying `source_session`,
  # exactly as an install does — the state the dashboard reads back on mount.
  defp seed_skill(name, source_session) do
    md = """
    ---
    name: #{name}
    description: A seeded skill for the installed-marker test.
    ---

    # #{name}
    """

    {:ok, _path} =
      Faber.Install.install({name, md}, provenance: %{"source_session" => source_session})
  end

  test "with no Faber skills installed, no session shows an installed marker", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    html = render_async(view, @async_timeout)

    refute html =~ "row-skill"
    refute html =~ "badge installed"
  end

  test "a session with a Faber skill on disk is marked installed, surviving a fresh mount", %{
    conn: conn
  } do
    seed_skill("seeded-skill", @source_session)

    # A brand-new mount is exactly what a browser refresh does: the LiveView's assigns are empty, so
    # the "installed" state can only come from the on-disk provenance marker.
    {:ok, view, _html} = live(conn, "/")
    html = render_async(view, @async_timeout)

    # The ranked table flags the seeded session's row.
    assert html =~ "row-skill"

    # Opening that session (rank #1) shows the persistent detail badge, naming the skill — no
    # proposal in memory, no install this session, purely reconstructed from disk.
    detail = render_click(view, "select", %{"i" => "1"})
    assert detail =~ ~s(class="badge installed")
    assert detail =~ "seeded-skill installed"
  end

  test "the proposal card offers Reinstall (force) when a skill of that name already exists", %{
    conn: conn
  } do
    # The stub always proposes `investigate-retry-loops`; a skill by that exact name already on disk
    # means installing would clobber it, so the card must offer an explicit force-Reinstall instead.
    seed_skill("investigate-retry-loops", "unrelated-session")

    {:ok, view, _html} = live(conn, "/")
    render_async(view, @async_timeout)
    render_click(view, "select", %{"i" => "1"})
    render_click(view, "propose", %{"i" => "1"})
    html = render_async(view, @async_timeout)

    assert html =~ "Reinstall ▾"
    assert html =~ ~s(phx-value-force="true")
    refute html =~ "Install ▾"
  end

  test "the proposal card offers a plain Install (no force) when the skill name is new", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, "/")
    render_async(view, @async_timeout)
    render_click(view, "select", %{"i" => "1"})
    render_click(view, "propose", %{"i" => "1"})
    html = render_async(view, @async_timeout)

    assert html =~ "Install ▾"
    refute html =~ "Reinstall ▾"
    refute html =~ ~s(phx-value-force="true")
  end
end
