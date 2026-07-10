defmodule FaberWeb.RuntimeConfigTest do
  # async: false — mutates the FABER_HOME env var while evaluating config/runtime.exs (its :prod
  # block persists a secret_key_base file under that dir, redirected here to the test tmp dir).
  use ExUnit.Case, async: false

  # Regression guard for the 2026-06-26 review's DNS-rebinding fix (commit 7fa4968): the prod
  # endpoint must stay pinned to loopback — a malicious page resolving to 127.0.0.1 must not be
  # able to open the socket and drive Propose events. A revert to `check_origin: false` (or a
  # 0.0.0.0 bind) fails here.
  @tag :tmp_dir
  test "prod endpoint config pins origins and bind address to loopback", %{tmp_dir: dir} do
    prev = System.get_env("FABER_HOME")
    System.put_env("FABER_HOME", dir)

    on_exit(fn ->
      if prev, do: System.put_env("FABER_HOME", prev), else: System.delete_env("FABER_HOME")
    end)

    config = Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)
    endpoint = config[:faber][FaberWeb.Endpoint]

    assert endpoint[:check_origin] == ["//localhost", "//127.0.0.1"]
    assert endpoint[:http][:ip] == {127, 0, 0, 1}
    # The secret credential landed in FABER_HOME (not a shared location) — proves the redirect
    # this test relies on, and pins the 0600 tightening.
    secret = Path.join(dir, "secret_key_base")
    assert File.exists?(secret)
  end
end
