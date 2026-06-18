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
    # Scan only on the connected mount — the static (first-paint) render would otherwise scan
    # thousands of transcripts a second time before the websocket even connects.
    if connected?(socket) do
      {:ok, load(socket)}
    else
      {:ok, assign(socket, scanned: false, total: 0, tier2: 0, results: [])}
    end
  end

  @impl true
  def handle_event("rescan", _params, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    results = Scan.run(scan_opts())

    socket
    |> assign(:scanned, true)
    |> assign(:total, length(results))
    |> assign(:tier2, Enum.count(results, & &1.tier2))
    |> assign(:results, Enum.take(results, 25))
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
        tier-2 eligible · showing top {length(@results)}
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
