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

    with {:ok, json} <- Jason.encode(request),
         {:ok, tmp} <- write_temp(json) do
      try do
        run(python, command, tmp, dir)
      after
        File.rm(tmp)
      end
    end
  end

  defp run(python, command, tmp, dir) do
    {out, _code} =
      System.cmd(python, ["-m", "faber_eval", command, "--input", tmp],
        cd: dir,
        stderr_to_stdout: false
      )

    case Jason.decode(out) do
      {:ok, map} -> {:ok, map}
      {:error, _} -> {:error, {:sidecar_bad_output, out}}
    end
  rescue
    e in [ErlangError, File.Error] -> {:error, {:sidecar_unavailable, e}}
  end

  defp write_temp(json) do
    path = Path.join(System.tmp_dir!(), "faber-#{System.unique_integer([:positive])}.json")

    case File.write(path, json) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, {:tmp_write_failed, reason}}
    end
  end

  defp default_dir, do: Path.join(File.cwd!(), "python")
end
