defmodule Faber.Subprocess do
  @moduledoc """
  `System.cmd/3` with a `:timeout` — the guard every external binary Faber shells out to
  (`claude -p`, the Python sidecar, `git`, `sqlite3`) runs through, so a hung subprocess can
  never wedge a scheduler tick, stall the reflective loop, or hang a one-shot CLI command.

  The command runs in a task; on timeout the task is brutally shut down, which closes the
  port — a well-behaved CLI gets EOF/EPIPE on its stdio and exits (a truly detached child is
  orphaned, which is the best `System.cmd/3` semantics can offer without a process-group
  dependency). Raises from `System.cmd/3` itself (e.g. `ErlangError` for a missing binary)
  re-raise in the caller, so existing `rescue` handling keeps working unchanged.

  Returns what `System.cmd/3` returns, or `{:error, :timeout}`. Passing no `:timeout` (or
  `:infinity`) is plain `System.cmd/3`.
  """

  @spec run(binary(), [binary()], keyword()) ::
          {binary(), non_neg_integer()} | {:error, :timeout}
  def run(bin, args, opts \\ []) do
    {timeout, cmd_opts} = Keyword.pop(opts, :timeout, :infinity)

    if timeout == :infinity do
      System.cmd(bin, args, cmd_opts)
    else
      run_with_timeout(bin, args, cmd_opts, timeout)
    end
  end

  defp run_with_timeout(bin, args, cmd_opts, timeout) do
    task =
      Task.async(fn ->
        try do
          {:ok, System.cmd(bin, args, cmd_opts)}
        rescue
          e -> {:raise, e, __STACKTRACE__}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, result}} -> result
      {:ok, {:raise, e, stacktrace}} -> reraise e, stacktrace
      {:exit, reason} -> exit(reason)
      nil -> {:error, :timeout}
    end
  end
end
