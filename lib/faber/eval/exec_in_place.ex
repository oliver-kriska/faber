defmodule Faber.Eval.ExecInPlace do
  @moduledoc """
  Dispatch to an adapter's **referenced** scorer (`eval/eval.yaml` `mode: exec-in-place`).

  Some eval frameworks can't be vendored file-by-file: the reference plugin's `lab.eval` uses
  package-relative imports and `__file__`-relative paths, and must run with cwd = its own repo
  root. So the adapter *references* it in place (keeping the upstream at zero diffs) and this
  module runs it: `<entrypoints.score> <skill_path>` with cwd + `PYTHONPATH` = the resolved `root`,
  decoding the JSON it prints on stdout. See `docs/ADAPTER_CONTRACT.md` §7.0.

  ## The scorer takes a path, not stdin

  `python3 -m lab.eval.scorer` reads a **positional file path** and never reads stdin — unlike
  Faber's own sidecar. It also derives the skill's name from the *parent directory* of that path
  (`basename(dirname(skill_path))`) to look up a skill-specific eval definition. So the rendered
  SKILL.md is written to `<tmp>/<skill-name>/SKILL.md`: the name resolves, and a freshly proposed
  skill (which has no eval definition upstream) gets the framework's generic 8-dimension default.

  ## Failure is never silent

  Every failure path — unresolvable root, missing repo, non-zero exit, undecodable JSON — returns
  `{:error, reason}` so the caller can fall back to native scoring. It never fabricates a score.
  The caller is responsible for recording *which* engine actually scored the skill, because a PASS
  from a fallback must not be reported as the adapter's verdict.
  """

  alias Faber.{Adapter, Subprocess}

  @timeout_ms :timer.minutes(2)

  @doc """
  Score `skill_md` through `adapter`'s referenced scorer.

  Returns `{:ok, result}` with the scorer's decoded JSON (normalized to Faber's result shape), or
  `{:error, reason}` — the caller falls back to native.
  """
  @spec score(String.t(), Adapter.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def score(skill_md, %Adapter{} = adapter, opts \\ []) when is_binary(skill_md) do
    with {:ok, root} <- resolve_root(adapter),
         {:ok, command} <- entrypoint(adapter, "score"),
         {:ok, skill_path, tmp_root} <- write_skill(skill_md, skill_name(skill_md)) do
      try do
        run(command, skill_path, root, opts)
      after
        File.rm_rf(tmp_root)
      end
    end
  end

  defp run(command, skill_path, root, opts) do
    {bin, args} = split_command(command)
    timeout = opts[:timeout] || @timeout_ms

    case Subprocess.run(bin, args ++ [skill_path],
           cd: root,
           env: [{"PYTHONPATH", root}],
           stderr_to_stdout: false,
           timeout: timeout
         ) do
      {:error, :timeout} ->
        {:error, {:exec_in_place_timeout, timeout}}

      {out, 0} ->
        decode(out)

      # Never trust partial stdout from a failed run: an import error or traceback can still print
      # something that parses. Surface the exit code so the pack author can triage.
      {out, code} ->
        {:error, {:exec_in_place_exit, code, String.slice(out, 0, 500)}}
    end
  rescue
    # A missing interpreter/repo raises rather than returning a code — that's an environment gap,
    # not a scoring verdict, so it falls back like any other failure.
    e in [ErlangError, File.Error] -> {:error, {:exec_in_place_unavailable, e}}
  catch
    # `Subprocess.run_with_timeout/4` deliberately re-raises an abnormal task exit via `exit/1`
    # (subprocess.ex), and **no `rescue` clause can catch an exit** — only `catch :exit`. Without
    # this clause a scorer whose port dies abnormally (linked-process crash, `:brutal_kill` race)
    # unwinds straight through `score/3` and takes the eval pipeline down, instead of falling back
    # to native — the precise opposite of this module's "failure is never silent, the caller falls
    # back" contract. `Faber.CLI.guarded/1` pairs `rescue` + `catch` for the same reason.
    :exit, reason -> {:error, {:exec_in_place_unavailable, reason}}
  end

  defp decode(out) do
    case Jason.decode(out) do
      {:ok, %{"composite" => _} = result} -> {:ok, normalize(result)}
      {:ok, other} -> {:error, {:exec_in_place_bad_shape, other}}
      {:error, _} -> {:error, {:exec_in_place_bad_output, String.slice(out, 0, 500)}}
    end
  end

  # Map the referenced scorer's shape onto Faber's. `composite` is already weight-normalized and
  # the payload carries no `weight_total`, so 1.0 keeps `Eval.fold_behavioral/2`'s math exact.
  # Assertions use `type`/`desc` upstream where Faber's native shape uses `check_type` — translate,
  # so anything reading `dimensions` sees one shape regardless of which engine scored.
  defp normalize(result) do
    dimensions =
      result
      |> Map.get("dimensions", %{})
      |> Map.new(fn {name, dim} ->
        {name,
         dim
         |> Map.put("dimension", name)
         |> Map.update("assertions", [], fn assertions ->
           Enum.map(assertions, &normalize_assertion/1)
         end)}
      end)

    %{
      "composite" => result["composite"],
      "dimensions" => dimensions,
      "weight_total" => 1.0
    }
  end

  defp normalize_assertion(%{} = a) do
    a
    |> Map.put_new("check_type", a["type"])
    |> Map.put_new("evidence", a["desc"])
  end

  defp normalize_assertion(other), do: other

  defp resolve_root(adapter) do
    case Adapter.eval_root(adapter) do
      nil ->
        {:error, {:exec_in_place_root_unresolved, adapter.eval["root"]}}

      root ->
        # Checked at score time, not load time: the referenced repo is environment-bound, so a
        # machine without it must still load the adapter and simply fall back here.
        if File.dir?(root),
          do: {:ok, root},
          else: {:error, {:exec_in_place_root_missing, root}}
    end
  end

  defp entrypoint(%Adapter{eval: eval}, key) do
    case get_in(eval, ["entrypoints", key]) do
      cmd when is_binary(cmd) and cmd != "" -> {:ok, cmd}
      other -> {:error, {:exec_in_place_no_entrypoint, key, other}}
    end
  end

  # The entrypoint is a command string from a declarative pack (`python3 -m lab.eval.scorer`). It
  # is split on whitespace and executed WITHOUT a shell — no interpolation, globbing, or `;`
  # chaining — so a pack cannot smuggle shell metacharacters into a subshell.
  defp split_command(command) do
    [bin | args] = String.split(command)
    {bin, args}
  end

  # `<tmp>/<skill-name>/SKILL.md`: the scorer reads the skill's name from the parent directory.
  #
  # This literal is deliberately NOT derived from `Faber.Proposal.filename/1`, unlike every other
  # write seam. It is the *upstream scorer's* contract, not Faber's naming choice: `lab.eval.scorer`
  # reads a SKILL.md and parses skill frontmatter out of it. Writing a `kind: :hook` proposal here
  # as `hook.sh` wouldn't make the scorer understand hooks — it would just fail differently. This
  # path is skill-only by construction; hooks are scored by `Faber.Eval.Native`'s hook eval set
  # (which is why that set exists), and `Faber.Eval` routes on kind before reaching here.
  #
  # The body is derived from the user's private session transcript, so lock the tree down before it
  # lands: 0700 on the root, O_EXCL + 0600 on the file — the same treatment
  # `Faber.Sidecar.System.write_temp/1` gives an equally sensitive payload. Defaults (0755/0644 under
  # a typical umask) would leave it readable for the scorer's whole run, and `/tmp` is world-listable
  # on stock macOS/Linux, so on a shared dev box or CI host that is a real (if time-boxed) leak.
  # The random root name defeats symlink pre-planting; these perms defeat the reader.
  #
  # NOTE: this runs OUTSIDE `run/4`'s rescue/catch, so it must return errors rather than raise.
  defp write_skill(skill_md, name) do
    root = Path.join(System.tmp_dir!(), "faber-eval-#{rand_token()}")
    dir = Path.join(root, name)
    path = Path.join(dir, "SKILL.md")

    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(root, 0o700),
         :ok <- write_private(path, skill_md) do
      {:ok, path, root}
    else
      {:error, reason} -> {:error, {:tmp_write_failed, reason}}
    end
  end

  defp write_private(path, content) do
    case File.open(path, [:write, :exclusive, :binary]) do
      {:ok, io} ->
        IO.binwrite(io, content)
        File.close(io)
        File.chmod(path, 0o600)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The scorer keys its eval lookup on this, so prefer the skill's own frontmatter `name`. Sanitized
  # to one path segment: the name comes from LLM-generated frontmatter and becomes a directory.
  defp skill_name(skill_md) do
    case Regex.run(~r/^\s*name:\s*(.+?)\s*$/m, skill_md) do
      [_, name] -> sanitize(name)
      _ -> "faber-skill"
    end
  end

  # Reduce to one safe path segment. Separators become `-`, so `../../etc/pwned` collapses to the
  # harmless literal `..-..-etc-pwned`. The bare `.`/`..` cases still have to be rejected by name:
  # they survive the character filter intact and `Path.join(tmp, "..")` would escape the temp dir.
  defp sanitize(name) do
    name
    |> String.trim()
    |> String.replace(~r/[^A-Za-z0-9._-]/, "-")
    |> String.trim("-")
    |> String.slice(0, 80)
    |> case do
      safe when safe in ["", ".", ".."] -> "faber-skill"
      safe -> safe
    end
  end

  defp rand_token, do: :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
end
