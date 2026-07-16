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

  require Logger

  alias Faber.{Adapter, Eval, Propose, Scan}
  alias Faber.Proposal.Store

  # How many ranked rows the table shows before "Show more". We keep the *full* scan
  # (`all_results`) so filters run across every session, then take a cap-sized slice of the filtered
  # set for display, raising the limit a cap at a time on demand. Runtime-configurable (like
  # `dashboard_scan_opts`) so a huge corpus can page bigger and tests can shrink it — see
  # `display_cap/0`.
  @default_display_cap 25

  @impl true
  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        scanned: false,
        scanning: false,
        total: 0,
        tier2: 0,
        # The full ranked scan, and the filtered+capped slice that actually renders. `results` is
        # what select/propose/install index into (1-based); `all_results` is the filter source.
        all_results: [],
        results: [],
        shown: 0,
        match_count: 0,
        # How many of the filtered set to render. Starts at the cap; "Show more" raises it by a cap
        # at a time. Reset to the cap whenever the scope changes (a filter pick or a fresh scan).
        display_limit: display_cap(),
        max_raw: 1.0,
        # Facet filters over the table. nil = "All". Distinct option lists come from `all_results`.
        filters: default_filters(),
        filter_options: %{projects: [], types: [], signals: []},
        # The ranked session open in the detail pane (1-based), or nil for the overview table. The
        # default is nil: land on the full table, drill into one session on click. This drives the
        # overview→detail collapse (the table shrinks to a sidebar, the pane reveals).
        selected_i: nil,
        # Which session (1-based) has a proposal in flight, and which one the last result belongs
        # to — the detail pane shows them only when they match `selected_i`.
        proposing_i: nil,
        proposal: nil,
        proposal_i: nil,
        # The last install result (%{i, agent, msg}) so the detail pane can confirm it inline.
        installed: nil,
        # `session_id => %{name, path}` for every Faber-installed skill that recorded its source
        # session. Read from disk (the `.faber.json` markers), so an install survives a browser
        # refresh: reopening that session shows "installed" even though the assigns above are gone.
        installed_sessions: %{},
        allow_propose: allow_propose?(),
        allow_install: allow_install?(),
        # Onboarding context for the empty state: where we looked and the message floor, so a
        # first-run user with nothing to rank is told what to do next rather than a bare "none".
        # `scan_error?` separates a genuinely empty scan (teach) from a crashed one (retry).
        scan_location: scan_location(scan_opts()),
        scan_min: Keyword.get(scan_opts(), :min_messages, 4),
        scan_error?: false
      )

    # Scan only on the connected mount, and run it asynchronously so the LiveView process stays
    # responsive — `Scan.run` fans out over hundreds of transcripts and would otherwise block the
    # mount, hiding the "scanning…" state. The static (first-paint) render shows the loading state.
    # The installed-skills map is a cheap disk read; load it once on connect (refreshed after each
    # install), so the persistent "installed" markers are present as soon as the table renders.
    socket =
      if connected?(socket),
        do: socket |> assign(:installed_sessions, load_installed_sessions()) |> start_scan(),
        else: socket

    {:ok, socket}
  end

  # Debounce: ignore rescans while one is already in flight (the button is also disabled).
  @impl true
  def handle_event("rescan", _params, %{assigns: %{scanning: true}} = socket),
    do: {:noreply, socket}

  def handle_event("rescan", _params, socket) do
    # Clear any selection/proposal/install: after a rescan the rows change, so anything pinned to
    # "session 1" would belong to a different (or gone) session.
    {:noreply,
     socket
     |> assign(
       scanned: false,
       selected_i: nil,
       proposing_i: nil,
       proposal: nil,
       proposal_i: nil,
       installed: nil,
       filters: default_filters()
     )
     |> start_scan()}
  end

  # Close the detail pane, back to the overview table.
  def handle_event("deselect", _params, socket), do: {:noreply, assign(socket, :selected_i, nil)}

  # Facet filters (project / type / signal), picked from the custom combo dropdowns. The chosen
  # value rides in on `phx-value-choice` (NOT `phx-value-value`: on a <button>, LiveView's client
  # overwrites the reserved `value` key with the element's own empty `.value`, so a `value`-named
  # facet payload always arrived blank — see `filter_combo/1`). Blank string means "All". Any
  # change re-scopes the table, so drop the current selection and proposal (their 1-based indices
  # point into the old row set).
  def handle_event("pick_filter", %{"facet" => facet, "choice" => value}, socket)
      when facet in ["project", "type", "signal"] do
    filters = Map.put(socket.assigns.filters, String.to_existing_atom(facet), blank_to_nil(value))
    {:noreply, socket |> assign(:filters, filters) |> reset_selection() |> apply_view()}
  end

  def handle_event("pick_filter", _params, socket), do: {:noreply, socket}

  def handle_event("clear_filters", _params, socket) do
    {:noreply, socket |> assign(:filters, default_filters()) |> reset_selection() |> apply_view()}
  end

  # "Show more": reveal the next cap-sized slice of the current (filtered) set. The button only
  # renders while `@shown < @match_count`, so no upper clamp is needed here — apply_view's
  # `Enum.take` naturally stops at the end of the set once the limit outgrows it.
  def handle_event("show_more", _params, socket) do
    {:noreply,
     socket
     |> assign(:display_limit, socket.assigns.display_limit + display_cap())
     |> apply_view()}
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
       |> assign(
         selected_i: idx,
         proposing_i: idx,
         proposal: nil,
         proposal_i: nil,
         installed: nil
       )
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

  # Abort an in-flight paid Propose. `cancel_async` kills the task (closing the `claude -p` port with
  # it, which may stop the model mid-generation and save the tail tokens — best-effort, not
  # guaranteed) and discards its result, so no `handle_async` fires. We clear `proposing_i` ourselves.
  # A no-op if nothing is proposing (a stale click after it already resolved).
  def handle_event("cancel_propose", _params, %{assigns: %{proposing_i: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("cancel_propose", _params, socket) do
    {:noreply,
     socket
     |> cancel_async(:propose)
     |> assign(:proposing_i, nil)
     |> put_flash(:info, "Propose cancelled — no skill was drafted.")}
  end

  # Write the shown proposal's SKILL.md into the chosen agent's world (skills dir + managed pointer).
  # Gated like Propose (a raw client can't drive it with the flag off) and only ever installs the
  # proposal currently on screen for the selected session — never a stale or mismatched one.
  def handle_event("install", %{"agent" => agent, "i" => i} = params, socket) do
    proposal = socket.assigns.proposal

    # `force` (from the Reinstall affordance) overwrites an existing skill on disk. It's a separate,
    # explicitly-confirmed action — a plain Install never clobbers, so a stale skill isn't replaced
    # by accident.
    force = params["force"] == "true"

    with true <- allow_install?(),
         {idx, ""} <- Integer.parse(i),
         true <- idx == socket.assigns.proposal_i,
         %{name: name, md: md} <- proposal,
         false <- Map.has_key?(proposal, :error),
         true <- Map.has_key?(Faber.Install.agent_context_files(), agent) do
      # Stamp which session this skill came from (idx == proposal_i, so the row is valid) so the
      # "installed" marker can be recovered from disk after a refresh.
      session = Enum.at(socket.assigns.results, idx - 1)

      case do_install(name, md, agent, session && session.session_id, force) do
        {:ok, msg} ->
          {:noreply,
           socket
           |> assign(:installed, %{i: idx, agent: agent, msg: msg})
           |> assign(:installed_sessions, load_installed_sessions())
           |> put_flash(:info, msg)}

        {:error, msg} ->
          {:noreply, put_flash(socket, :error, msg)}
      end
    else
      false ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Install is disabled — set `config :faber, :web_allow_install, true`."
         )}

      _ ->
        {:noreply, socket}
    end
  end

  # Open a session in the detail pane. `i` is client-supplied — parse defensively and bounds-check
  # against the current results so a stray value can't select past the list (and crash the detail
  # render on a nil session).
  def handle_event("select", %{"i" => i}, socket) do
    n = length(socket.assigns.results)

    case Integer.parse(i) do
      {idx, ""} when idx >= 1 and idx <= n -> {:noreply, select_session(socket, idx)}
      _ -> {:noreply, socket}
    end
  end

  # Keyboard navigation. In the detail view: ↑/k and ↓/j move the selection (clamped), Escape
  # returns to the overview table. In the overview: ↓/j opens the top session. No-op with no
  # results, or for keys we don't handle (so normal typing/shortcuts pass through).
  def handle_event("nav", %{"key" => key}, %{assigns: %{results: results}} = socket)
      when results != [] do
    # Arrowing onto a session goes through the same path as clicking it, so a stored proposal comes
    # back either way — otherwise the same session would show a paid proposal or not depending on
    # how you reached it.
    #
    # The unchanged case has to short-circuit: this is a `phx-window-keydown`, so it fires on every
    # keystroke, and unhandled keys resolve to the current selection. Falling through to
    # `select_session/2` would re-read the store from disk on every key the user presses.
    sel = socket.assigns.selected_i

    case nav_target(sel, key, length(results)) do
      ^sel -> {:noreply, socket}
      nil -> {:noreply, assign(socket, :selected_i, nil)}
      idx -> {:noreply, select_session(socket, idx)}
    end
  end

  def handle_event("nav", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:scan, {:ok, results}, socket) do
    {:noreply,
     socket
     |> assign(:scanned, true)
     |> assign(:scanning, false)
     |> assign(:scan_error?, false)
     |> assign(:total, length(results))
     |> assign(:tier2, Enum.count(results, & &1.tier2))
     |> assign(:all_results, results)
     |> assign(:filter_options, filter_options(results))
     # A fresh scan starts unfiltered and on the overview table (no session open).
     |> assign(:filters, default_filters())
     |> assign(:selected_i, nil)
     |> assign(:display_limit, display_cap())
     |> apply_view()}
  end

  def handle_async(:scan, {:exit, reason}, socket) do
    Logger.error("dashboard scan crashed: #{inspect(reason)}")

    {:noreply,
     socket
     |> put_flash(
       :error,
       "Couldn't scan your sessions. #{humanize_error(reason)} Use Rescan to try again."
     )
     |> assign(
       scanned: true,
       scanning: false,
       scan_error?: true,
       total: 0,
       tier2: 0,
       all_results: [],
       results: [],
       shown: 0,
       match_count: 0,
       max_raw: 1.0,
       filters: default_filters(),
       filter_options: %{projects: [], types: [], signals: []},
       selected_i: nil
     )}
  end

  def handle_async(:propose, {:ok, data}, socket) do
    {:noreply,
     assign(socket, proposal: data, proposal_i: socket.assigns.proposing_i, proposing_i: nil)}
  end

  def handle_async(:propose, {:exit, reason}, socket) do
    Logger.error("dashboard propose crashed: #{inspect(reason)}")

    {:noreply,
     socket
     |> put_flash(
       :error,
       "Couldn't draft a skill. #{humanize_error(reason)} The Propose button is ready to try again."
     )
     |> assign(proposing_i: nil)}
  end

  defp do_propose(result) do
    with {:ok, adapter} <- Adapter.load(Faber.adapter_dir()),
         {:ok, proposal} <- Propose.propose(result, adapter),
         {:ok, eval} <- Eval.score(proposal, adapter: adapter) do
      md = Propose.render_skill_md(proposal, adapter)
      scores = %{composite: eval.composite, passed: eval.passed, threshold: eval.threshold}

      # Persist before handing it to the LiveView. This artifact cost LLM tokens, and until it is
      # on disk it exists only in one process's assigns — a browser refresh would destroy it and
      # the only way back would be paying again. Best-effort: a store failure is logged there and
      # must not deny the user the proposal they already bought.
      # Store the WHOLE eval, not just the three scores the view happens to render: `:engine` is
      # what separates the adapter's stack-specific verdict from a `native:fallback` that only
      # certifies generic markdown structure, and a reader of this artifact must not have to guess
      # which one it is holding. (The store round-trips every eval key as of format 2.)
      Store.put(result, %{name: proposal.name, md: md, eval: eval, adapter: adapter.name})

      Map.merge(scores, %{name: proposal.name, md: md})
    else
      {:error, reason} ->
        Logger.error("dashboard propose failed: #{inspect(reason)}")
        %{error: humanize_error(reason)}
    end
  end

  # Turn an internal error term into one plain sentence for the UI. The raw term is logged (above),
  # never shown — a dashboard user gets a cause they can act on, not an Elixir `inspect`. Converges
  # with the CLI's error humanizer later; kept dashboard-local for now.
  defp humanize_error(msg) when is_binary(msg), do: msg
  defp humanize_error(:timeout), do: "It ran too long and was stopped."
  defp humanize_error(:killed), do: "The task was stopped before it finished."
  defp humanize_error({:shutdown, _}), do: "The task was shut down before it finished."
  defp humanize_error({:exit, inner}), do: humanize_error(inner)

  defp humanize_error({exception, stack}) when is_exception(exception) and is_list(stack),
    do: Exception.message(exception)

  defp humanize_error(exception) when is_exception(exception), do: Exception.message(exception)
  defp humanize_error(_reason), do: "An unexpected error stopped it."

  # Which row a keypress moves to: `nil` closes the pane, an integer opens that rank (1-based,
  # clamped to the row count). Split out of the handler so the navigation table stays readable on
  # its own — it is the part that actually earns scrutiny.
  defp nav_target(sel, key, n)
  defp nav_target(nil, key, _n) when key in ["ArrowDown", "j"], do: 1
  defp nav_target(nil, _key, _n), do: nil
  defp nav_target(_sel, "Escape", _n), do: nil
  defp nav_target(i, key, n) when is_integer(i) and key in ["ArrowDown", "j"], do: min(i + 1, n)
  defp nav_target(i, key, _n) when is_integer(i) and key in ["ArrowUp", "k"], do: max(i - 1, 1)
  defp nav_target(i, _key, _n), do: i

  # Open a session, bringing back any proposal already stored for it. This is the read side of the
  # refresh fix: the proposal outlives this process, so landing on a session shows what was already
  # bought rather than a Propose button that would buy it a second time.
  #
  # Only ever *adds* a proposal — never clears one. If the store has nothing (or its write failed),
  # whatever is in assigns stands; `proposal_i` is what gates the render, so a proposal belonging
  # to another session stays invisible rather than being wrongly attached to this one.
  defp select_session(socket, idx) do
    with result when not is_nil(result) <- Enum.at(socket.assigns.results, idx - 1),
         restored when not is_nil(restored) <- restore_proposal(result) do
      assign(socket, selected_i: idx, proposal: restored, proposal_i: idx, installed: nil)
    else
      _ -> assign(socket, :selected_i, idx)
    end
  end

  # Rebuild the render shape from a stored proposal, so reopening a session shows what was already
  # paid for instead of an empty pane with a Propose button that would charge for it twice.
  defp restore_proposal(result) do
    case Store.latest(result) do
      nil ->
        nil

      record ->
        %{
          name: record.name,
          md: record.md,
          composite: record.eval[:composite],
          passed: record.eval[:passed],
          threshold: record.eval[:threshold],
          # Distinguishes "restored from disk" from "just generated" for the UI, and carries
          # whether the session has moved on since — reported, never a reason to hide it.
          restored: true,
          stale: Store.stale?(record, result)
        }
    end
  end

  defp start_scan(socket) do
    opts = scan_opts()

    socket
    |> assign(:scanning, true)
    |> assign(:scan_error?, false)
    |> start_async(:scan, fn -> Scan.run(opts) end)
  end

  # ── Filtering ────────────────────────────────────────────────────────────────
  defp default_filters, do: %{project: nil, type: nil, signal: nil}

  # Recompute the rendered slice from the full scan + current filters. `match_count` is the total
  # matching the filters; `results`/`shown` are the displayed (capped) slice; `max_raw` scales the
  # heat bars to the visible top row.
  defp apply_view(socket) do
    matching = filter_results(socket.assigns.all_results, socket.assigns.filters)
    shown = Enum.take(matching, socket.assigns.display_limit)

    socket
    |> assign(:results, shown)
    |> assign(:shown, length(shown))
    |> assign(:match_count, length(matching))
    |> assign(:max_raw, max_raw(shown))
  end

  defp filter_results(results, filters) do
    Enum.filter(results, fn r ->
      (is_nil(filters.project) or project_name(r) == filters.project) and
        (is_nil(filters.type) or to_string(r.fingerprint) == filters.type) and
        (is_nil(filters.signal) or to_string(r.dominant_signal) == filters.signal)
    end)
  end

  # Distinct, sorted facet values from the full scan — the option lists for each filter select.
  defp filter_options(results) do
    %{
      projects: results |> Enum.map(&project_name/1) |> distinct_sorted(),
      types: results |> Enum.map(&to_string(&1.fingerprint)) |> distinct_sorted(),
      signals:
        results
        |> Enum.reject(&is_nil(&1.dominant_signal))
        |> Enum.map(&to_string(&1.dominant_signal))
        |> distinct_sorted()
    }
  end

  defp distinct_sorted(values) do
    values |> Enum.reject(&(&1 in [nil, ""])) |> Enum.uniq() |> Enum.sort()
  end

  defp active_filters?(%{project: p, type: t, signal: s}), do: p != nil or t != nil or s != nil

  # Selection/proposal indices are positional in the *displayed* rows; re-scoping the table
  # invalidates them, so drop them together.
  defp reset_selection(socket) do
    assign(socket,
      selected_i: nil,
      proposing_i: nil,
      proposal: nil,
      proposal_i: nil,
      installed: nil,
      # A scope change (this runs on every filter pick/clear) starts over at the top of the new set.
      display_limit: display_cap()
    )
  end

  # The row cap, runtime-configurable so a large corpus can page bigger and tests can shrink it to
  # exercise the "Show more" reveal against a small fixture set. Mirrors `scan_opts/0`.
  defp display_cap, do: Application.get_env(:faber, :dashboard_display_cap, @default_display_cap)

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(value) when is_binary(value), do: value

  # Score ALL sessions (no :limit) so the ranking reflects your true highest-friction sessions —
  # capping here would sample a subset and could hide the worst ones. The scan is async, so the
  # full fan-out doesn't block the LiveView. Tests point this at fixtures via :dashboard_scan_opts.
  defp scan_opts do
    Application.get_env(:faber, :dashboard_scan_opts, min_messages: 4)
  end

  # A human-readable path for the empty state's "we looked here" line. An explicit `:base` wins;
  # otherwise, for the default file source, it is the resolved agent format's default transcript
  # root (e.g. `~/.claude/projects`). A non-file source (ccrider) has no single path — stay generic.
  defp scan_location(opts) do
    cond do
      opts[:base] ->
        opts[:base]

      (opts[:source] || Application.get_env(:faber, :ingest_source, :files)) == :files ->
        Faber.Ingest.Format.resolve(opts).default_base()

      true ->
        "your configured session source"
    end
  end

  defp allow_propose?, do: Application.get_env(:faber, :web_allow_propose, true) == true
  defp allow_install?, do: Application.get_env(:faber, :web_allow_install, true) == true

  # Install targets = the agents Faber knows a shared-context file for (claude, codex), mapped to
  # display labels. Derived from `Faber.Install` so adding an agent there flows through here.
  defp agents do
    labels = %{"claude" => "Claude Code", "codex" => "Codex"}

    Faber.Install.agent_context_files()
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map(fn key -> {key, Map.get(labels, key, key)} end)
  end

  # Map of `session_id => %{name, path}` for every Faber-installed skill whose provenance marker
  # recorded a source session. Read straight off disk so the "installed" state survives a browser
  # refresh (which wipes the LiveView's assigns). `Map.put_new` keeps the first (name-sorted) skill
  # when two came from the same session — the marker is best-effort provenance, not a unique key.
  defp load_installed_sessions do
    Faber.Install.list_faber_installed()
    |> Enum.reduce(%{}, fn %{name: name, path: path}, acc ->
      case Faber.Install.provenance(path) do
        %{"source_session" => sid} when is_binary(sid) ->
          Map.put_new(acc, sid, %{name: name, path: path})

        _ ->
          acc
      end
    end)
  end

  # The Faber skill installed for this session (from disk provenance), or nil. Keyed by session_id,
  # so a transcript that carries no id reads as not-installed rather than matching by accident.
  defp installed_skill(%{session_id: sid}, installed) when is_binary(sid),
    do: Map.get(installed, sid)

  defp installed_skill(_session, _installed), do: nil

  # Stamp the source session into the provenance marker so `load_installed_sessions/0` can recover
  # the "installed" state after a refresh. Omitted when the session has no id — nothing to match on.
  defp install_provenance(sid) when is_binary(sid), do: [provenance: %{"source_session" => sid}]
  defp install_provenance(_sid), do: []

  # Install options: provenance (always, when there's a session id) plus `force` only for an explicit
  # Reinstall. A reinstall force-overwrites AND re-stamps the marker, so an older skill installed
  # before provenance existed picks up its `source_session` on the next reinstall.
  defp install_opts(session_id, force) do
    install_provenance(session_id) ++ if(force, do: [force: true], else: [])
  end

  # Whether a skill by this name already sits on disk (from any session). Drives the Install⇄Reinstall
  # label + the force flag: reinstalling clobbers, so it's only offered when there's something there.
  defp skill_installed?(name) when is_binary(name) do
    [Faber.Install.default_dir(), name, "SKILL.md"] |> Path.join() |> File.exists?()
  end

  defp skill_installed?(_name), do: false

  defp install_confirm(true, name, label) do
    "Reinstall “#{name}” for #{label}? This OVERWRITES the existing skill in your " <>
      "~/.claude/skills and updates the #{label} context file."
  end

  defp install_confirm(false, name, label) do
    "Install “#{name}” for #{label}? This writes a SKILL.md into your " <>
      "~/.claude/skills and updates the #{label} context file."
  end

  # Write the skill + sync the chosen agent's pointer. A plain install never force-overwrites (the
  # user's dir is shared, so `{:exists, _}` reports rather than clobbers); a Reinstall passes
  # `force: true` to replace it deliberately.
  defp do_install(name, md, agent, session_id, force) do
    case Faber.Install.install({name, md}, install_opts(session_id, force)) do
      {:ok, path} ->
        pointer =
          case Faber.Install.sync_pointer(agent) do
            {:ok, :written} -> " · pointer added to #{agent}"
            {:ok, :unchanged} -> ""
            _ -> " · pointer not updated"
          end

        {:ok,
         "#{if force, do: "Reinstalled", else: "Installed"} #{name} → #{shorten(path)}#{pointer}"}

      {:error, reason} ->
        {:error, install_error(name, reason)}
    end
  end

  defp install_error(name, {:exists, path}),
    do: "#{name} already installed at #{shorten(path)} — use Reinstall to overwrite"

  # This path gated on nothing before the veto moved into `Install.install/2` — the dashboard would
  # happily write a skill the eval had refused. Now it cannot, and this only has to say so.
  # Deliberately does not suggest Reinstall: `force` is not a safety override.
  defp install_error(name, {:vetoed, vetoes}),
    do:
      "REFUSED — #{name} was not installed: " <>
        Enum.map_join(vetoes, "; ", & &1.evidence) <> " (safety refusal, not a score)"

  defp install_error(_name, {:invalid_name, n}), do: "Invalid skill name: #{n}"
  defp install_error(_name, reason), do: "Install failed: #{inspect(reason)}"

  # Collapse the home prefix to ~ so install paths read cleanly in the flash/confirmation.
  defp shorten(path) do
    home = System.user_home() || ""

    if home != "" and String.starts_with?(path, home),
      do: "~" <> String.slice(path, String.length(home)..-1//1),
      else: path
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="container">
      <FaberWeb.Layouts.flash_group flash={@flash} />
      <header class="masthead">
        <%!-- aria-live so the "scanning sessions…" → "N sessions scanned" swap is announced to a
              screen reader (the skeleton below is decorative and silent). Not atomic: only the
              changed summary line is read, not the unchanging title. --%>
        <div class="masthead-title" aria-live="polite">
          <h1><span class="accent">Faber</span> — session friction</h1>
          <p :if={!@scanned} class="summary">scanning sessions…</p>
          <p :if={@scanned} class="summary">
            <strong>{@total}</strong> sessions scanned · <strong>{@tier2}</strong>
            tier-2 eligible · ranked by
            <span tabindex="0" aria-label={"Total friction — #{friction_tip()}"} data-tip={friction_tip()}>total friction <span class="q" aria-hidden="true">?</span></span>
          </p>
        </div>
        <div class="masthead-actions">
          <button :if={@scanned and @selected_i} class="secondary" phx-click="deselect">
            ← All sessions
          </button>
          <button :if={@scanned} class="secondary" phx-click="rescan" disabled={@scanning}>
            {if @scanning, do: "Scanning…", else: "Rescan"}
          </button>
          <%!-- Theme toggle handled client-side (app.js) on <html data-theme>, so it's instant and
                survives LiveView patches. Static glyph — the state lives on the document, not here. --%>
          <button
            class="secondary theme-toggle"
            type="button"
            data-theme-toggle
            title="Toggle light / dark theme"
            aria-label="Toggle light / dark theme"
          >
            ◐
          </button>
        </div>
      </header>

      <%!-- Facet filters as custom combos (open/close + search handled client-side in app.js;
            picking a value is a LiveView event). The count reflects the active scope, with a
            Clear when any facet is set. --%>
      <div :if={@scanned and @all_results != []} class="filters">
        <div class="filter-field">
          <span class="filter-label">Project</span>
          <.filter_combo
            facet="project"
            value={@filters.project}
            value_label={@filters.project || "All projects"}
            label_plural="projects"
            search_label="projects"
            options={Enum.map(@filter_options.projects, &{&1, &1})}
            searchable
          />
        </div>
        <div class="filter-field">
          <span class="filter-label">Type</span>
          <.filter_combo
            facet="type"
            value={@filters.type}
            value_label={@filters.type || "All types"}
            label_plural="types"
            options={Enum.map(@filter_options.types, &{&1, &1})}
          />
        </div>
        <div class="filter-field">
          <span class="filter-label">Signal</span>
          <.filter_combo
            facet="signal"
            value={@filters.signal}
            value_label={(@filters.signal && signal(@filters.signal)) || "All signals"}
            label_plural="signals"
            options={Enum.map(@filter_options.signals, &{&1, signal(&1)})}
          />
        </div>
        <button
          :if={active_filters?(@filters)}
          type="button"
          class="filter-clear"
          phx-click="clear_filters"
        >
          Clear
        </button>
        <span class="filter-count">
          {if active_filters?(@filters),
            do: "#{@shown} shown · #{@match_count} match",
            else: "showing top #{@shown}"}
        </span>
      </div>

      <%!-- First-scan skeleton: a shimmer echo of the ranked table while the initial scan runs (and
            at first paint, before connect). Purely decorative — `aria-hidden`, with the masthead's
            "scanning sessions…" carrying status to assistive tech. Only the first scan (`not
            @scanned`); a rescan keeps the existing table on screen, so no skeleton there. --%>
      <div :if={not @scanned} class="scan-skeleton" aria-hidden="true">
        <span class="skel skel-caption"></span>
        <div :for={n <- 1..8} class="skel-row" style={"--i: #{n}"}>
          <span class="skel skel-rank"></span>
          <span class="skel skel-friction"></span>
          <span class="skel skel-project"></span>
          <span class="skel skel-metric"></span>
          <span class="skel skel-metric"></span>
          <span class="skel skel-metric"></span>
          <span class="skel skel-metric"></span>
          <span class="skel skel-metric"></span>
        </div>
      </div>

      <.hero
        :if={@scanned and @results != [] and is_nil(@selected_i)}
        session={hd(@results)}
        allow_propose={@allow_propose}
        installed_skill={installed_skill(hd(@results), @installed_sessions)}
      />

      <%!-- One stage, two modes. Overview: the full ranked table. Detail: the same `.index`
            table shrinks to a sidebar (a container query drops its metric columns) while the
            pane reveals on the right. `data-mode` is the end state; the `StageMorph` hook
            (app.js) tweens the grid columns continuously between the two on each change (FLIP),
            falling back to the instant CSS switch under reduced motion / narrow viewports. --%>
      <div
        :if={@results != []}
        id="stage"
        class="stage"
        data-mode={if @selected_i, do: "detail", else: "overview"}
        phx-hook="StageMorph"
        phx-window-keydown="nav"
      >
        <div class="index" id="index">
          <table class="ranked">
            <caption class="ranked-caption">
              Ranked by friction. Arrow keys or <kbd>j</kbd> / <kbd>k</kbd> move, <kbd>Enter</kbd> opens.
            </caption>
            <thead>
              <%!-- Metric headers carry their definition in a hover/focus tooltip. `tabindex=0` makes
                    the tipped ones keyboard-focusable so the reveal isn't pointer-only (WCAG 1.4.13);
                    `scope="col"` keeps the abbreviated names associated with their cells for SR table
                    navigation (the detail pane spells the same metrics out in prose). --%>
              <tr>
                <th scope="col" class="col-rank">#</th>
                <th scope="col" tabindex="0" class="col-friction num" data-tip={friction_tip()}>Friction</th>
                <th scope="col" class="col-project">Project</th>
                <th scope="col" class="col-type">Type</th>
                <th scope="col" class="col-signal">Signal</th>
                <th scope="col" class="col-missed">Missed</th>
                <th scope="col" tabindex="0" class="col-num num" data-tip="Transcript events — every user + assistant line, including the agent's own tool traffic.">
                  Events
                </th>
                <th scope="col" tabindex="0" class="col-num num" data-tip="Messages a human actually typed. Far smaller than events — the agent generates most of a transcript itself.">
                  Turns
                </th>
                <th scope="col" tabindex="0" class="col-num num" data-tip="Tool calls the agent made — edits, searches, shell runs, MCP calls.">
                  Tools
                </th>
                <th scope="col" tabindex="0" class="col-num num" data-tip="Failures in the session — non-zero command exits and errored tool results.">
                  Errs
                </th>
                <th scope="col" tabindex="0" class="col-num num" data-tip="Peak context-window usage. Shown hot (red) when a session pushed near the limit — a compaction risk.">
                  Ctx
                </th>
                <th scope="col" tabindex="0" class="col-tier2" data-tip="Tier-2 eligible: clears the bar to be worth proposing a skill for.">
                  T2
                </th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={{r, i} <- Enum.with_index(@results, 1)}
                id={"session-#{i}"}
                class={["srow", i == @selected_i && "selected"]}
                style={bar_style(r.raw, @max_raw)}
                data-friction={fmt(r.raw)}
                tabindex="0"
                role="button"
                aria-label={"Open session #{i}: #{project_name(r)}, friction #{fmt(r.raw)}"}
                phx-click="select"
                phx-value-i={i}
                phx-keydown="select"
                phx-key="Enter"
                phx-hook={i == @selected_i && "SelectedIntoView"}
                aria-current={i == @selected_i && "true"}
              >
                <td class="col-rank">{i}</td>
                <td class="col-friction num">{fmt(r.raw)}</td>
                <td class="col-project">
                  <span class="proj-line"><span class="proj-name">{project_name(r)}</span><span class="proj-id">/{project_short(r)}</span><span
                      :if={installed_skill(r, @installed_sessions)}
                      class="row-skill"
                      data-tip="A Faber skill from this session is already installed."
                      aria-label="Skill installed"
                    >✓ skill</span></span>
                  <span class="srow-meta">{r.fingerprint} · {signal(r.dominant_signal)}</span>
                </td>
                <td class="col-type">{r.fingerprint}</td>
                <td class="col-signal">{signal(r.dominant_signal)}</td>
                <td class="col-missed">
                  <span :for={m <- r.missed} class="chip">/{m}</span>
                  <span :if={r.missed == []} class="muted">—</span>
                </td>
                <td class="col-num num">{fmt_int(r.message_count)}</td>
                <td class="col-num num">{fmt_int(r.human_turns)}</td>
                <td class="col-num num">{fmt_int(r.tool_count)}</td>
                <td class="col-num num">{fmt_int(r.error_count)}</td>
                <td class={["col-num", "num", "ctx", hot_ctx?(r.max_ctx_pct) && "hot"]}>
                  {ctx(r.max_ctx_pct)}
                </td>
                <td class="col-tier2">{if r.tier2, do: "✓", else: ""}</td>
              </tr>
            </tbody>
          </table>

          <%!-- The table renders at most `display_limit` rows; when the set is larger, reveal the
                next slice a cap at a time. Only shown while rows remain hidden, so the count
                doubles as "you're not seeing everything yet". --%>
          <div :if={@shown < @match_count} class="show-more-row">
            <button type="button" class="ghost show-more" phx-click="show_more">
              Show more
            </button>
            <span class="show-more-count">{@shown} of {@match_count} shown</span>
          </div>
        </div>

        <.detail_pane
          :if={@selected_i}
          session={Enum.at(@results, @selected_i - 1)}
          selected_i={@selected_i}
          allow_propose={@allow_propose}
          allow_install={@allow_install}
          agents={agents()}
          proposing={@proposing_i == @selected_i}
          proposal={if @proposal_i == @selected_i, do: @proposal, else: nil}
          installed={if @installed && @installed.i == @selected_i, do: @installed, else: nil}
          installed_sessions={@installed_sessions}
        />
      </div>

      <%!-- The scan crashed: a distinct state from "nothing to rank" — nothing is wrong with your
            sessions, so point at Rescan + the logs, not the onboarding copy below. --%>
      <div :if={@scanned and @scan_error?} class="empty">
        <p class="empty-title">The scan didn't finish.</p>
        <p class="empty-body">
          Something went wrong reading your sessions. The details are in the server logs; the scan
          left everything as it was.
        </p>
        <button type="button" class="secondary" phx-click="rescan">Rescan</button>
      </div>

      <%!-- Genuinely empty scan — the first-run moment. Teach where we looked, the message floor,
            and the one next step, instead of a bare "none". --%>
      <div :if={@scanned and not @scan_error? and @all_results == []} class="empty">
        <p class="empty-title">No sessions to rank yet.</p>
        <p class="empty-body">
          Faber read <code>{@scan_location}</code> and found nothing to rank{if @scan_min > 0,
            do: " (sessions under #{@scan_min} messages are skipped)",
            else: ""}. Friction is mined from real coding-agent transcripts — once you've worked a
          session with an agent there, Rescan to see it ranked.
        </p>
        <button type="button" class="secondary" phx-click="rescan">Rescan</button>
      </div>

      <p :if={@scanned and not @scan_error? and @all_results != [] and @results == []} class="empty">
        No sessions match these filters.
        <button type="button" class="filter-clear" phx-click="clear_filters">Clear filters</button>
      </p>
    </main>
    """
  end

  # The opinionated landing lead: the single highest-friction session in the current scan (the top
  # of the ranked list), stated in prose with the one action that matters — Propose a skill for it.
  # It leads the overview; selecting any row swaps it for the detail pane. It never auto-proposes:
  # the button is an explicit, token-spend-confirmed click, so merely loading the page costs nothing.
  attr :session, :map, required: true
  attr :allow_propose, :boolean, required: true
  attr :installed_skill, :map, default: nil

  defp hero(assigns) do
    ~H"""
    <section class="hero" aria-label="Highest-friction session">
      <div class="hero-body">
        <p class="hero-context">Your highest-friction session — where a skill would have helped most.</p>
        <h2 class="hero-title">
          <span class="proj-name">{project_name(@session)}</span><span class="proj-id">/{project_short(@session)}</span>
          <span
            class="hero-score"
            tabindex="0"
            aria-label={"Friction #{fmt(@session.raw)} — #{friction_tip()}"}
            data-tip={friction_tip()}
          >
            {fmt(@session.raw)} <span class="hero-score-label">friction</span>
          </span>
        </h2>
        <p class="hero-explain">{explain(@session)}</p>
        <div :if={@session.missed != []} class="hero-missed">
          <span class="hero-missed-label">Would have helped:</span>
          <span :for={m <- @session.missed} class="chip">/{m}</span>
        </div>
      </div>
      <div class="hero-aside">
        <span :if={@installed_skill} class="badge installed" data-tip="A Faber skill from this session is already installed.">
          ✓ skill installed
        </span>
        <button
          :if={@allow_propose}
          type="button"
          class="propose-btn hero-cta"
          phx-click="propose"
          phx-value-i="1"
          data-confirm="This calls the configured LLM (claude -p by default) and spends tokens. Propose a skill for this session?"
        >
          Propose a skill
        </button>
        <button type="button" class="ghost hero-open" phx-click="select" phx-value-i="1">
          Open session
        </button>
        <p :if={not @allow_propose} class="hero-note">
          Proposing is off in this view — enable it in your Faber web config to draft skills in place.
        </p>
      </div>
    </section>
    """
  end

  # A custom filter dropdown. Open/close and (when searchable) type-to-filter are client-side
  # (app.js, via `data-combo-toggle` / `data-combo-search`); picking an option is a LiveView
  # `pick_filter` event. `options` is a list of `{value, label}`; `value` is the current selection
  # (nil = All). The menu closes on the re-render that follows a pick (the `.open` class app.js
  # added isn't in the server markup, so morphdom drops it).
  attr :facet, :string, required: true
  attr :value, :string, default: nil
  attr :value_label, :string, required: true
  attr :label_plural, :string, required: true
  attr :search_label, :string, default: ""
  attr :options, :list, required: true
  attr :searchable, :boolean, default: false

  defp filter_combo(assigns) do
    ~H"""
    <div class="combo" id={"combo-#{@facet}"}>
      <%!-- A disclosure button controlling a menu of mutually-exclusive choices. The options are
            `menuitemradio` (not a listbox — the earlier `role="listbox"` had no `option` children and
            announced as an empty listbox), so a screen reader reads "menu, N items, <label> checked".
            `aria-expanded` is synced client-side by app.js; the trigger's name carries the facet so
            it isn't announced as a bare "All projects". --%>
      <button
        type="button"
        class="combo-trigger"
        data-combo-toggle
        aria-haspopup="menu"
        aria-controls={"combo-#{@facet}-list"}
        aria-expanded="false"
        aria-label={"#{String.capitalize(@facet)} filter: #{@value_label}"}
      >
        <span class={["combo-value", @value == nil && "is-placeholder"]}>{@value_label}</span>
        <span class="combo-caret" aria-hidden="true">▾</span>
      </button>
      <div class="combo-menu">
        <div :if={@searchable} class="combo-search-wrap">
          <input
            type="text"
            class="combo-search"
            data-combo-search
            autocomplete="off"
            placeholder={"Search #{@search_label}…"}
            aria-label={"Search #{@search_label}"}
          />
        </div>
        <%!-- The pick rides on phx-value-choice, not -value: on a <button> LiveView overwrites the
        reserved `value` key with the element's own (empty) `.value`, silently blanking the facet. --%>
        <ul class="combo-list" id={"combo-#{@facet}-list"} role="menu" aria-label={"#{String.capitalize(@facet)} options"}>
          <li role="none">
            <button
              type="button"
              role="menuitemradio"
              aria-checked={to_string(@value == nil)}
              class={["combo-option", @value == nil && "selected"]}
              phx-click="pick_filter"
              phx-value-facet={@facet}
              phx-value-choice=""
            >
              All {@label_plural}
            </button>
          </li>
          <li :for={{val, label} <- @options} role="none" data-combo-item={String.downcase(label)}>
            <button
              type="button"
              role="menuitemradio"
              aria-checked={to_string(@value == val)}
              class={["combo-option", @value == val && "selected"]}
              phx-click="pick_filter"
              phx-value-facet={@facet}
              phx-value-choice={val}
            >
              {label}
            </button>
          </li>
        </ul>
        <p class="combo-empty" hidden>No matches</p>
      </div>
    </div>
    """
  end

  # The right pane: everything known about the selected session, in prose and quiet metrics, plus
  # the place to act — Propose, Copy, Install — where the session lives, not in a modal.
  attr :session, :map, required: true
  attr :selected_i, :integer, required: true
  attr :allow_propose, :boolean, required: true
  attr :allow_install, :boolean, required: true
  attr :agents, :list, required: true
  attr :proposing, :boolean, required: true
  attr :proposal, :map, default: nil
  attr :installed, :map, default: nil
  attr :installed_sessions, :map, default: %{}

  defp detail_pane(assigns) do
    ~H"""
    <section
      class="detail"
      id="detail-pane"
      phx-hook="DetailFocus"
      data-session={@selected_i}
      aria-labelledby="detail-heading"
    >
      <div class="detail-inner">
        <header class="detail-head">
          <h2 class="detail-id" id="detail-heading" tabindex="-1">
            <span class="proj-name">{project_name(@session)}</span><span class="proj-id">/{project_short(@session)}</span>
          </h2>
          <div
            class="detail-score"
            tabindex="0"
            aria-label={"Friction #{fmt(@session.raw)} — #{friction_tip()}"}
            data-tip={friction_tip()}
          >
            <span class="detail-friction">{fmt(@session.raw)}</span>
            <span class="detail-friction-label">friction <span class="q" aria-hidden="true">?</span></span>
          </div>
        </header>

        <div class="detail-tags">
          <span class="tag">{@session.fingerprint}</span>
          <span class="tag">{signal(@session.dominant_signal)}</span>
          <span :if={@session.tier2} class="badge tier">tier-2 eligible</span>
          <span
            :if={skill = installed_skill(@session, @installed_sessions)}
            class="badge installed"
            data-tip="A Faber skill from this session is installed in your skills dir — it survives a browser refresh."
          >
            ✓ {skill.name} installed
          </span>
        </div>

        <%!-- A plain-language read of why this row ranks where it does — the "explain the row" ask. --%>
        <p class="detail-explain">{explain(@session)}</p>

        <div class="detail-metrics">
          <span class="stat" tabindex="0" data-tip="Transcript events — every user + assistant line, including the agent's own tool traffic.">
            <b>{fmt_int(@session.message_count)}</b> events
          </span>
          <span class="stat" tabindex="0" data-tip="Messages a human actually typed. Far smaller than events — the agent generates most of a transcript itself.">
            <b>{fmt_int(@session.human_turns)}</b> turns
          </span>
          <span class="stat"><b>{fmt_int(@session.tool_count)}</b> tools</span>
          <span class="stat"><b>{fmt_int(@session.error_count)}</b> errors</span>
          <span class="stat">
            <b class={hot_ctx?(@session.max_ctx_pct) && "hot"}>{ctx(@session.max_ctx_pct)}</b> peak context
          </span>
        </div>

        <div class="detail-missed">
          <span class="detail-label">Skills that would have helped</span>
          <div class="chips">
            <span :for={m <- @session.missed} class="chip">/{m}</span>
            <span :if={@session.missed == []} class="muted">none detected</span>
          </div>
        </div>

        <div class="detail-actions">
          <button
            :if={@allow_propose}
            class="propose-btn"
            phx-click="propose"
            phx-value-i={@selected_i}
            disabled={@proposing}
            data-confirm="This calls the configured LLM (claude -p by default) and spends tokens. Continue?"
          >
            {if @proposing, do: "Proposing…", else: "Propose a skill"}
          </button>
          <span :if={!@allow_propose} class="muted">
            Propose is disabled (<code>web_allow_propose: false</code>).
          </span>
        </div>

        <div :if={@proposing} class="proposing-block">
          <p class="proposing">
            Proposing a skill for <strong>{project(@session)}</strong> — this calls the LLM and can take ~a minute.
          </p>
          <div class="progress"><span></span></div>
          <button type="button" class="ghost cancel-propose" phx-click="cancel_propose">
            Cancel
          </button>
        </div>

        <.proposal_card
          :if={@proposal != nil}
          proposal={@proposal}
          row={@selected_i}
          allow_install={@allow_install}
          agents={@agents}
          installed={@installed}
          already={skill_installed?(@proposal[:name])}
        />
      </div>
    </section>
    """
  end

  # Inline result card for the selected session: the eval verdict, the rendered skill, and the
  # act-in-place controls (copy, or install into an agent's world).
  attr :proposal, :map, required: true
  attr :row, :integer, required: true
  attr :allow_install, :boolean, required: true
  attr :agents, :list, required: true
  attr :installed, :map, default: nil
  attr :already, :boolean, default: false

  defp proposal_card(assigns) do
    ~H"""
    <div :if={@proposal[:error]} class="proposal-error">
      <p class="proposal-error-msg">Couldn't draft a skill for this session. {@proposal.error}</p>
      <button
        class="ghost"
        type="button"
        phx-click="propose"
        phx-value-i={@row}
        data-confirm="This calls the configured LLM (claude -p by default) and spends tokens. Try proposing again?"
      >
        Try again
      </button>
    </div>
    <div :if={!@proposal[:error]} class="proposal-card">
      <div class="proposal-head">
        <div class="proposal-meta">
          <span class="proposal-name">{@proposal.name}</span>
          <span class={"badge " <> if(@proposal.passed, do: "pass", else: "fail")}>
            {verdict(@proposal)}
          </span>
          <span class="composite">composite {fmt(@proposal.composite)}</span>
        </div>
        <div class="proposal-buttons">
          <button class="ghost copy-btn" type="button" data-copy={"#skill-#{@row}"}>
            Copy skill
          </button>
          <div :if={@allow_install} class="install" id={"install-#{@row}"}>
            <button
              class="ghost install-btn"
              type="button"
              data-install-toggle
              aria-haspopup="menu"
              aria-expanded="false"
            >
              {if @already, do: "Reinstall ▾", else: "Install ▾"}
            </button>
            <div class="install-menu" role="menu">
              <button
                :for={{key, label} <- @agents}
                type="button"
                role="menuitem"
                phx-click="install"
                phx-value-agent={key}
                phx-value-i={@row}
                phx-value-force={@already && "true"}
                data-confirm={install_confirm(@already, @proposal.name, label)}
              >
                {label}
              </button>
            </div>
          </div>
        </div>
      </div>
      <p :if={@installed} class="install-result">✓ {@installed.msg}</p>
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

  # Shared copy for the "what is friction" tooltip (table header + detail score).
  defp friction_tip do
    "Total weighted friction: retry loops, user corrections, error/tool ratio, approach changes, " <>
      "context compactions, and interrupts. Higher = rougher session; the bar fills relative to the top row."
  end

  # A plain-language read of the row: what drove its friction, at what scale. Turns the raw
  # counts into a sentence so the detail pane explains the ranking, not just displays it.
  defp explain(r) do
    lead =
      case r.dominant_signal do
        nil -> "Friction here was spread across signals"
        s -> "Friction here came mostly from #{signal(s)}"
      end

    errs =
      if is_integer(r.error_count) and r.error_count > 0,
        do: "#{fmt_int(r.error_count)} tool #{plural(r.error_count, "error")}",
        else: "no tool errors"

    ctx =
      case r.max_ctx_pct do
        p when is_number(p) and p >= 80.0 ->
          ", peaking at #{round(p)}% context (near the compaction line)"

        p when is_number(p) ->
          ", peaking at #{round(p)}% context"

        _ ->
          ""
      end

    "#{lead}, over #{fmt_int(r.human_turns)} human #{plural(r.human_turns, "turn")} " <>
      "and #{fmt_int(r.tool_count)} tool #{plural(r.tool_count, "call")} with #{errs}#{ctx}."
  end

  defp plural(1, word), do: word
  defp plural(_n, word), do: word <> "s"

  # Group digits with thousands separators so the detail-pane counts (events can run to five
  # figures) stay legible: 9161 → "9,161".
  defp fmt_int(n) when is_integer(n) do
    n |> Integer.to_string() |> String.replace(~r/\B(?=(\d{3})+(?!\d))/, ",")
  end

  defp fmt_int(n), do: to_string(n)

  # Highest friction in the current page → the highest raw seen; other rows get a proportional bar.
  defp max_raw([]), do: 1.0
  defp max_raw(results), do: results |> Enum.map(& &1.raw) |> Enum.max()

  # A heat bar as a CSS gradient background: fill width ∝ friction / page-max. `--w` drives it.
  defp bar_style(raw, max) when is_number(raw) and is_number(max) and max > 0 do
    "--w:#{round(raw / max * 100)}%"
  end

  defp bar_style(_raw, _max), do: "--w:0%"

  # Clean project label from the session's working directory (falls back to the transcript's
  # parent dir when `cwd` is absent — e.g. some fixtures), plus a short session handle. The table
  # renders the two parts at different emphasis (name in ink, id muted); `project/1` keeps the
  # combined form for prose like the "Proposing a skill for …" line.
  defp project(r), do: "#{project_name(r)}/#{project_short(r)}"

  defp project_name(%{cwd: cwd, path: path}) do
    if is_binary(cwd) and cwd != "",
      do: Path.basename(cwd),
      else: path |> Path.dirname() |> Path.basename()
  end

  defp project_short(%{session_id: sid, path: path}) do
    if is_binary(sid), do: String.slice(sid, 0, 8), else: Path.basename(path, ".jsonl")
  end
end
