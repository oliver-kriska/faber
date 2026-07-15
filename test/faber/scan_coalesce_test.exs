defmodule Faber.ScanCoalesceTest do
  @moduledoc """
  Single-flight has two failure modes, and they pull in opposite directions: coalescing too little
  (N tabs = N scans, the thing this exists to stop) and coalescing too much (a caller handed an
  answer to a question it did not ask, or left hanging when the leader dies).

  Everything here synchronizes on `flights/0` rather than on sleeps, and asserts on the *specific*
  exit reason rather than "it exited" — an over-broad exit assertion is satisfied by a test that
  merely timed out, which silently turns a hang into a pass.
  """

  use ExUnit.Case, async: false

  alias Faber.Scan.Coalesce

  describe "coalescing" do
    test "concurrent callers on the same key run the work once and all receive that result" do
      test_pid = self()
      runs = :counters.new(1, [])

      fun = fn ->
        :counters.add(runs, 1, 1)
        send(test_pid, {:running, self()})

        receive do
          :release -> :the_one_result
        after
          5_000 -> exit(:never_released)
        end
      end

      leader = Task.async(fn -> Coalesce.run(:same_key, fun) end)
      assert_receive {:running, leader_pid}, 1_000

      joiners = for _ <- 1..3, do: Task.async(fn -> Coalesce.run(:same_key, fun) end)
      # Wait for the joiners to actually attach. "A flight exists" is registered by the leader and
      # says nothing about the joiners — waiting on that instead would let them race past and each
      # start a flight of their own, quietly voiding the whole test.
      wait_until(fn -> Coalesce.flights()[:same_key] == 3 end, "joiners never attached")

      send(leader_pid, :release)

      assert Task.await(leader) == :the_one_result
      assert Enum.map(joiners, &Task.await/1) == List.duplicate(:the_one_result, 3)

      # The point of the module: four callers, one execution.
      assert :counters.get(runs, 1) == 1
    end

    test "different keys do not share a flight" do
      test_pid = self()

      a = Task.async(fn -> Coalesce.run(:key_a, blocking_fun(test_pid, :a)) end)
      assert_receive {:running, :a, pid_a}, 1_000

      b = Task.async(fn -> Coalesce.run(:key_b, blocking_fun(test_pid, :b)) end)
      assert_receive {:running, :b, pid_b}, 1_000

      # Both ran: key_b did not join key_a's flight, and each is a leader with no waiters.
      assert Coalesce.flights() == %{key_a: 0, key_b: 0}

      send(pid_a, {:release, :answer_a})
      send(pid_b, {:release, :answer_b})

      assert Task.await(a) == :answer_a
      assert Task.await(b) == :answer_b
    end

    test "sequential calls never coalesce — each runs its own work" do
      runs = :counters.new(1, [])
      fun = fn -> :counters.add(runs, 1, 1) end

      Coalesce.run(:seq, fun)
      Coalesce.run(:seq, fun)
      Coalesce.run(:seq, fun)

      # This is what keeps `scan → change the corpus → scan` honest: a flight exists only between a
      # leader's start and its finish, so nothing here can be served an earlier call's answer.
      assert :counters.get(runs, 1) == 3
      assert Coalesce.flights() == %{}
    end

    test "a finished flight is cleared, so the next caller leads a fresh one" do
      assert Coalesce.run(:cleared, fn -> 1 end) == 1
      assert Coalesce.flights() == %{}
      assert Coalesce.run(:cleared, fn -> 2 end) == 2
    end
  end

  describe "failure" do
    setup do
      # Task.async links, so an abnormally-dying task would take this test process with it before
      # Task.await could report anything.
      Process.flag(:trap_exit, true)
      :ok
    end

    test "a raising leader re-raises to itself and hands the same error to its joiners" do
      test_pid = self()

      leader =
        Task.async(fn ->
          Coalesce.run(:boom, fn ->
            send(test_pid, {:running, self()})

            receive do
              :release -> raise "scan blew up"
            after
              5_000 -> exit(:never_released)
            end
          end)
        end)

      assert_receive {:running, leader_pid}, 1_000
      joiner = Task.async(fn -> Coalesce.run(:boom, fn -> :never_runs end) end)
      wait_until(fn -> Coalesce.flights()[:boom] == 1 end, "joiner never attached")

      send(leader_pid, :release)

      # Matching the error itself, not merely "it exited": the leader's raise must reach the leader
      # unchanged...
      assert {{%RuntimeError{message: "scan blew up"}, _stack}, {Task, :await, _}} =
               catch_exit(Task.await(leader))

      # ...and reach the joiner too, rather than stranding it until @call_timeout or — far worse —
      # handing it a plausible wrong answer.
      assert {{%RuntimeError{message: "scan blew up"}, _stack}, {Task, :await, _}} =
               catch_exit(Task.await(joiner))

      assert Coalesce.flights() == %{}
    end

    test "a leader that rescues its own failure still frees its joiners" do
      test_pid = self()

      # A caller that rescues — a long-lived server calling Scan.run inside a try, say. The leader
      # process SURVIVES its failed scan, so the monitor never fires: only the explicit report back
      # can release the joiners. Without this case, the two tests above pass on the monitor alone
      # and that report looks like dead code.
      leader =
        Task.async(fn ->
          try do
            Coalesce.run(:rescued, fn ->
              send(test_pid, {:running, self()})

              receive do
                :release -> raise "scan blew up"
              after
                5_000 -> exit(:never_released)
              end
            end)
          rescue
            e in RuntimeError -> {:rescued, e.message}
          end
        end)

      assert_receive {:running, leader_pid}, 1_000
      joiner = Task.async(fn -> Coalesce.run(:rescued, fn -> :never_runs end) end)
      wait_until(fn -> Coalesce.flights()[:rescued] == 1 end, "joiner never attached")

      send(leader_pid, :release)

      assert Task.await(leader) == {:rescued, "scan blew up"}

      assert {{%RuntimeError{message: "scan blew up"}, _stack}, {Task, :await, _}} =
               catch_exit(Task.await(joiner))

      assert Coalesce.flights() == %{}
    end

    test "a leader killed mid-flight fails its joiners via the monitor" do
      test_pid = self()

      # Unlinked: this one gets killed on purpose.
      leader = spawn(fn -> Coalesce.run(:killed, blocking_fun(test_pid, :victim)) end)
      assert_receive {:running, :victim, _}, 1_000

      joiner = Task.async(fn -> Coalesce.run(:killed, fn -> :never_runs end) end)
      wait_until(fn -> Coalesce.flights()[:killed] == 1 end, "joiner never attached")

      # Exactly what start_async does to its task when a LiveView disconnects mid-scan. The leader
      # dies with no chance to report, so only the monitor can free the joiner.
      Process.exit(leader, :kill)

      assert {:killed, {Task, :await, _}} = catch_exit(Task.await(joiner))
      wait_until(fn -> Coalesce.flights() == %{} end, "a dead leader's flight was never cleared")
    end
  end

  describe "degradation" do
    test "with the registry down, run/2 still runs the work inline" do
      :ok = Supervisor.terminate_child(Faber.Supervisor, Coalesce)
      on_exit(fn -> Supervisor.restart_child(Faber.Supervisor, Coalesce) end)

      refute Process.whereis(Coalesce)

      # Coalescing is an optimization, never a dependency: no registry ⇒ no sharing, same answer.
      assert Coalesce.run(:no_registry, fn -> :still_works end) == :still_works
    end
  end

  describe "Faber.Scan.run/1 integration" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp_dir} do
      corpus = Path.join(tmp_dir, "corpus")
      File.mkdir_p!(Path.join(corpus, "proj"))

      for i <- 1..3 do
        lines =
          for j <- 1..(i * 2) do
            Jason.encode!(%{
              "type" => "user",
              "uuid" => "u#{j}-#{i}",
              "sessionId" => "s#{i}",
              "cwd" => "/tmp/proj",
              "message" => %{"role" => "user", "content" => "do the thing #{j}"}
            })
          end

        File.write!(Path.join([corpus, "proj", "s#{i}.jsonl"]), Enum.join(lines, "\n"))
      end

      {:ok, corpus: corpus}
    end

    test "concurrent scans agree, whether or not they shared a flight", %{corpus: corpus} do
      opts = [base: corpus, min_messages: 0, dedupe: false]

      # `max_concurrency` is excluded from @result_opts because it changes only HOW the scan runs.
      # So all three ask the same question and must get the same answer — the middle one proves the
      # exclusion is safe, since it shares a flight key with callers that fan out differently.
      tasks = [
        Task.async(fn -> Faber.Scan.run(opts) end),
        Task.async(fn -> Faber.Scan.run(Keyword.put(opts, :max_concurrency, 1)) end),
        Task.async(fn -> Faber.Scan.run(opts) end)
      ]

      [a, b, c] = Enum.map(tasks, &Task.await(&1, 30_000))
      assert length(a) == 3
      assert a == b
      assert b == c
    end

    test "opts that change the result do not share a flight", %{corpus: corpus} do
      opts = [base: corpus, min_messages: 0, dedupe: false]

      # min_messages IS in @result_opts. If flight keys ignored it, one of these could be handed the
      # other's results.
      tasks = [
        Task.async(fn -> Faber.Scan.run(opts) end),
        Task.async(fn -> Faber.Scan.run(Keyword.put(opts, :min_messages, 5)) end)
      ]

      [all, filtered] = Enum.map(tasks, &Task.await(&1, 30_000))
      assert length(all) == 3
      assert length(filtered) == 1
    end

    test "coalesce: false returns the same results", %{corpus: corpus} do
      opts = [base: corpus, min_messages: 0, dedupe: false]

      assert Faber.Scan.run(opts) == Faber.Scan.run(Keyword.put(opts, :coalesce, false))
    end
  end

  # Blocks until released, so a flight stays open deterministically instead of by sleeping and
  # hoping the timing lands.
  defp blocking_fun(test_pid, tag) do
    fn ->
      send(test_pid, {:running, tag, self()})

      receive do
        {:release, value} -> value
      after
        5_000 -> exit(:never_released)
      end
    end
  end

  defp wait_until(fun, msg, tries \\ 200)
  defp wait_until(_fun, msg, 0), do: flunk(msg)

  defp wait_until(fun, msg, tries) do
    if fun.() do
      :ok
    else
      Process.sleep(5)
      wait_until(fun, msg, tries - 1)
    end
  end
end
