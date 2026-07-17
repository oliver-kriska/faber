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

  alias Faber.Proposal.Store

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
      proposals: Application.get_env(:faber, :proposals_dir),
      store: Application.get_env(:faber, :proposal_store),
      skills: Application.get_env(:faber, :skills_dir)
    }

    Application.put_env(:faber, :dashboard_scan_opts, base: "test/fixtures", min_messages: 0)
    Application.put_env(:faber, :web_allow_propose, true)
    Application.put_env(:faber, :web_allow_install, true)
    Application.put_env(:faber, :hooks_dir, Path.join(tmp_dir, "faber-hooks"))
    Application.put_env(:faber, :settings_path, Path.join(tmp_dir, "settings.json"))
    Application.put_env(:faber, :proposals_dir, Path.join(tmp_dir, "proposals"))

    # The third write target, pinned for the same reason as the other two. `config/test.exs` points
    # this at a suite-wide dir, so a test asserting "a hook was NOT written here" would read a
    # neighbour's leftover and fail on someone else's write — or, worse, pass on its own.
    Application.put_env(:faber, :skills_dir, Path.join(tmp_dir, "skills"))

    # `config/test.exs` disables the proposal store globally, so nothing in the suite ever exercised
    # the restore path — which is exactly how B4 shipped: `restore_proposal/1` dropping `kind` was
    # unreachable from any test, in the env where every gate runs. Enabled here, scoped to this file
    # and pointed at `tmp_dir`, so the restore path is covered without any test writing to the real
    # `~/.faber`.
    Application.put_env(:faber, :proposal_store, true)

    on_exit(fn -> Enum.each(prev, fn {k, v} -> restore(key(k), v) end) end)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  defp key(:scan), do: :dashboard_scan_opts
  defp key(:propose), do: :web_allow_propose
  defp key(:install), do: :web_allow_install
  defp key(:hooks), do: :hooks_dir
  defp key(:settings), do: :settings_path
  defp key(:proposals), do: :proposals_dir
  defp key(:store), do: :proposal_store
  defp key(:skills), do: :skills_dir

  defp restore(k, nil), do: Application.delete_env(:faber, k)
  defp restore(k, v), do: Application.put_env(:faber, k, v)

  # The scan result for the fixture carrying the hazard — the seed for every store-backed restore
  # test below.
  defp hazard_result do
    result =
      [base: "test/fixtures", min_messages: 0]
      |> Faber.Scan.run()
      |> Enum.find(&(&1.hazards != []))

    assert result, "the hazard fixture vanished — this test has lost its subject"
    result
  end

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
  test "each hazard's Propose button is distinguishable by label alone (S4)", %{conn: conn} do
    # The visible text is "Propose a hook" on every hazard; what tells them apart is the hazard
    # rendered above each one. A screen reader listing this pane's buttons drops exactly that
    # spatial cue, so the accessible name has to carry the hazard itself.
    {_view, detail, _i} = open_hazard_session(conn)

    assert detail =~ ~s(aria-label="Propose a hook for )

    assert detail =~ ~r/aria-label="Propose a hook for [^"]+"/,
           "the per-hazard Propose button has no hazard in its accessible name"
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
  test "a RESTORED hook is still a hook — it cannot come back as a skill card", %{conn: conn} do
    # B4, found by codex where six Claude agents missed it. The store persisted `%{name, md, eval,
    # adapter}` with no `kind`; `restore_proposal/1` rebuilt without it; the card picks on
    # `@proposal[:kind] != :hook`, and `nil != :hook` is TRUE. So selecting away and back turned a
    # bash script into a skill card WITH the agent install menu — one click from writing
    # `#!/usr/bin/env bash` into `~/.claude/skills/<name>/SKILL.md`, where it is not a hook, not a
    # skill, and never runs.
    {view, _detail, i} = open_hazard_session(conn)

    view
    |> render_click("propose_hook", %{"i" => to_string(i), "kind" => "pipe_masks_exit"})
    |> then(fn _ -> render_async(view, @async_timeout) end)

    # Select away, then back — the restore path.
    other = if i == 1, do: 2, else: 1
    render_click(view, "select", %{"i" => to_string(other)})
    restored = render_click(view, "select", %{"i" => to_string(i)})

    assert restored =~ "no-masked-gate-exit", "the restore path did not put the proposal back"
    assert restored =~ "#!/usr/bin/env bash"

    # The card is a HOOK card: it offers the hook install and NOT the agent picker.
    assert restored =~ "Install hook"

    refute restored =~ ~s(phx-click="install"),
           "a restored hook came back as a SKILL card — its Install would write the script to " <>
             "~/.claude/skills/<name>/SKILL.md"

    refute restored =~ "data-install-toggle",
           "a restored hook came back with the agent install menu"
  end

  @tag :tmp_dir
  test "a restored hook installs the bytes it displayed", %{conn: conn} do
    # PB-T2, option (c). A restored hook must be installable *as a hook*, and must install the
    # stored bytes — the ones on screen — rather than a fresh render through a pack that may have
    # changed since. The locked posture is "the human confirms the script"; that only means
    # something if the confirmed bytes are the written bytes.
    {view, _detail, i} = open_hazard_session(conn)

    card =
      view
      |> render_click("propose_hook", %{"i" => to_string(i), "kind" => "pipe_masks_exit"})
      |> then(fn _ -> render_async(view, @async_timeout) end)

    assert card =~ "no-masked-gate-exit"

    other = if i == 1, do: 2, else: 1
    render_click(view, "select", %{"i" => to_string(other)})
    render_click(view, "select", %{"i" => to_string(i)})

    render_click(view, "install_hook", %{"i" => to_string(i)})

    script =
      Path.join([Application.get_env(:faber, :hooks_dir), "no-masked-gate-exit", "hook.sh"])

    assert File.exists?(script), "a restored hook's Install button did nothing"
    assert File.read!(script) =~ "#!/usr/bin/env bash"

    settings = Application.get_env(:faber, :settings_path) |> File.read!() |> Jason.decode!()

    assert [%{"matcher" => "Bash", "hooks" => [%{"command" => ^script}]}] =
             settings["hooks"]["PreToolUse"],
           "the restored hook's pointer did not carry its event/matcher"
  end

  @tag :tmp_dir
  test "the script is rendered BEFORE the Install button, not after it", %{conn: conn} do
    # PC-T3. The review claimed the dashboard "never shows the script" and that was wrong — the
    # `<pre>` was always there. But the plan's correction was ALSO wrong in the other direction: it
    # recorded the script as rendering *above* the Install button, and it did not. The button came
    # first, so the confirm could be answered before the reader ever reached the bytes.
    #
    # Ordering IS the posture. "Show the script, then confirm" is the whole reason the veto is
    # allowed to be a backstop; a confirm answered above its subject is a rubber stamp. Asserted on
    # DOM order because that is the claim — not on any visual property, which this test cannot see.
    {view, _detail, i} = open_hazard_session(conn)

    card =
      view
      |> render_click("propose_hook", %{"i" => to_string(i), "kind" => "pipe_masks_exit"})
      |> then(fn _ -> render_async(view, @async_timeout) end)

    script_at = :binary.match(card, "#!/usr/bin/env bash") |> elem(0)
    install_at = :binary.match(card, ~s(phx-click="install_hook")) |> elem(0)

    assert script_at < install_at,
           "the Install button precedes the script it installs — the confirm would be answered " <>
             "before the reader reaches the bytes"
  end

  @tag :tmp_dir
  test "install_hook is refused server-side when the flag is off — the hidden button is not a gate",
       %{conn: conn} do
    # S3, mirroring the `propose_hook` test above. `@allow_install` only hides the BUTTON; a raw
    # client event does not care about markup. This is the one that matters more of the two: propose
    # spends tokens, install writes an auto-executing script to disk.
    {view, _detail, i} = open_hazard_session(conn)

    view
    |> render_click("propose_hook", %{"i" => to_string(i), "kind" => "pipe_masks_exit"})
    |> then(fn _ -> render_async(view, @async_timeout) end)

    Application.put_env(:faber, :web_allow_install, false)

    html = render_click(view, "install_hook", %{"i" => to_string(i)})

    assert html =~ "web_allow_install"

    refute File.exists?(
             Path.join([
               Application.get_env(:faber, :hooks_dir),
               "no-masked-gate-exit",
               "hook.sh"
             ])
           ),
           "a raw install_hook event wrote a script with installs disabled"

    refute File.exists?(Application.get_env(:faber, :settings_path)),
           "a raw install_hook event wrote a settings.json pointer with installs disabled"
  end

  @tag :tmp_dir
  test "a hook that FAILED its eval is not installable — the score is a gate, not a caption",
       %{conn: conn} do
    # W2, and the dashboard half of the per-kind decision (`Faber.CLI.refuse_hook_install/2` carries
    # the argument). Before this, both surfaces rendered `passed` as a badge and then installed
    # regardless — the only thing standing between a broken hook and `chmod 0755` was the veto,
    # which does not look at whether the script can run at all.
    #
    # Driven through the restore path because that is the honest way to get a failing eval in front
    # of the button: seed the store with a hook whose eval failed, select the session, click.
    result =
      [base: "test/fixtures", min_messages: 0]
      |> Faber.Scan.run()
      |> Enum.find(&(&1.hazards != []))

    assert result, "the hazard fixture vanished — this test has lost its subject"

    Store.put(result, %{
      name: "no-masked-gate-exit",
      md: "#!/usr/bin/env bash\nexit 0\n",
      kind: :hook,
      event: "PreToolUse",
      matcher: "Bash",
      adapter: "faber-elixir",
      eval: %{composite: 0.41, passed: false, threshold: 0.9, dimensions: %{}}
    })

    {view, _detail, i} = open_hazard_session(conn)
    html = render_click(view, "install_hook", %{"i" => to_string(i)})

    assert html =~ "did not pass the hook eval"

    assert html =~ "necessary conditions",
           "the refusal must say WHY a hook is gated when a skill isn't"

    refute File.exists?(
             Path.join([
               Application.get_env(:faber, :hooks_dir),
               "no-masked-gate-exit",
               "hook.sh"
             ])
           ),
           "a hook that failed its eval was written to disk anyway"

    refute File.exists?(Application.get_env(:faber, :settings_path)),
           "a hook that failed its eval got a settings.json pointer"
  end

  @tag :tmp_dir
  test "a restored hook with NO stored eval refuses rather than installing on an unknown score",
       %{conn: conn} do
    # Fail-closed. A format-1/2 record predates the eval being stored, so `passed` restores as `nil`.
    # `nil` is not `false` — it is "we don't know", and the gate matches on `true` precisely so that
    # an unknown score refuses. An old draft is the LEAST reviewed thing on disk; it is the last
    # artifact that should get the benefit of the doubt.
    result =
      [base: "test/fixtures", min_messages: 0]
      |> Faber.Scan.run()
      |> Enum.find(&(&1.hazards != []))

    Store.put(result, %{
      name: "no-masked-gate-exit",
      md: "#!/usr/bin/env bash\nexit 0\n",
      kind: :hook,
      event: "PreToolUse",
      matcher: "Bash",
      adapter: "faber-elixir",
      eval: %{}
    })

    {view, _detail, i} = open_hazard_session(conn)
    html = render_click(view, "install_hook", %{"i" => to_string(i)})

    assert html =~ "did not pass the hook eval"
    assert html =~ "predates the eval being stored"

    refute File.exists?(Application.get_env(:faber, :settings_path)),
           "a hook with an unknown eval result was installed"
  end

  @tag :tmp_dir
  test "the SKILL install handler refuses a hook — the hidden button is not a gate", %{conn: conn} do
    # The THIRD surface that turns a stored record into a file, found by auditing for a third after
    # the CLI's was fixed. The `install_hook` handler matches `%{kind: :hook}`; its sibling `install`
    # never grew the mirror-image check, so the only thing keeping a hook out of it is the template
    # guard that omits the button — and `handle_event` is client-driven. A raw event (or a stale DOM)
    # reaches it with a hook on screen: `%{name: name, md: md}` matches a hook just as well as a
    # skill, and `md` is a bash script.
    #
    # It also bypasses `hook_eval_gate/1` and lands in `Install.install({name, md})`, whose `opts
    # [:kind] || :skill` reads the script as MARKDOWN — the `##` exemption, the safe-sections
    # carve-out, the `|` filter. Every gate at once, through a button that isn't rendered.
    result =
      [base: "test/fixtures", min_messages: 0]
      |> Faber.Scan.run()
      |> Enum.find(&(&1.hazards != []))

    assert result, "the hazard fixture vanished — this test has lost its subject"

    Store.put(result, %{
      name: "no-masked-gate-exit",
      md: "#!/usr/bin/env bash\nexit 0\n",
      kind: :hook,
      event: "PreToolUse",
      matcher: "Bash",
      adapter: "faber-elixir",
      eval: %{composite: 1.0, passed: true, threshold: 0.9, dimensions: %{}}
    })

    {view, _detail, i} = open_hazard_session(conn)

    # The button is not rendered — which is exactly why this drives the event directly.
    html = render_click(view, "install", %{"agent" => "claude", "i" => to_string(i)})

    refute File.exists?(
             Path.join([Faber.Install.default_dir(), "no-masked-gate-exit", "SKILL.md"])
           ),
           "a raw install event wrote a hook's bash script into the skills dir as a SKILL.md"

    assert html =~ "not a skill", "the refusal must say what was actually refused"
  end

  # S-4. Both handlers had the same two bugs, so they are fixed and tested together: an unparseable
  # `i` fell to a bare `_ -> {:noreply, socket}` (total silence), and the `false ->` clause caught
  # BOTH `allow_install?()` and `idx == proposal_i`, so a stale index blamed a config flag.
  @tag :tmp_dir
  test "a stale or unparseable index is answered, not silently swallowed", %{conn: conn} do
    Store.put(hazard_result(), %{
      name: "no-masked-gate-exit",
      md: "#!/usr/bin/env bash\nexit 0\n",
      kind: :hook,
      event: "PreToolUse",
      matcher: "Bash",
      adapter: "faber-elixir",
      eval: %{composite: 1.0, passed: true, threshold: 0.9, dimensions: %{}}
    })

    {view, _detail, i} = open_hazard_session(conn)

    for {event, params} <- [
          {"install_hook", %{"i" => "not-a-number"}},
          {"install_hook", %{"i" => "#{i + 99}"}},
          {"install", %{"agent" => "claude", "i" => "not-a-number"}},
          {"install", %{"agent" => "claude", "i" => "#{i + 99}"}}
        ] do
      html = render_click(view, event, params)

      # Silence is the worst answer here: the user clicks Install and the page does nothing, which
      # is indistinguishable from a write that worked.
      assert html =~ "no longer the one on screen",
             "#{event} with #{inspect(params)} gave no feedback at all"

      # And it must not blame a config flag the user never touched.
      refute html =~ "web_allow_install",
             "#{event} reported a stale index as an install-disabled error"
    end
  end

  @tag :tmp_dir
  test "an unknown agent is named, not ignored", %{conn: conn} do
    {view, _detail, i} = open_hazard_session(conn)

    view
    |> render_click("propose", %{"i" => to_string(i)})
    |> then(fn _ -> render_async(view, @async_timeout) end)

    html = render_click(view, "install", %{"agent" => "emacs", "i" => to_string(i)})
    assert html =~ "emacs"
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
