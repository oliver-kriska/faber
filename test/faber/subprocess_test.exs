defmodule Faber.SubprocessTest do
  use ExUnit.Case, async: true

  alias Faber.Subprocess

  test "returns System.cmd's result when the command finishes in time" do
    assert {"hi\n", 0} = Subprocess.run("echo", ["hi"], timeout: 5_000)
  end

  test "without a :timeout it is plain System.cmd" do
    assert {"ok\n", 0} = Subprocess.run("echo", ["ok"])
  end

  test "kills a hung command and returns {:error, :timeout} promptly" do
    {us, result} = :timer.tc(fn -> Subprocess.run("sleep", ["10"], timeout: 100) end)

    assert result == {:error, :timeout}
    # Promptly = the timeout, not the sleep: well under a second.
    assert us < 1_000_000
  end

  test "re-raises System.cmd's own errors in the caller (missing binary)" do
    assert_raise ErlangError, fn ->
      Subprocess.run("/nonexistent/faber-no-such-bin", [], timeout: 1_000)
    end
  end

  test "non-zero exits pass through untouched" do
    assert {_out, code} = Subprocess.run("sh", ["-c", "exit 3"], timeout: 5_000)
    assert code == 3
  end
end
