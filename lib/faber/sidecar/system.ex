defmodule Faber.Sidecar.System do
  @moduledoc """
  Default `Faber.Sidecar` impl: runs `python -m faber_eval <command> --input <tmp.json>` and
  decodes the JSON it prints on stdout.

  The interpreter (`config :faber, :python`, default `"python3"`) and the package directory
  (`config :faber, :python_dir`, default `<cwd>/python`) are configurable. The sidecar is
  stdlib-only, so no virtualenv/uv is required. A missing interpreter surfaces as
  `{:error, {:sidecar_unavailable, _}}` rather than a crash — eval is best-effort, not a hard
  dependency of the spine.
  """

  @behaviour Faber.Sidecar

  @impl Faber.Sidecar
  def call(command, request, opts) do
    python = opts[:python] || Application.get_env(:faber, :python, "python3")
    dir = opts[:python_dir] || Application.get_env(:faber, :python_dir, default_dir())

    timeout =
      opts[:timeout] || Application.get_env(:faber, :sidecar_timeout_ms, :timer.minutes(2))

    with {:ok, json} <- Jason.encode(request),
         {:ok, tmp} <- write_temp(json) do
      try do
        run(python, command, tmp, dir, timeout)
      after
        File.rm(tmp)
      end
    end
  end

  defp run(python, command, tmp, dir, timeout) do
    case Faber.Subprocess.run(python, ["-m", "faber_eval", command, "--input", tmp],
           cd: dir,
           stderr_to_stdout: false,
           timeout: timeout
         ) do
      {:error, :timeout} ->
        {:error, {:sidecar_timeout, timeout}}

      {out, 0} ->
        case Jason.decode(out) do
          {:ok, map} -> {:ok, map}
          {:error, _} -> {:error, {:sidecar_bad_output, out}}
        end

      # A non-zero exit means the run failed (import error, traceback, bad command); never trust
      # partial stdout that happens to parse — surface the code so triage is possible.
      {out, code} ->
        {:error, {:sidecar_exit, code, out}}
    end
  rescue
    e in [ErlangError, File.Error] -> {:error, {:sidecar_unavailable, e}}
  end

  # Write the request JSON with an unguessable name and O_EXCL + 0600 perms — the body is the
  # friction finding, and on a shared/CI host a predictable world-readable temp file is an
  # info-leak / symlink-TOCTOU vector.
  defp write_temp(json) do
    path = Path.join(System.tmp_dir!(), "faber-#{rand_token()}.json")

    case File.open(path, [:write, :exclusive, :binary]) do
      {:ok, io} ->
        IO.binwrite(io, json)
        File.close(io)
        _ = File.chmod(path, 0o600)
        {:ok, path}

      {:error, reason} ->
        {:error, {:tmp_write_failed, reason}}
    end
  end

  defp rand_token, do: :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)

  defp default_dir, do: Path.join(File.cwd!(), "python")
end
