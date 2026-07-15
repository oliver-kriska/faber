defmodule FaberWeb.DashboardLive do
  @moduledoc """
  The friction dashboard — runs `Faber.Scan` and renders the ranked sessions, with a rescan
  button. Read-only over the filesystem, so no database is involved. The scan options come from
  `config :faber, :dashboard_scan_opts` (tests point it at fixtures for a hermetic render).

  Local-first by design: there is no auth. The rescan event triggers only a read-only scan
  (debounced while one is in flight). The per-row **Propose** button is different — it calls the
  configured `Faber.LLM` and spends tokens — so it is guarded three ways: the endpoint binds
  loopback with `check_origin` pinned to it, the button carries a browser confirm, and
  `config :faber, :web_allow_propose, false` removes it outright (the server rejects the event
  too, not just the UI). The MCP twin `faber_propose_skill` is opt-in in the opposite direction
  (default off): an agent must not spend your tokens silently, a human clicking a button may.
  Add an `on_mount` guard before exposing this endpoint over any network interface.
  """
  use FaberWeb, :live_view

  alias Faber.{Adapter, Eval, Propose, Scan}

  @impl true
  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        scanned: false,
        scanning: false,
        total: 0,
        tier2: 0,
        results: [],
        shown: 0,
        max_raw: 1.0,
        # Which ranked row (1-based) has a proposal in flight, and which row the last result
        # belongs to — so the proposal renders *inline under its own row*, not in a detached panel.
        proposing_i: nil,
        proposal: nil,
        proposal_i: nil,
        allow_propose: allow_propose?()
      )

    # Scan only on the connected mount, and run it asynchronously so the LiveView process stays
    # responsive — `Scan.run` fans out over hundreds of transcripts and would otherwise block the
    # mount, hiding the "scanning…" state. The static (first-paint) render shows the loading state.
    {:ok, if(connected?(socket), do: start_scan(socket), else: socket)}
  end

  # Debounce: ignore rescans while one is already in flight (the button is also disabled).
  @impl true
  def handle_event("rescan", _params, %{assigns: %{scanning: true}} = socket),
    do: {:noreply, socket}

  def handle_event("rescan", _params, socket) do
    # Clear any shown/in-flight proposal: after a rescan the rows change, so an inline card left
    # under "row 1" would belong to a different (or gone) session.
    {:noreply,
     socket
     |> assign(scanned: false, proposing_i: nil, proposal: nil, proposal_i: nil)
     |> start_scan()}
  end

  # Present (not install): propose + eval a skill for one session, async, rendered inline under
  # its row. Debounce: one proposal at a time (the buttons are also disabled while in flight).
  def handle_event("propose", _params, %{assigns: %{proposing_i: p}} = socket)
      when not is_nil(p),
      do: {:noreply, socket}

  def handle_event("propose", %{"i" => i}, socket) do
    # Server-side gate (the UI also hides the button): propose spends LLM tokens, so a client
    # driving raw events must be refused when the flag is off — the hidden button alone is not
    # a boundary. `i` is a client-supplied string — parse defensively so a malformed value
    # can't crash the LiveView process (it would just be ignored).
    with true <- allow_propose?(),
         {idx, ""} <- Integer.parse(i),
         result when not is_nil(result) <- Enum.at(socket.assigns.results, idx - 1) do
      {:noreply,
       socket
       |> assign(proposing_i: idx, proposal: nil, proposal_i: nil)
       |> start_async(:propose, fn -> do_propose(result) end)}
    else
      false ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Propose is disabled — set `config :faber, :web_allow_propose, true`."
         )}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_async(:scan, {:ok, results}, socket) do
    top = Enum.take(results, 25)

    {:noreply,
     socket
     |> assign(:scanned, true)
     |> assign(:scanning, false)
     |> assign(:total, length(results))
     |> assign(:tier2, Enum.count(results, & &1.tier2))
     |> assign(:results, top)
     |> assign(:shown, length(top))
     |> assign(:max_raw, max_raw(top))}
  end

  def handle_async(:scan, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> put_flash(:error, "Scan failed — see server logs.")
     |> assign(
       scanned: true,
       scanning: false,
       total: 0,
       tier2: 0,
       results: [],
       shown: 0,
       max_raw: 1.0
     )}
  end

  def handle_async(:propose, {:ok, data}, socket) do
    {:noreply,
     assign(socket, proposal: data, proposal_i: socket.assigns.proposing_i, proposing_i: nil)}
  end

  def handle_async(:propose, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> put_flash(:error, "Proposal failed — see server logs.")
     |> assign(proposing_i: nil)}
  end

  defp do_propose(result) do
    with {:ok, adapter} <- Adapter.load(Faber.adapter_dir()),
         {:ok, proposal} <- Propose.propose(result, adapter),
         {:ok, eval} <- Eval.score(proposal, adapter: adapter) do
      %{
        name: proposal.name,
        md: Propose.render_skill_md(proposal, adapter),
        composite: eval.composite,
        passed: eval.passed,
        threshold: eval.threshold
      }
    else
      {:error, reason} -> %{error: inspect(reason)}
    end
  end

  defp start_scan(socket) do
    opts = scan_opts()

    socket
    |> assign(:scanning, true)
    |> start_async(:scan, fn -> Scan.run(opts) end)
  end

  # Score ALL sessions (no :limit) so the ranking reflects your true highest-friction sessions —
  # capping here would sample a subset and could hide the worst ones. The scan is async, so the
  # full fan-out doesn't block the LiveView. Tests point this at fixtures via :dashboard_scan_opts.
  defp scan_opts do
    Application.get_env(:faber, :dashboard_scan_opts, min_messages: 4)
  end

  defp allow_propose?, do: Application.get_env(:faber, :web_allow_propose, true) == true

  @impl true
  def render(assigns) do
    ~H"""
    <main class="container">
      <FaberWeb.Layouts.flash_group flash={@flash} />
      <header class="masthead">
        <div>
          <h1><span class="accent">Faber</span> — session friction</h1>
          <p :if={!@scanned} class="summary">scanning sessions…</p>
          <p :if={@scanned} class="summary">
            <strong>{@total}</strong> sessions scanned · <strong>{@tier2}</strong>
            tier-2 eligible · ranked by total friction · showing top {@shown}
          </p>
        </div>
        <button :if={@scanned} class="secondary" phx-click="rescan" disabled={@scanning}>
          {if @scanning, do: "Scanning…", else: "Rescan"}
        </button>
      </header>

      <table :if={@results != []}>
        <thead>
          <tr>
            <th data-tip="Rank — sessions ordered by friction, highest first.">#</th>
            <th
              class="num"
              data-tip="Total weighted friction: retry loops, user corrections, error/tool ratio, approach changes, context compactions, and interrupts. Higher = rougher session; the bar shows it relative to the top row."
            >
              Friction
            </th>
            <th data-tip="The session's working directory, with a short session id.">Project</th>
            <th data-tip="What the work was — feature, bug-fix, refactoring, exploration, maintenance, or review.">
              Type
            </th>
            <th data-tip="The friction signal that contributed the most (e.g. user corrections, retry loops, context compactions).">
              Signal
            </th>
            <th data-tip="Skills that could have helped this session but weren't used — the reason to propose one.">
              Missed
            </th>
            <th class="num" data-tip="Transcript events — every user + assistant line, including the agent's own tool traffic.">
              Events
            </th>
            <th class="num" data-tip="Messages a human actually typed. Far smaller than events: the agent generates most of a transcript itself.">
              Turns
            </th>
            <th class="num" data-tip="Number of tool calls made in the session.">Tools</th>
            <th class="num tip-end" data-tip="Tool calls that returned an error.">Errs</th>
            <th class="num tip-end" data-tip="Peak context-window usage reached. Turns red at ≥ 80%.">
              Ctx
            </th>
            <th
              class="tip-end"
              data-tip="Tier-2 eligible: the session clears the bar to be worth proposing a skill for."
            >
              T2
            </th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <%= for {r, i} <- Enum.with_index(@results, 1) do %>
            <tr class={row_class(i, @proposing_i, @proposal_i)}>
              <td class="muted">{i}</td>
              <td class="num friction" data-friction={fmt(r.raw)} style={bar_style(r.raw, @max_raw)}>
                {fmt(r.raw)}
              </td>
              <td class="muted project" title={r.cwd || r.path}>{project(r)}</td>
              <td>{r.fingerprint}</td>
              <td>{signal(r.dominant_signal)}</td>
              <td class="chips">
                <span :for={m <- r.missed} class="chip">/{m}</span>
                <span :if={r.missed == []} class="muted">—</span>
              </td>
              <td class="num">{r.message_count}</td>
              <td class="num">{r.human_turns}</td>
              <td class="num">{r.tool_count}</td>
              <td class="num">{r.error_count}</td>
              <td class={"num ctx" <> if(hot_ctx?(r.max_ctx_pct), do: " hot", else: "")}>
                {ctx(r.max_ctx_pct)}
              </td>
              <td class="tier2">{if(r.tier2, do: "✓", else: "")}</td>
              <td>
                <button
                  :if={@allow_propose}
                  class="ghost propose-btn"
                  phx-click="propose"
                  phx-value-i={i}
                  disabled={@proposing_i != nil}
                  data-confirm="This calls the configured LLM (claude -p by default) and spends tokens. Continue?"
                >
                  <span :if={@proposing_i == i} class="spinner"></span>
                  {if @proposing_i == i, do: "Proposing…", else: "Propose"}
                </button>
              </td>
            </tr>

            <tr :if={@proposing_i == i} class="expand">
              <td colspan="12">
                <div class="proposing">
                  <span class="spinner"></span>
                  <span>Proposing a skill for <strong>{project(r)}</strong> — this calls the LLM and can take ~a minute.</span>
                </div>
                <div class="progress"><span></span></div>
              </td>
            </tr>

            <tr :if={@proposal_i == i and @proposal != nil} class="expand">
              <td colspan="12">
                <.proposal_card proposal={@proposal} row={i} />
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>

      <p :if={@scanned and @results == []} class="empty">No sessions matched.</p>
    </main>
    """
  end

  # Inline result card, rendered in an expansion row directly under the session it belongs to.
  attr :proposal, :map, required: true
  attr :row, :integer, required: true

  defp proposal_card(assigns) do
    ~H"""
    <p :if={@proposal[:error]} class="proposal-error">Proposal failed: {@proposal.error}</p>
    <div :if={!@proposal[:error]} class="proposal-card">
      <div class="proposal-head">
        <div class="proposal-meta">
          <span class="proposal-name">{@proposal.name}</span>
          <span class={"badge " <> if(@proposal.passed, do: "pass", else: "fail")}>
            {verdict(@proposal)}
          </span>
          <span class="composite">composite {fmt(@proposal.composite)}</span>
        </div>
        <button class="ghost copy-btn" type="button" data-copy={"#skill-#{@row}"}>
          Copy skill
        </button>
      </div>
      <pre id={"skill-#{@row}"} class="skill" title="Click to select all, or use Copy skill"><code>{@proposal.md}</code></pre>
    </div>
    """
  end

  defp verdict(%{passed: true}), do: "PASS"
  defp verdict(%{threshold: t}), do: "below threshold (#{t})"

  defp fmt(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 1)
  defp fmt(n), do: to_string(n)

  defp signal(nil), do: "—"
  defp signal(s), do: s |> to_string() |> String.replace("_", " ")

  defp ctx(nil), do: "—"
  defp ctx(pct) when is_number(pct), do: "#{round(pct)}%"

  defp hot_ctx?(pct) when is_number(pct), do: pct >= 80.0
  defp hot_ctx?(_), do: false

  # Highlight the row whose proposal is in flight or currently shown, so the inline expansion
  # reads as belonging to it.
  defp row_class(i, i, _proposal_i), do: "active"
  defp row_class(i, _proposing_i, i), do: "active"
  defp row_class(_i, _proposing_i, _proposal_i), do: nil

  # Highest friction in the current page → the highest raw seen; other rows get a proportional bar.
  defp max_raw([]), do: 1.0
  defp max_raw(results), do: results |> Enum.map(& &1.raw) |> Enum.max()

  # A heat bar as a CSS gradient background: fill width ∝ friction / page-max. `--w` drives it.
  defp bar_style(raw, max) when is_number(raw) and is_number(max) and max > 0 do
    "--w:#{round(raw / max * 100)}%"
  end

  defp bar_style(_raw, _max), do: "--w:0%"

  # Clean project label from the session's working directory (falls back to the transcript's
  # parent dir when `cwd` is absent — e.g. some fixtures), plus a short session handle.
  defp project(%{cwd: cwd, session_id: sid, path: path}) do
    name =
      if is_binary(cwd) and cwd != "",
        do: Path.basename(cwd),
        else: path |> Path.dirname() |> Path.basename()

    short = if is_binary(sid), do: String.slice(sid, 0, 8), else: Path.basename(path, ".jsonl")
    "#{name}/#{short}"
  end
end
