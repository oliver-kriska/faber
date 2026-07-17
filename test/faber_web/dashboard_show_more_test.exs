defmodule FaberWeb.DashboardShowMoreTest do
  # Exercises the "Show more" reveal, which only appears once the matching set exceeds the display
  # cap. The fixture corpus is 6 sessions — under the 25-row production cap — so this module shrinks
  # the cap via `dashboard_display_cap` to drive the reveal. That mutates application env, so it runs
  # `async: false` (in isolation from `DashboardLiveTest`, which is async and cap-25 dependent) and
  # restores the env afterwards.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint FaberWeb.Endpoint

  # See DashboardLiveTest: the async scan walks the fixture transcripts; wait generously so a cold CI
  # runner doesn't fail on timing rather than behaviour.
  @async_timeout 2_000

  setup do
    prev = Application.get_env(:faber, :dashboard_display_cap)
    Application.put_env(:faber, :dashboard_display_cap, 2)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:faber, :dashboard_display_cap)
        val -> Application.put_env(:faber, :dashboard_display_cap, val)
      end
    end)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  test "'Show more' reveals the next cap-sized slice until the whole set is shown", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    html = render_async(view, @async_timeout)

    # 6 fixture sessions, cap 2: the first slice shows 2, the paginating footer offers the rest.
    assert count_rows(html) == 2
    assert html =~ ~s(phx-click="show_more")
    assert html =~ "Show more"
    assert html =~ "2 of 6 shown"

    # One reveal raises the limit by a cap: 4 of 6 now on screen, control still present.
    after_one = render_click(view, "show_more")
    assert count_rows(after_one) == 4
    assert after_one =~ ~s(phx-click="show_more")
    assert after_one =~ "4 of 6 shown"

    # The next reveal reaches the whole set: all 6 rows show and the control retires (its gate,
    # `@shown < @match_count`, no longer holds).
    after_two = render_click(view, "show_more")
    assert count_rows(after_two) == 6
    refute after_two =~ ~s(phx-click="show_more")
    refute after_two =~ "Show more"
  end

  test "a scope change resets the reveal back to the first cap-sized slice", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    render_async(view, @async_timeout)

    # Reveal a wider slice, then re-scope the table: the widened limit must NOT carry over — every
    # scope change (`reset_selection/1`, shared by filter pick and clear) starts at the top of the
    # new set. `clear_filters` is the unconditional trigger; a `pick_filter` runs the same path.
    render_click(view, "show_more")
    reset = render_click(view, "clear_filters")

    assert count_rows(reset) == 2
    assert reset =~ ~s(phx-click="show_more")
    assert reset =~ "2 of 6 shown"
  end

  # Count rendered ranked rows by their stable per-row id (`session-N`), independent of column markup.
  defp count_rows(html), do: length(Regex.scan(~r/id="session-\d+"/, html))
end
