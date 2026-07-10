defmodule Faber.Loop.Git do
  @moduledoc """
  Git as the loop's ratchet — HEAD always holds the current best skill.

  On **keep**: stage the skill path(s) and commit. On **revert**: `git checkout --` the path(s),
  discarding the failed mutation back to the last kept state. All operations are scoped to the
  given paths (relative to `dir`), so the loop can never touch unrelated files — the same safety
  invariant as the plugin's `git checkout -- {skill_dir}`.
  """

  @doc """
  Stage `paths` and commit with `message`. Returns `:ok` or `{:error, output}`.

  A candidate byte-identical to HEAD is a successful no-op (`:ok`, no commit made) — HEAD
  already holds it, and `git commit` exiting non-zero on "nothing to commit" must not read as a
  ratchet failure.
  """
  @spec commit(Path.t(), [String.t()], String.t()) :: :ok | {:error, term()}
  def commit(_dir, [], _message), do: :ok

  def commit(dir, paths, message) do
    with {:ok, safe} <- safe_paths(dir, paths),
         {:ok, _} <- git(dir, ["add", "--" | safe]) do
      if staged_changes?(dir, safe) do
        case git(dir, ["commit", "-m", message]) do
          {:ok, _} ->
            :ok

          {:error, _} = err ->
            # Un-stage what we just added (best-effort): `revert/2` restores the worktree FROM
            # the index, so a failed commit must not leave the candidate staged or the
            # follow-up revert would "restore" the very content whose commit failed.
            _ = git(dir, ["reset", "--" | safe])
            err
        end
      else
        :ok
      end
    end
  end

  # `git diff --quiet --cached` exits 0 only when the staged paths match HEAD. Non-zero means
  # staged changes (1) — or an unborn HEAD in a fresh repo (128); both must fall through to the
  # commit, so anything but a clean 0 counts as "changes present".
  defp staged_changes?(dir, safe) do
    case git(dir, ["diff", "--quiet", "--cached", "--" | safe]) do
      {:ok, _} -> false
      {:error, _} -> true
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
    # Local git ops are sub-second; a hung git (lock contention, credential prompt through a
    # misconfigured helper) must not stall the loop forever.
    case Faber.Subprocess.run("git", args,
           cd: dir,
           stderr_to_stdout: true,
           timeout: :timer.minutes(1)
         ) do
      {:error, :timeout} -> {:error, {:git_timeout, args}}
      {out, 0} -> {:ok, out}
      {out, code} -> {:error, {:git_failed, code, out}}
    end
  rescue
    e in ErlangError -> {:error, {:git_unavailable, e}}
  end
end
