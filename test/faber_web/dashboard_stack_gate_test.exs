defmodule FaberWeb.DashboardStackGateTest do
  # async: false — scopes :dashboard_scan_opts to the non-Elixir fixture so rank 1 IS the
  # wrong-stack session, and swaps in a counting :llm. Both are application env. Restored on exit.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Faber.{Adapter, Propose, Scan}

  @endpoint FaberWeb.Endpoint

  # See FaberWeb.DashboardLiveTest — 100ms is too tight for the real scan on a loaded runner.
  @async_timeout 2_000

  # Reports being called, so "the gate spent nothing" is asserted as a fact rather than inferred
  # from the absence of a loading state. A call here would be a real (paid) LLM call in
  # production. The dashboard must never reach it for a wrong-stack session.
  #
  # Messages the test process rather than holding a count in an Agent: `do_propose/1` runs in a
  # `start_async` task, so the tick has to cross processes either way — and an unsupervised Agent
  # for a counter would be a long-lived process outside a supervision tree (Iron Law #14).
  defmodule ReportingLLM do
    @behaviour Faber.LLM

    @impl Faber.LLM
    def generate_object(_prompt, _schema, _opts) do
      send(Application.get_env(:faber, :test_pid), :llm_called)
      {:error, :should_never_be_called}
    end
  end

  setup do
    prev_scan = Application.get_env(:faber, :dashboard_scan_opts)
    # nonelixir/js_session.jsonl — a Next.js session (page.tsx), the same fixture the CLI's gate
    # test uses. Scoping the scan here makes rank 1 deterministic.
    Application.put_env(:faber, :dashboard_scan_opts,
      base: "test/fixtures/nonelixir",
      min_messages: 0
    )

    on_exit(fn -> Application.put_env(:faber, :dashboard_scan_opts, prev_scan) end)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  # The premise the whole gate rests on: this fixture really is outside faber-elixir's stack. If
  # the fixture ever drifted into matching, every assertion below would pass vacuously.
  test "the fixture session is genuinely a stack mismatch" do
    {:ok, adapter} = Adapter.load(Faber.adapter_dir())
    [result | _] = Scan.run(base: "test/fixtures/nonelixir", min_messages: 0)

    refute Propose.stack_match?(adapter, result)
    assert {:error, {:stack_mismatch, ^adapter, ^result}} = Propose.stack_gate(adapter, result)

    # ...and the refusal can cite what it actually touched. Asserted as membership, not on the
    # head: the fixture touches .tsx and .jsx once each, so which one sorts first is a tie-break,
    # not a fact worth pinning a test to.
    exts = result |> Propose.touched_extensions() |> Enum.map(&elem(&1, 0))
    assert ".tsx" in exts
    refute ".ex" in exts
    refute ".exs" in exts
  end

  test "a wrong-stack row is marked in the ranked table", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    html = render_async(view, @async_timeout)

    # Marked in the table, so the mismatch is visible before the click — not discovered by
    # spending tokens and reading the wrong stack in the output.
    assert html =~ ~s(class="row-stack")
    assert html =~ "wrong stack"
    assert html =~ "Wrong stack — cannot propose"
  end

  test "the hero explains the refusal instead of offering a Propose button", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    html = render_async(view, @async_timeout)

    # The hero's CTA proposes for rank 1. When rank 1 is the wrong stack the button must be gone,
    # replaced by why — the friction is real, only the stack framing would be wrong.
    refute html =~ ~s(phx-click="propose" phx-value-i="1")
    assert html =~ "faber-elixir"
    assert html =~ "describe the wrong language"
  end

  test "the open detail pane refuses with evidence, not a Propose button", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    render_async(view, @async_timeout)

    html = render_click(view, "select", %{"i" => "1"})

    refute html =~ ~s(class="propose-btn")
    assert html =~ ~s(class="badge mismatch")
    # The refusal carries its evidence: what the session touched, and what the adapter targets.
    assert html =~ "Wrong stack for faber-elixir"
    assert html =~ ".tsx"
    assert html =~ "mix.exs"
  end

  test "the raw propose event is refused server-side and spends nothing", %{conn: conn} do
    prev_llm = Application.get_env(:faber, :llm)
    Application.put_env(:faber, :llm, ReportingLLM)
    Application.put_env(:faber, :test_pid, self())

    # Asymmetric on purpose: `:llm` has a real configured default to put back, while `:test_pid` is
    # ours alone and has no prior value — `put_env(nil)` would leave it *set* to nil, which is not
    # the same as unset. Don't "tidy" these into the same shape.
    on_exit(fn ->
      Application.put_env(:faber, :llm, prev_llm)
      Application.delete_env(:faber, :test_pid)
    end)

    {:ok, view, _html} = live(conn, "/")
    render_async(view, @async_timeout)

    # A client driving the raw event bypasses the hidden button — the hidden button is not a
    # boundary. The gate is, and it answers before any async work starts.
    html = render_click(view, "propose", %{"i" => "1"})

    assert html =~ "Wrong stack for faber-elixir"
    refute html =~ "Proposing a skill"
    refute render(view) =~ ~s(class="progress")

    # The point of gating before start_async: a wrong-stack click costs zero LLM calls. This is
    # what the dashboard used to get wrong — it drafted a Phoenix skill from a Go session, and an
    # equally adapter-scoped eval then graded it PASS.
    #
    # The timeout is load-bearing — do NOT swap this for a bare `refute_received`. It looks
    # redundant (the gate is synchronous, so render_click has already returned by now), but that
    # reasoning only holds while the gate is *present*, which is the one thing this test exists to
    # doubt. Without the gate the call happens in a start_async task a few ms later, so
    # `refute_received` inspects an empty mailbox and passes — measured: it passes against a
    # deliberately un-gated dashboard, while this line fails it with "Unexpectedly received
    # message :llm_called". The 200ms is what makes the assertion bite.
    refute_receive :llm_called, 200
  end

  # THE CONTROL. Everything above asserts the gate *refuses* — and would all still pass if
  # `matches_session?/2` returned false for every session on earth, i.e. if Propose were dead
  # dashboard-wide and Faber shipped a button that never works. This is the only test that fails
  # in that world. Same gate, same mechanism, a session that DOES match.
  test "a matching-stack session is untouched by the gate", %{conn: conn} do
    # test/fixtures ranks the Elixir session (sample_session.jsonl) first, and also contains the
    # nonelixir/ fixture — so one scan shows both verdicts, which is the discrimination itself.
    Application.put_env(:faber, :dashboard_scan_opts, base: "test/fixtures", min_messages: 0)

    {:ok, view, _html} = live(conn, "/")
    html = render_async(view, @async_timeout)

    # Rank 1 matches: the hero keeps its Propose CTA and says nothing about stacks.
    assert html =~ ~s(phx-click="propose" phx-value-i="1")
    refute html =~ "Wrong stack for faber-elixir"

    # ...while the wrong-stack row in the SAME table is still marked. Both states at once: the
    # gate discriminates rather than blanket-refusing.
    assert html =~ ~s(class="row-stack")

    # And the matching session's detail pane offers the button, not the refusal.
    detail = render_click(view, "select", %{"i" => "1"})
    assert detail =~ ~s(class="propose-btn")
    refute detail =~ ~s(class="badge mismatch")
  end

  # The `stack_ok?(nil, _) -> true` / `gate_stack(nil, _) -> :ok` branch: when the pack itself
  # can't be read we cannot know a session's stack, so the UI must not accuse every row of being
  # wrong. That leniency is cosmetic ONLY — `do_propose/1` re-loads the adapter independently, and
  # that is where an unreadable pack stops the spend. This test pins both halves of that split.
  test "an unloadable adapter marks nothing, but still spends nothing", %{conn: conn} do
    prev_dir = Application.get_env(:faber, :adapter_dir)
    prev_llm = Application.get_env(:faber, :llm)
    Application.put_env(:faber, :adapter_dir, "/nonexistent/faber-adapter")
    Application.put_env(:faber, :llm, ReportingLLM)
    Application.put_env(:faber, :test_pid, self())

    on_exit(fn ->
      if prev_dir,
        do: Application.put_env(:faber, :adapter_dir, prev_dir),
        else: Application.delete_env(:faber, :adapter_dir)

      Application.put_env(:faber, :llm, prev_llm)
      Application.delete_env(:faber, :test_pid)
    end)

    {:ok, view, _html} = live(conn, "/")
    html = render_async(view, @async_timeout)

    # Fails open, visibly: no accusation we can't substantiate, even though this session really is
    # the wrong stack — we just can't prove it without the globs.
    refute html =~ ~s(class="row-stack")
    refute html =~ "Wrong stack for"
    assert html =~ ~s(phx-click="propose" phx-value-i="1")

    # Fails closed where it costs money: the click gets through the cosmetic gate and is stopped by
    # do_propose/1's own Adapter.load, before the LLM.
    render_click(view, "propose", %{"i" => "1"})
    render_async(view, @async_timeout)
    refute_receive :llm_called, 200
  end
end
