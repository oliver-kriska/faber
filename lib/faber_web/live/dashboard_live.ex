defmodule FaberWeb.DashboardLive do
  @moduledoc """
  The friction dashboard — runs `Faber.Scan` and renders the ranked sessions, with a rescan
  button. Read-only over the filesystem, so no database is involved. The scan options come from
  `config :faber, :dashboard_scan_opts` (tests point it at fixtures for a hermetic render).
  """
  use FaberWeb, :live_view

  alias Faber.Scan

  @impl true
  def mount(_params, _session, socket) do
    socket = assign(socket, scanned: false, total: 0, tier2: 0, results: [], shown: 0)

    # Scan only on the connected mount, and run it asynchronously so the LiveView process stays
    # responsive — `Scan.run` fans out over hundreds of transcripts and would otherwise block the
    # mount, hiding the "scanning…" state. The static (first-paint) render shows the loading state.
    {:ok, if(connected?(socket), do: start_scan(socket), else: socket)}
  end

  @impl true
  def handle_event("rescan", _params, socket) do
    {:noreply, socket |> assign(:scanned, false) |> start_scan()}
  end

  @impl true
  def handle_async(:scan, {:ok, results}, socket) do
    {:noreply,
     socket
     |> assign(:scanned, true)
     |> assign(:total, length(results))
     |> assign(:tier2, Enum.count(results, & &1.tier2))
     |> assign(:results, Enum.take(results, 25))
     |> assign(:shown, min(25, length(results)))}
  end

  def handle_async(:scan, {:exit, _reason}, socket) do
    {:noreply, assign(socket, scanned: true, total: 0, tier2: 0, results: [], shown: 0)}
  end

  defp start_scan(socket) do
    opts = scan_opts()
    start_async(socket, :scan, fn -> Scan.run(opts) end)
  end

  defp scan_opts do
    Application.get_env(:faber, :dashboard_scan_opts, limit: 400, min_messages: 4)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="container">
      <h1><span class="accent">Faber</span> — session friction</h1>
      <p :if={!@scanned} class="summary">scanning sessions…</p>
      <p :if={@scanned} class="summary">
        <strong>{@total}</strong> sessions scanned · <strong>{@tier2}</strong>
        tier-2 eligible · showing top {@shown}
      </p>
      <button :if={@scanned} phx-click="rescan">Rescan</button>

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
          </tr>
        </tbody>
      </table>

      <p :if={@scanned and @results == []} class="empty">No sessions matched.</p>
    </main>
    """
  end

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
