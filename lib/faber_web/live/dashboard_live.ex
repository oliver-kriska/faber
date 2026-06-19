defmodule FaberWeb.DashboardLive do
  @moduledoc """
  The friction dashboard — runs `Faber.Scan` and renders the ranked sessions, with a rescan
  button. Read-only over the filesystem, so no database is involved. The scan options come from
  `config :faber, :dashboard_scan_opts` (tests point it at fixtures for a hermetic render).

  Local-first by design: there is no auth on the rescan event (it only triggers a read-only
  scan, debounced while one is in flight). Add an `on_mount` guard before exposing this endpoint
  over any network interface.
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
        proposing: false,
        proposal: nil
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
    {:noreply, socket |> assign(:scanned, false) |> start_scan()}
  end

  # Present (not install): propose + eval a skill for one session, async, shown in a panel.
  def handle_event("propose", _params, %{assigns: %{proposing: true}} = socket),
    do: {:noreply, socket}

  def handle_event("propose", %{"i" => i}, socket) do
    # `i` is a client-supplied string — parse defensively so a malformed value can't crash the
    # LiveView process (it would just be ignored).
    with {idx, ""} <- Integer.parse(i),
         result when not is_nil(result) <- Enum.at(socket.assigns.results, idx - 1) do
      {:noreply,
       socket
       |> assign(proposing: true, proposal: nil)
       |> start_async(:propose, fn -> do_propose(result) end)}
    else
      _ -> {:noreply, socket}
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
     |> assign(:shown, length(top))}
  end

  def handle_async(:scan, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> put_flash(:error, "Scan failed — see server logs.")
     |> assign(scanned: true, scanning: false, total: 0, tier2: 0, results: [], shown: 0)}
  end

  def handle_async(:propose, {:ok, data}, socket) do
    {:noreply, assign(socket, proposing: false, proposal: data)}
  end

  def handle_async(:propose, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> put_flash(:error, "Proposal failed — see server logs.")
     |> assign(proposing: false)}
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

  defp scan_opts do
    Application.get_env(:faber, :dashboard_scan_opts, limit: 400, min_messages: 4)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="container">
      <FaberWeb.Layouts.flash_group flash={@flash} />
      <h1><span class="accent">Faber</span> — session friction</h1>
      <p :if={!@scanned} class="summary">scanning sessions…</p>
      <p :if={@scanned} class="summary">
        <strong>{@total}</strong> sessions scanned · <strong>{@tier2}</strong>
        tier-2 eligible · showing top {@shown}
      </p>
      <button :if={@scanned} phx-click="rescan" disabled={@scanning}>Rescan</button>

      <table :if={@results != []}>
        <thead>
          <tr>
            <th>#</th>
            <th>Friction</th>
            <th>Type</th>
            <th>Opp</th>
            <th>Signal</th>
            <th>Msgs</th>
            <th>Tools</th>
            <th>Errs</th>
            <th>T2</th>
            <th>Session</th>
            <th>Skill</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={{r, i} <- Enum.with_index(@results, 1)}>
            <td class="muted">{i}</td>
            <td class="num">{fmt(r.raw)}</td>
            <td>{r.fingerprint}</td>
            <td class="num">{fmt(r.opportunity)}</td>
            <td>{signal(r.dominant_signal)}</td>
            <td class="num">{r.message_count}</td>
            <td class="num">{r.tool_count}</td>
            <td class="num">{r.error_count}</td>
            <td class="tier2">{if(r.tier2, do: "✓", else: "")}</td>
            <td class="muted">{session(r)}</td>
            <td>
              <button phx-click="propose" phx-value-i={i} disabled={@proposing}>Propose</button>
            </td>
          </tr>
        </tbody>
      </table>

      <p :if={@scanned and @results == []} class="empty">No sessions matched.</p>

      <section :if={@proposing} class="panel">Proposing a skill…</section>

      <section :if={@proposal} class="panel">
        <p :if={@proposal[:error]} class="empty">Proposal failed: {@proposal.error}</p>
        <div :if={!@proposal[:error]}>
          <h2>
            {@proposal.name} — composite {fmt(@proposal.composite)}
            <span class="tier2">{verdict(@proposal)}</span>
          </h2>
          <pre class="skill">{@proposal.md}</pre>
        </div>
      </section>
    </main>
    """
  end

  defp verdict(%{passed: true}), do: "PASS"
  defp verdict(%{threshold: t}), do: "below threshold (#{t})"

  defp fmt(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 1)
  defp fmt(n), do: to_string(n)

  defp signal(nil), do: "—"
  defp signal(s), do: to_string(s)

  defp session(%{path: path, session_id: sid}) do
    project = path |> Path.dirname() |> Path.basename()
    short = if is_binary(sid), do: String.slice(sid, 0, 8), else: Path.basename(path, ".jsonl")
    "#{project}/#{short}"
  end
end
