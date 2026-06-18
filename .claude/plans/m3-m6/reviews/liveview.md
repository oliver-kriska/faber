# LiveView Architecture Review: DashboardLive

Reviewed files: `lib/faber_web/live/dashboard_live.ex`, `lib/faber_web/components/layouts.ex`,
`lib/faber_web/endpoint.ex`, `lib/faber_web/router.ex`, `lib/faber_web.ex`

Diff base: `e1db06c..HEAD -- lib/faber_web`

---

## BLOCKER — Scan blocks the LiveView process on mount and handle_event

**File**: `lib/faber_web/live/dashboard_live.ex:15-26`

`Scan.run/1` is called synchronously in both the connected mount branch and in `handle_event
"rescan"`. `Scan.run` fans out across up to 400 sessions via `Task.async_stream`, waits for all
tasks (60 s per-session timeout), and then sorts. Even with parallelism, the wall time on a real
`~/.claude/projects` tree is seconds. Calling this directly blocks the LiveView process. The
browser gets no response until the call returns — no intermediate spinner state becomes visible,
and the socket is unresponsive to other events for the duration.

**The connected? guard is structurally correct** (avoids the double-scan on dead render), but it
does not fix the blocking problem. The disconnected branch returning `scanned: false` and showing
"scanning sessions…" gives the visual impression of async loading, but the connected mount blocks
before any UI update reaches the client.

**Fix**: Wrap the scan in `assign_async`:

```elixir
def mount(_params, _session, socket) do
  if connected?(socket) do
    {:ok,
     socket
     |> assign(:scanned, false, :total, 0, :tier2, 0, :results, [])
     |> assign_async(:scan_result, fn -> {:ok, %{scan_result: do_scan()}} end)}
  else
    {:ok, assign(socket, scanned: false, total: 0, tier2: 0, results: [])}
  end
end
```

Then in `handle_async/3` (or by watching `@scan_result.ok?`) derive the display assigns. For the
rescan button, use `start_async/3` so the existing scan result stays visible while the new one
runs:

```elixir
def handle_event("rescan", _params, socket) do
  {:noreply,
   start_async(socket, :scan_result, fn -> {:ok, %{scan_result: do_scan()}} end)}
end
```

Extract `scan_opts()` before the closure to avoid capturing the socket.

---

## WARNING — length(@results) called in render on every re-render

**File**: `lib/faber_web/live/dashboard_live.ex:47`

```heex
showing top {length(@results)}
```

`length/1` is O(n) and runs every render cycle. At a fixed 25 items this is negligible, but the
idiomatic fix is to store the count as an assign once at load time and reference it directly
(`@shown`). This also keeps the template free of inline computation.

---

## WARNING — Streams vs assigns: not a concern here, but document the reasoning

**File**: `lib/faber_web/live/dashboard_live.ex:32`

`@results` is a plain list assign holding at most 25 structs (the `Enum.take(results, 25)` cap is
hardcoded). At 25 items, the memory delta between a stream and a list assign is immaterial (~a few
KB). Streams add DOM-id overhead and complicate the `:for` comprehension without any practical
benefit at this cardinality. The current assigns approach is correct. No change needed.

If the cap is ever raised above ~200, revisit with `stream/3`.

---

## WARNING — No `fetch_live_flash` / flash rendering in layout

**File**: `lib/faber_web/components/layouts.ex`

The root layout has no `<.flash_group>` or equivalent. LiveView's `put_flash/3` calls will be
silently dropped. For a read-only dashboard that currently never calls `put_flash` this is not
active harm, but if error handling is added (e.g., scan failure feedback), flashes will be
invisible. Add a flash group to `layouts.ex` preemptively.

---

## WARNING — `defer` on LiveView JS may delay socket connection on slow networks

**File**: `lib/faber_web/components/layouts.ex:15-20`

