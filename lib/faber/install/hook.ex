defmodule Faber.Install.Hook do
  @moduledoc """
  **Pipeline tail — install a hook.** Write an accepted `kind: :hook` proposal's script into a
  Faber-owned dir and point `settings.json` at it, so Claude Code actually runs it.

  Two artifacts, deliberately:

    * **the script** — `<hooks_dir>/<name>/hook.sh`, plus the same `.faber.json` provenance marker
      every Faber-installed artifact carries. This is `Faber.Install.install/2` verbatim (with
      `dir:`/`filename:`/`kind:`), not a parallel writer: name validation, the write-boundary safety
      veto **on the exact bytes**, and the marker all come along unforked. A second writer would be a
      second place for the veto to drift out of.
    * **the pointer** — one entry in `~/.claude/settings.json`, the smallest possible footprint in a
      file Faber does not own.

  Splitting them is what keeps the shared-JSON problem small. The alternative — a JSON managed block
  — would mean inventing one: `Faber.Install.ManagedBlock` is HTML-comment delimited and works on
  markdown only. Its *idea* survives here anyway (see "Never clobber").

  ## settings.json is the user's file

  Every rule below follows from that one fact.

    * **Merge at the event level.** Append to `hooks.<Event>[]`, creating the event key when absent.
      Never replace the `hooks` object — a user's `PostToolUse` hooks must survive a `PreToolUse`
      install untouched. Multiple hooks on one event run in parallel, so appending is well-defined.
    * **Preserve key order.** The file is read with `Jason`'s `:ordered_objects` and re-encoded, so
      unrelated keys keep their positions. A plain decode returns a map and would silently reorder
      the user's whole file — a diff on every line of something Faber didn't write. Whitespace still
      normalizes; that is as far as JSON allows.
    * **Idempotent.** Re-installing the same hook is a no-op: the pointer is recognized by the script
      path it names, so the second install finds it and changes nothing.
    * **Never clobber a hand-edit.** If our pointer is present but *altered* (a timeout added, the
      command wrapped), that is the user's edit to a line they own. Installing over it silently is
      the exact thing `ManagedBlock`'s digest guard exists to prevent, so it errors with
      `{:error, {:hand_edited, command}}` unless `:force`.
  """

  alias Faber.{Install, Proposal}

  @doc """
  Install a hook: write its script, then point `settings.json` at it.

  Options: `:dir` (hooks root), `:settings_path`, `:adapter` (render through the pack's `hook`
  template — the same bytes `Faber.Eval` gated), `:force` (overwrite an existing script and adopt a
  hand-edited pointer). Returns `{:ok, %{script: path, settings: path}}` or `{:error, reason}` —
  including `{:error, {:vetoed, vetoes}}` when the script must never be written, `{:error, {:exists,
  path}}`, and `{:error, {:hand_edited, command}}`.
  """
  @spec install(Proposal.t(), keyword()) ::
          {:ok, %{script: Path.t(), settings: Path.t()}} | {:error, term()}
  def install(proposal, opts \\ [])

  def install(%Proposal{kind: :hook} = p, opts) do
    settings_path = opts[:settings_path] || settings_path()

    # Decide the settings merge BEFORE writing the script, so a refusal (hand-edited pointer,
    # unreadable settings) leaves nothing on disk. The script is still written before the settings
    # are saved: if that save then fails, an inert script is orphaned — which is the safe direction.
    # A pointer to a script that isn't there is a hook Claude Code tries to run on every matching
    # call and can't.
    with {:ok, settings} <- read_settings(settings_path),
         script_path = script_path(p, opts),
         {:ok, merged} <- merge_pointer(settings, p, script_path, opts),
         {:ok, ^script_path} <- write_script(p, opts),
         :ok <- File.chmod(script_path, 0o755),
         :ok <- save_settings(settings_path, merged) do
      {:ok, %{script: script_path, settings: settings_path}}
    end
  end

  def install(%Proposal{kind: kind}, _opts), do: {:error, {:not_a_hook, kind}}

  @doc """
  The Faber-owned hooks root. Its own dir, not `~/.claude/skills` — a hook is not a skill, and skill
  discovery walks that tree looking for `SKILL.md`.
  """
  @spec default_dir() :: Path.t()
  def default_dir do
    Application.get_env(:faber, :hooks_dir, Path.join(home(), ".claude/faber-hooks"))
  end

  @doc "The user-scope settings file the pointer is written into."
  @spec settings_path() :: Path.t()
  def settings_path do
    Application.get_env(:faber, :settings_path, Path.join(home(), ".claude/settings.json"))
  end

  @doc """
  Where this hook's script lives (or would live). Pure — it touches nothing.
  """
  @spec script_path(Proposal.t(), keyword()) :: Path.t()
  def script_path(%Proposal{} = p, opts \\ []) do
    Path.join([opts[:dir] || default_dir(), to_string(p.name), Proposal.filename(p)])
  end

  # `Faber.Install.install/2` does the whole write: it validates the (untrusted) name, runs the
  # safety veto against the exact bytes it is about to write — with `kind: :hook`, so a `##` shell
  # comment can't buy an exemption meant for prose — creates the dir, writes, and drops the
  # `.faber.json` marker. Nothing here re-implements any of that.
  defp write_script(%Proposal{} = p, opts) do
    Install.install(p, Keyword.put_new(opts, :dir, default_dir()))
  end

  # ── settings.json ──────────────────────────────────────────────────────────

  defp read_settings(path) do
    case File.read(path) do
      {:ok, body} -> decode_settings(body, path)
      # No settings file yet is normal, not an error — this is the first hook on a fresh machine.
      {:error, :enoent} -> {:ok, empty()}
      {:error, reason} -> {:error, {:settings_unreadable, path, reason}}
    end
  end

  # An unparseable settings.json is where a writer must stop, not "helpfully" start fresh: the file
  # has the user's own configuration in it, and overwriting it with a one-key object because we
  # couldn't read it would destroy exactly what we are trying not to touch.
  defp decode_settings(body, path) do
    case Jason.decode(body, objects: :ordered_objects) do
      {:ok, %Jason.OrderedObject{} = obj} -> {:ok, obj}
      {:ok, other} -> {:error, {:settings_not_an_object, path, other}}
      {:error, reason} -> {:error, {:settings_invalid_json, path, reason}}
    end
  end

  defp save_settings(path, obj) do
    with :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, Jason.encode!(obj, pretty: true) <> "\n")
    end
  end

  # The merge. `:unchanged` is returned as-is by `save_settings`'s caller writing identical bytes —
  # cheap, and it keeps the function total.
  defp merge_pointer(settings, %Proposal{} = p, script_path, opts) do
    hooks = oget(settings, "hooks", empty())
    entries = oget(hooks, p.event, [])

    with {:ok, entries} <- put_command(entries, p.matcher, script_path, opts) do
      {:ok, oput(settings, "hooks", oput(hooks, p.event, entries))}
    end
  end

  # Place our command among this event's entries:
  #
  #   * ours already there, byte-identical → no-op (re-install is idempotent)
  #   * ours there but ALTERED → the user edited a line they own; refuse unless :force
  #   * an entry with our matcher → append our command to it (its other hooks stay)
  #   * otherwise → append a new entry (every other entry untouched)
  defp put_command(entries, matcher, script_path, opts) do
    case find_ours(entries, script_path) do
      {:exact, _} ->
        {:ok, entries}

      {:altered, command} ->
        if opts[:force],
          do: {:ok, replace_ours(entries, script_path, matcher)},
          else: {:error, {:hand_edited, command}}

      :none ->
        {:ok, add_command(entries, matcher, script_path)}
    end
  end

  # Recognize our own pointer by the script path its command names — nothing else in the file points
  # at that path — then compare the WHOLE hook object against what we would write. This is the JSON
  # analogue of the managed block's digest, and the object is the unit that must match, not the
  # command string: a user who adds `"timeout": 5` beside an untouched command has edited our
  # pointer just as surely as one who rewrote the command, and comparing strings alone would call
  # that identical and then silently drop their timeout on the next `--force`.
  defp find_ours(entries, script_path) do
    ours = command_hook(script_path)

    entries
    |> Enum.flat_map(&oget(&1, "hooks", []))
    |> Enum.filter(&mentions?(&1, script_path))
    |> Enum.reduce(:none, fn hook, acc ->
      cond do
        acc != :none -> acc
        hook == ours -> {:exact, script_path}
        true -> {:altered, oget(hook, "command", script_path)}
      end
    end)
  end

  defp mentions?(hook, script_path) do
    command = oget(hook, "command", nil)
    is_binary(command) and String.contains?(command, script_path)
  end

  defp add_command(entries, matcher, script_path) do
    case Enum.find_index(entries, &(oget(&1, "matcher", nil) == matcher)) do
      nil ->
        entries ++ [new_entry(matcher, script_path)]

      idx ->
        List.update_at(entries, idx, fn entry ->
          oput(entry, "hooks", oget(entry, "hooks", []) ++ [command_hook(script_path)])
        end)
    end
  end

  # Only reachable under `:force`: drop every trace of our path, then add it back clean.
  defp replace_ours(entries, script_path, matcher) do
    entries
    |> Enum.map(fn entry ->
      oput(entry, "hooks", Enum.reject(oget(entry, "hooks", []), &mentions?(&1, script_path)))
    end)
    # An entry whose only hook was ours is now empty and would be a matcher pointing at nothing.
    |> Enum.reject(&(oget(&1, "hooks", []) == []))
    |> add_command(matcher, script_path)
  end

  defp new_entry(matcher, script_path) do
    ordered([{"matcher", matcher}, {"hooks", [command_hook(script_path)]}])
  end

  defp command_hook(script_path) do
    ordered([{"type", "command"}, {"command", script_path}])
  end

  # ── Jason.OrderedObject helpers ────────────────────────────────────────────
  #
  # `oput/3` replaces IN PLACE when the key exists and appends otherwise, which is what preserves the
  # user's key order: a delete-then-append would quietly move `hooks` to the end of their file.

  defp empty, do: ordered([])
  defp ordered(pairs), do: %Jason.OrderedObject{values: pairs}

  defp oget(%Jason.OrderedObject{values: values}, key, default) do
    case List.keyfind(values, key, 0) do
      {^key, value} -> value
      nil -> default
    end
  end

  defp oget(_other, _key, default), do: default

  defp oput(%Jason.OrderedObject{values: values} = obj, key, value) do
    if List.keymember?(values, key, 0),
      do: %{obj | values: List.keyreplace(values, key, 0, {key, value})},
      else: %{obj | values: values ++ [{key, value}]}
  end

  defp home, do: System.user_home!()
end
