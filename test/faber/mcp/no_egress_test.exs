defmodule Faber.MCP.NoEgressTest do
  # `async: false` is MANDATORY — this traces ALL processes for socket-connect calls. Run
  # concurrently with a test that legitimately connects and we'd capture a false positive. See
  # `Faber.NoEgressTest` for the full rationale; this is its MCP-path counterpart: the read-only
  # `faber_search_friction` tool must mine the local corpus and open ZERO outbound sockets.
  use ExUnit.Case, async: false

  alias Anubis.Server.Frame
  alias Faber.MCP.Tools.SearchFriction

  @egress_mfas [
    {:gen_tcp, :connect, :_},
    {:ssl, :connect, :_},
    {:socket, :connect, :_}
  ]

  @egress_keys [{:gen_tcp, :connect}, {:ssl, :connect}, {:socket, :connect}]

  # Positive control — a function the tool provably calls — proves the tracer is live, so an empty
  # egress set means "nothing connected" rather than "tracing silently no-op'd".
  @control_mfa {Faber.Scan, :run, :_}
  @control_key {Faber.Scan, :run}

  setup do
    prev = Application.get_env(:faber, :mcp_scan_opts)
    Application.put_env(:faber, :mcp_scan_opts, base: "test/fixtures", min_messages: 0)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:faber, :mcp_scan_opts, prev),
        else: Application.delete_env(:faber, :mcp_scan_opts)
    end)
  end

  test "faber_search_friction opens zero outbound sockets" do
    collector = spawn_link(fn -> collect([]) end)

    Code.ensure_loaded!(Faber.Scan)

    patterns = [@control_mfa | @egress_mfas]
    for mfa <- patterns, do: :erlang.trace_pattern(mfa, true, [:local])
    :erlang.trace(:all, true, [:call, {:tracer, collector}])

    try do
      assert {:reply, %{isError: false}, _frame} =
               SearchFriction.execute(%{limit: 5}, Frame.new())

      flush_trace_delivery()
    after
      :erlang.trace(:all, false, [:call])
      for mfa <- patterns, do: :erlang.trace_pattern(mfa, false, [:local])
    end

    calls = dump(collector)
    egress = Enum.filter(calls, &(&1 in @egress_keys))
    control = Enum.filter(calls, &(&1 == @control_key))

    assert control != [],
           "positive control never fired: the tracer was not live, so a clean egress " <>
             "result is meaningless. Captured calls: #{inspect(calls)}"

    assert egress == [],
           "the MCP friction tool made outbound network connections: #{inspect(egress)}. " <>
             "Read-only MCP tools must never touch the network."
  end

  defp flush_trace_delivery do
    ref = :erlang.trace_delivered(:all)

    receive do
      {:trace_delivered, :all, ^ref} -> :ok
    after
      5_000 -> flunk("trace_delivered timed out")
    end
  end

  defp dump(collector) do
    ref = make_ref()
    send(collector, {:dump, ref, self()})

    receive do
      {:calls, ^ref, calls} -> calls
    after
      5_000 -> flunk("trace collector did not respond to :dump")
    end
  end

  defp collect(acc) do
    receive do
      {:trace, _pid, :call, {mod, fun, _args}} -> collect([{mod, fun} | acc])
      # Drain any trace messages already enqueued ahead of nothing-left before replying, so the dump
      # can't miss a late-but-delivered call (belt-and-suspenders atop flush_trace_delivery/0).
      {:dump, ref, to} -> send(to, {:calls, ref, drain(acc)})
    end
  end

  defp drain(acc) do
    receive do
      {:trace, _pid, :call, {mod, fun, _args}} -> drain([{mod, fun} | acc])
    after
      0 -> acc
    end
  end
end
