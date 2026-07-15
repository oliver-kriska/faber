defmodule Faber.Scan.Coalesce do
  @moduledoc """
  Single-flight for scans: concurrent callers asking the same question share one answer.

  Every dashboard mount runs a scan, and a LiveView's assigns die with its process — so a browser
  refresh, or a second tab, is a fresh `mount` and a fresh scan. `Faber.Scan.Cache` already removed
  the expensive half (nobody re-parses a transcript), but the rest is still paid per mount: on a
  ~6.6k-session corpus a warm scan is ~424ms, **~60% of it `discover/1` walking the transcript
  tree**. Three tabs refreshing meant three simultaneous walks of the same 6.6k files, and a cold
  corpus multiplies that by ~13.

  This coalesces them. The first caller for a given key runs the scan; anyone who asks the same
  question *while it is in flight* blocks and receives that scan's result. N concurrent mounts cost
  one scan, not N.

  ## Why this doesn't compromise the cache's transparency

  `Faber.Scan.Cache` is transparent by construction — it can only ever return what re-scoring would
  have. A **TTL memo** would break that: it deliberately serves a result computed at some earlier
  time. Single-flight does not. A joiner gets the result of a scan that overlapped its own call, so
  the answer is one that a scan running *right now* legitimately produces.

  The honest caveat: a joiner's result is a snapshot taken when the leader started, up to one scan
  earlier. That is not a new source of staleness — a scan of a live corpus is already a snapshot of
  a moving target (transcripts are appended to *while* the scan runs), so the window this adds is
  bounded by the very same scan duration that was always racy. Anything needing a hard "read after
  my write" ordering must not overlap its scans, and sequential calls never coalesce: a flight only
  exists between a leader's start and its finish.

  ## Shape

  The **leader runs the scan in its own process**, not in this GenServer and not in a task. That
  keeps ~5s of fan-out out of this process's mailbox (it must stay responsive to joiners), avoids a
  third `Task.Supervisor` in the tree, and leaves the caller's own timeout and cancellation
  semantics — `start_async`'s in the dashboard's case — exactly as they were. This process only
  ever bookkeeps: who is leading, who is waiting.

  The leader is monitored, so a leader that crashes (or is killed mid-scan, which `start_async`
  does when a LiveView disconnects) fails its joiners rather than hanging them forever.
  """

  use GenServer

  # A cold scan on a large corpus runs ~9s, and a joiner waits out the leader's whole scan. The
  # default 5s `GenServer.call` timeout would fire *mid-flight* and turn a working scan into a
  # caller crash, so this is deliberately generous — it is a deadlock backstop, not a scan budget.
  @call_timeout 120_000

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Run `fun`, or join an in-flight run for the same `key` and take its result.

  Faithful to calling `fun` directly: a leader whose scan raises or exits propagates that to itself
  normally, and joiners of a failed flight exit with the same reason rather than silently receiving
  a wrong answer.

  Degrades to running `fun` inline when this process isn't up (a bare `Faber.Scan` call from a
  script that never started the app) — coalescing is an optimization, never a dependency.
  """
  @spec run(term(), (-> result)) :: result when result: term()
  def run(key, fun) do
    if Process.whereis(__MODULE__) do
      do_run(key, fun)
    else
      fun.()
    end
  end

  defp do_run(key, fun) do
    case join(key) do
      :lead -> lead(key, fun)
      {:joined, result} -> unwrap(result)
      :no_registry -> fun.()
    end
  end

  # The catch belongs to the call and nothing else. Wrapping the whole dispatch would swallow the
  # exits this module deliberately propagates — a joiner re-raising a dead leader's exit, or a
  # leader re-raising its own exiting scan — and silently re-run `fun` instead, which is the exact
  # duplicate work single-flight exists to prevent.
  defp join(key) do
    GenServer.call(__MODULE__, {:join, key}, @call_timeout)
  catch
    # The registry died between the whereis and the call. Not a reason to fail a scan.
    :exit, _ -> :no_registry
  end

  defp lead(key, fun) do
    result = fun.()
    GenServer.cast(__MODULE__, {:done, key, {:ok, result}})
    result
  catch
    kind, reason ->
      # Release the joiners before re-raising, or they would block until @call_timeout on a flight
      # that is already dead.
      GenServer.cast(__MODULE__, {:done, key, {:failed, {kind, reason}}})
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp unwrap({:ok, result}), do: result
  defp unwrap({:failed, {:exit, reason}}), do: exit(reason)
  defp unwrap({:failed, {kind, reason}}), do: :erlang.raise(kind, reason, [])
  defp unwrap({:down, reason}), do: exit(reason)

  @doc """
  The scans currently in flight, mapped to how many extra callers are waiting on each — for tests
  and diagnostics.

  `%{}` means nothing is running; `%{key => 0}` is a leader with no joiners yet. Reporting waiters
  rather than just a count matters for tests: "a flight exists" is registered by the *leader* and
  says nothing about whether a joiner has attached to it yet.
  """
  @spec flights() :: %{term() => non_neg_integer()}
  def flights, do: GenServer.call(__MODULE__, :flights)

  # ── Registry ──────────────────────────────────────────────────────────────────────────────────

  @impl true
  def init(_opts), do: {:ok, %{flights: %{}, monitors: %{}}}

  @impl true
  def handle_call({:join, key}, {pid, _tag} = from, state) do
    case state.flights[key] do
      nil ->
        # Monitor the leader: if it dies mid-scan, its joiners must be told, not left to time out.
        ref = Process.monitor(pid)
        flights = Map.put(state.flights, key, %{ref: ref, waiters: []})
        {:reply, :lead, %{state | flights: flights, monitors: Map.put(state.monitors, ref, key)}}

      flight ->
        # No reply now — this caller blocks until the leader reports back.
        flights = Map.put(state.flights, key, %{flight | waiters: [from | flight.waiters]})
        {:noreply, %{state | flights: flights}}
    end
  end

  def handle_call(:flights, _from, state) do
    {:reply, Map.new(state.flights, fn {key, f} -> {key, length(f.waiters)} end), state}
  end

  @impl true
  def handle_cast({:done, key, result}, state) do
    {:noreply, resolve(state, key, result)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case state.monitors[ref] do
      nil -> {:noreply, state}
      key -> {:noreply, resolve(state, key, {:down, reason})}
    end
  end

  defp resolve(state, key, result) do
    case state.flights[key] do
      nil ->
        state

      flight ->
        Enum.each(flight.waiters, &GenServer.reply(&1, {:joined, result}))
        Process.demonitor(flight.ref, [:flush])

        %{
          state
          | flights: Map.delete(state.flights, key),
            monitors: Map.delete(state.monitors, flight.ref)
        }
    end
  end
end
