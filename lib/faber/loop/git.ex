defmodule Faber.Loop.Git do
  @moduledoc """
  Git as the loop's ratchet — HEAD always holds the current best skill.

  On **keep**: stage the skill path(s) and commit. On **revert**: `git checkout --` the path(s),
  discarding the failed mutation back to the last kept state. All operations are scoped to the
  given paths (relative to `dir`), so the loop can never touch unrelated files — the same safety
  invariant as the plugin's `git checkout -- {skill_dir}`.
  """

  @doc "Stage `paths` and commit with `message`. Returns `:ok` or `{:error, output}`."
  @spec commit(Path.t(), [String.t()], String.t()) :: :ok | {:error, term()}
  def commit(_dir, [], _message), do: :ok

  def commit(dir, paths, message) do
    with {:ok, safe} <- safe_paths(dir, paths),
         {:ok, _} <- git(dir, ["add", "--" | safe]),
         {:ok, _} <- git(dir, ["commit", "-m", message]) do
      :ok
    end
  end

  @doc "Discard working-tree changes to `paths` (revert to HEAD)."
  @spec revert(Path.t(), [String.t()]) :: :ok | {:error, term()}
  def revert(_dir, []), do: :ok

  def revert(dir, paths) do
    with {:ok, safe} <- safe_paths(dir, paths),
         {:ok, _} <- git(dir, ["checkout", "--" | safe]),
         do: :ok
  end

  # Enforce the moduledoc invariant: every path must be relative and stay within `dir`. Reject
  # absolute paths, `../` escapes, and leading-dash elements (which git would read as flags, e.g.
  # `-A` staging the whole tree). Without this an adapter/LLM-supplied path could clobber the repo.
  defp safe_paths(dir, paths) do
    paths
    |> Enum.reduce_while([], fn p, acc ->
      cond do
        not is_binary(p) -> {:halt, {:error, {:unsafe_path, p}}}
        String.starts_with?(p, "-") -> {:halt, {:error, {:unsafe_path, p}}}
        true -> safe_relative(p, dir, acc)
      end
    end)
    |> case do
      {:error, _} = err -> err
      list -> {:ok, Enum.reverse(list)}
    end
  end

  defp safe_relative(p, dir, acc) do
    case Path.safe_relative(p, dir) do
      {:ok, rel} -> {:cont, [rel | acc]}
      :error -> {:halt, {:error, {:unsafe_path, p}}}
    end
  end

  @doc "Run a raw git subcommand in `dir`. Exposed for setup (init, baseline commit) and tests."
  @spec git(Path.t(), [String.t()]) :: {:ok, String.t()} | {:error, term()}
  def git(dir, args) do
    case System.cmd("git", args, cd: dir, stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {out, code} -> {:error, {:git_failed, code, out}}
    end
  rescue
    e in ErlangError -> {:error, {:git_unavailable, e}}
  end
end