All three scripts (`phoenix.min.js`, `phoenix_live_view.min.js`, `app.js`) use `defer`. `defer`
guarantees execution order and fires before `DOMContentLoaded`, which is correct for LiveView. This
is a valid pattern when the scripts are small/vendored UMDs. No change needed.

However: `app.js` must be loaded last and must run after `phoenix_live_view.min.js` initialises
the `LiveSocket`. With `defer` on all three, browser load order is preserved as declared (spec
guarantee), so the ordering is correct as written.

No action required — noting for completeness.

---

## SUGGESTION — `fetch_live_flash` missing from `:browser` pipeline

**File**: `lib/faber_web/router.ex`

The browser pipeline omits `fetch_live_flash`. Standard Phoenix generators include it. Without it,
flash messages set inside LiveView callbacks cannot be read. Low risk for the current feature set,
but worth adding now:

```elixir
pipeline :browser do
  plug :accepts, ["html"]
  plug :fetch_session
  plug :fetch_live_flash          # add
  plug :put_root_layout, html: {FaberWeb.Layouts, :root}
  plug :protect_from_forgery
  plug :put_secure_browser_headers
end
```

---

## SUGGESTION — HEEx template: `:if` conditions are correct, minor readability note

**File**: `lib/faber_web/live/dashboard_live.ex:44-82`

All `:if` guards are syntactically correct HEEx. The `@results != []` guard on the table and the
`@scanned and @results == []` guard on the empty-state paragraph are logically complete and
non-overlapping. No correctness issues.

One readability micro-improvement: `Enum.empty?(@results)` communicates intent more clearly than
`@results == []`, but this is stylistic only.

---

## SUGGESTION — No `on_mount` / authentication guard

**File**: `lib/faber_web/router.ex:15`

The route has no `on_mount` hook. This is a local-only developer tool, so exposing it without
auth is presumably intentional. If the dashboard is ever reachable over a network interface,
an `on_mount` guard (or at minimum a `plug :ensure_localhost` in the pipeline) should be added.

---

## Summary table

| Severity | Location | Issue |
|----------|----------|-------|
| BLOCKER | `dashboard_live.ex:25-26` | `Scan.run` called synchronously in connected mount and `handle_event` — blocks LiveView process |
| WARNING | `dashboard_live.ex:47` | `length(@results)` in template — store as assign instead |
| WARNING | `layouts.ex` | No flash group — flash calls will be silently dropped |
| WARNING | `router.ex` | Missing `fetch_live_flash` plug |
| SUGGESTION | `dashboard_live.ex:32` | Streams not needed at 25 items — current approach correct, document threshold |
| SUGGESTION | `router.ex:15` | No auth guard — acceptable for local tool, note if network exposure changes |

---

## Recommended mount after fix

```elixir
def mount(_params, _session, socket) do
  opts = scan_opts()

  if connected?(socket) do
    {:ok,
     socket
     |> assign(scanned: false, total: 0, tier2: 0, results: [], shown: 0)
     |> assign_async(:_scan, fn ->
       results = Scan.run(opts)
       top = Enum.take(results, 25)
       {:ok, %{scanned: true, total: length(results),
               tier2: Enum.count(results, & &1.tier2),
               results: top, shown: length(top)}}
     end)}
  else
    {:ok, assign(socket, scanned: false, total: 0, tier2: 0, results: [], shown: 0)}
  end
end

def handle_event("rescan", _params, socket) do
  opts = scan_opts()
  {:noreply,
   socket
   |> assign(scanned: false)
   |> start_async(:_scan, fn ->
     results = Scan.run(opts)
     top = Enum.take(results, 25)
     {:ok, %{scanned: true, total: length(results),
             tier2: Enum.count(results, & &1.tier2),
             results: top, shown: length(top)}}
   end)}
end

def handle_async(:_scan, {:ok, data}, socket) do
  {:noreply, assign(socket, data)}
end

def handle_async(:_scan, {:exit, reason}, socket) do
  {:noreply, assign(socket, scanned: true, results: [], total: 0, tier2: 0, shown: 0)}
end
```
