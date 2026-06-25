defmodule Faber.NoEgressTest do
  # `async: false` is MANDATORY. This traces ALL processes for socket-connect calls; run
  # concurrently with another test that legitimately connects and we'd capture a false positive.
  # ExUnit runs `async: false` tests serially, isolated from every other test — so the only
  # network activity in the trace window is this pipeline's (the app's supervision tree —
  # PubSub, the inert scheduler, an idle Endpoint — makes no outbound connections at rest).
  use ExUnit.Case, async: false

  alias Faber.{Adapter, Eval, Install, Propose, Scan}

  # Every outbound TCP/TLS connection on the BEAM funnels through one of these public connect
  # entry points (HTTP clients — Req/Finch/Mint, :httpc, :gun — all bottom out here). Tracing the
  # chokepoint instead of each client makes the guard client-agnostic: swap ReqLLM for anything
  # and the test still bites. `:socket` is the newer nif-based stack; absent on older OTP, where
  # `trace_pattern` simply matches zero functions (no error).
  @egress_mfas [
    {:gen_tcp, :connect, :_},
    {:ssl, :connect, :_},
    {:socket, :connect, :_}
  ]

  @egress_keys [{:gen_tcp, :connect}, {:ssl, :connect}, {:socket, :connect}]

  # Positive control — a function the native pipeline provably calls. Capturing it proves the
  # tracer is actually live, so an empty egress set means "nothing connected" rather than
  # "tracing silently no-op'd" (a false-negative that would make this whole test worthless).
  @control_mfa {Faber.Eval.Native, :score, :_}
  @control_key {Faber.Eval.Native, :score}

  @fixtures [base: "test/fixtures", min_messages: 0]

  describe "the native pipeline is hermetic (proves the local-first promise)" do
    test "scan → propose(stub) → eval(native) → install opens zero outbound sockets" do
      tmp =
        Path.join(System.tmp_dir!(), "faber-no-egress-#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf(tmp) end)

      # A SEPARATE tracer process is required: the BEAM never traces its own tracer, so if the
      # test process were the tracer, the in-process pipeline calls (incl. the positive control)
      # would be invisible. The collector accumulates `:call` traces and replies on `:dump`.
      collector = spawn_link(fn -> collect([]) end)

      # A trace pattern only matches functions in *loaded* modules — the BEAM loads code lazily, so
      # the control module may not be in memory yet. Force it (the egress modules are OTP, always
      # loaded). Without this, `trace_pattern` matches 0 functions and the control silently never
      # fires — exactly the false-negative the control exists to catch.
      Code.ensure_loaded!(Faber.Eval.Native)

      patterns = [@control_mfa | @egress_mfas]
      for mfa <- patterns, do: :erlang.trace_pattern(mfa, true, [:local])
      :erlang.trace(:all, true, [:call, {:tracer, collector}])

      try do
        run_native_pipeline(tmp)
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
             "the native pipeline made outbound network connections: #{inspect(egress)}. " <>
               "The keyless/local-first path must never touch the network."
    end
  end

  # The full keyless path, end to end: mine fixtures, draft with the offline stub LLM, score with
  # the in-process native engine, and install the rendered skill to a tmp dir. No API key, no
  # sidecar, no `engine: :sidecar` — exactly the path a user runs with zero credentials.
  defp run_native_pipeline(tmp) do
    {:ok, adapter} = Adapter.load("adapters/faber-elixir")

    assert [%Scan.Result{} = result | _] = Scan.run(@fixtures ++ [limit: 3])
    assert {:ok, proposal} = Propose.propose(result, adapter, llm: Faber.LLM.Stub)

    skill = Propose.render_skill_md(proposal, adapter)
    assert {:ok, _score} = Eval.score(skill, engine: :native)
    assert {:ok, _path} = Install.install(proposal, dir: tmp, adapter: adapter, force: true)
  end

  # Block until every trace message generated before this point has reached the tracer — without
  # it, a connect in a just-finished Task worker could still be in flight when we dump.
  defp flush_trace_delivery do
    ref = :erlang.trace_delivered(:all)

    receive do
      {:trace_delivered, :all, ^ref} -> :ok
    after
      5_000 -> flunk("trace_delivered timed out — could not confirm trace messages were flushed")
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
      # Drain any still-enqueued trace messages before replying, so the dump can't miss a
      # late-but-delivered call (belt-and-suspenders atop flush_trace_delivery/0).
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
