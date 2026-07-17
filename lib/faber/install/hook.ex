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

  Two shapes, differing only in where the script text comes from:

    * `%Proposal{kind: :hook}` — rendered through `:adapter`'s template. The fresh
      propose→eval→install path, where render, eval and install all run in one process against one
      loaded pack, so the bytes provably agree.
    * `{name, md, event, matcher}` — the already-rendered bytes, written as given. The restore path
      (`Faber.Proposal.Store`), and the same shape `Install.install({name, md})` has always used for
      a restored skill. Returns `{:error, :no_pointer}` when `event`/`matcher` are absent, which is
      what a pre-format-3 record looks like.

  Both are refused by the safety veto at the write boundary; the bytes shape is not a way past it.
  """
  @spec install(
          Proposal.t() | {String.t(), String.t(), String.t() | nil, String.t() | nil},
          keyword()
        ) :: {:ok, %{script: Path.t(), settings: Path.t()}} | {:error, term()}
  def install(proposal_or_bytes, opts \\ [])

  def install(%Proposal{kind: :hook} = p, opts) do
    do_install(p.name, p.event, p.matcher, {:proposal, p}, opts)
  end

  def install(%Proposal{kind: kind}, _opts), do: {:error, {:not_a_hook, kind}}

  def install({name, md, event, matcher}, opts) when is_binary(name) and is_binary(md) do
    do_install(name, event, matcher, {:bytes, md}, opts)
  end

  defp do_install(name, event, matcher, source, opts) do
    settings_path = opts[:settings_path] || settings_path()

    # Decide the settings merge BEFORE writing the script, so a refusal (hand-edited pointer,
    # unreadable settings) leaves nothing on disk. The script is still written before the settings
    # are saved: if that save then fails, an inert script is orphaned — which is the safe direction.
    # A pointer to a script that isn't there is a hook Claude Code tries to run on every matching
    # call and can't.
    with :ok <- check_pointer(event, matcher),
         {:ok, settings} <- read_settings(settings_path),
         script_path = script_path(name, opts),
         {:ok, merged} <- merge_pointer(settings, event, matcher, script_path, opts),
         {:ok, ^script_path} <- write_script(source, name, opts),
         :ok <- File.chmod(script_path, 0o755),
         :ok <- save_settings(settings_path, merged) do
      {:ok, %{script: script_path, settings: settings_path}}
    end
  end

  # A pointer with no event or no matcher cannot be written into settings.json — `oput(hooks, nil,
  # …)` would produce a `null` key rather than fail. Reachable from the bytes path: a pre-format-3
  # store record has no `event`/`matcher` (they were only persisted from format 3 on), so a hook
  # drafted before that bump restores with its script but without its pointer.
  defp check_pointer(event, matcher) when is_binary(event) and is_binary(matcher), do: :ok
  defp check_pointer(_event, _matcher), do: {:error, :no_pointer}

  # The script text, from whichever end the caller has:
  #
  #   * `{:proposal, p}` — RENDER through the pack. The fresh propose→eval→install path, where the
  #     render, the eval and the install all happen in one process against one loaded pack, so the
  #     bytes provably agree.
  #   * `{:bytes, md}` — write the bytes AS GIVEN. The restore path, where the pack could have been
  #     edited since the draft was scored and stored. Re-rendering there would write something other
  #     than what the eval scored and — the part that matters — other than what the human confirmed.
  #     The install posture is "no hook is written without a human seeing the script"; that is only
  #     true if the seen bytes are the written bytes. Mirrors `Install.install({name, md})`, which
  #     is how a restored SKILL has always installed.
  #
  # Both go through `Install.install/2`, so both are refused by the safety veto at the write
  # boundary — the bytes path is not a way around it.
  defp write_script({:proposal, p}, _name, opts) do
    Install.install(p, Keyword.put_new(opts, :dir, default_dir()))
  end

  defp write_script({:bytes, md}, name, opts) do
    Install.install(
      {name, md},
      opts
      |> Keyword.put_new(:dir, default_dir())
      |> Keyword.put(:kind, :hook)
      |> Keyword.put(:filename, Proposal.filename(:hook))
    )
  end

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
  @spec script_path(Proposal.t() | String.t(), keyword()) :: Path.t()
  def script_path(proposal_or_name, opts \\ [])

  def script_path(%Proposal{} = p, opts), do: script_path(to_string(p.name), opts)

  # A hook's script path is a function of its NAME, not of the rest of the proposal — which is what
  # lets the restore path (`{name, md, event, matcher}`) compute the same path for the same hook.
  def script_path(name, opts) when is_binary(name) do
    Path.join([opts[:dir] || default_dir(), name, Proposal.filename(:hook)])
  end

  # `Faber.Install.install/2` does the whole write: it validates the (untrusted) name, runs the
  # safety veto against the exact bytes it is about to write — with `kind: :hook`, so a `##` shell
  # comment can't buy an exemption meant for prose — creates the dir, writes, and drops the
  # `.faber.json` marker. Nothing here re-implements any of that.

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
      {:ok, %Jason.OrderedObject{} = obj} -> check_hooks(obj, path)
      {:ok, other} -> {:error, {:settings_not_an_object, path, other}}
      {:error, reason} -> {:error, {:settings_invalid_json, path, reason}}
    end
  end

  # The `hooks` VALUE gets the same guard as the top level, and at the same boundary — this is the
  # one place that turns the user's bytes into something the merge trusts.
  #
  # `"hooks": null` is the case that bites: `List.keyfind/3` MATCHES `{"hooks", nil}`, so `oget/3`
  # finds the key and returns `nil` — its `default` never fires, because the key is present. `nil`
  # then reaches `oput/3`, which has no clause for it, and a plausible hand-edit crashes the
  # LiveView process or the mix task with a FunctionClauseError instead of returning `{:error, …}`.
  # Availability only: nothing is corrupted, since the crash precedes `save_settings/2`.
  #
  # Refusing rather than "helpfully" treating it as `{}` is the same posture as the top-level guard:
  # a `hooks` key we cannot merge into means the file does not say what we think it says, and
  # writing our own idea of it over the top is how a writer destroys the thing it is protecting.
  defp check_hooks(%Jason.OrderedObject{values: values} = obj, path) do
    case List.keyfind(values, "hooks", 0) do
      # Absent is normal — the first hook on a fresh machine.
      nil -> {:ok, obj}
      {_, %Jason.OrderedObject{}} -> {:ok, obj}
      {_, other} -> {:error, {:settings_hooks_not_an_object, path, other}}
    end
  end

  # S3/PE-T5. Write to a sibling tmp file and `rename` over the target — `rename(2)` is atomic within
  # a filesystem, and the tmp is a sibling precisely so it is on the same one.
  #
  # This was `File.write/2`, which opens the target with O_TRUNC: the user's settings.json is emptied
  # *first*, and only then refilled. Anything that stops the VM in that window (^C on `faber propose
  # --install`, an OOM kill, a `mix` task shutdown) leaves the file truncated — and that file is not
  # Faber's. It carries the user's permissions, MCP servers, env, and every hook they wrote
  # themselves. Losing Faber's own pointer would be an inconvenience; this loses THEIR config, to
  # install a hook they asked for. `Faber.write_private/2` documents exactly this hazard for Faber's
  # own files — the hook installer just wasn't using it.
  #
  # It cannot simply CALL `write_private/2`, hence the near-duplicate: that helper chmods to `0600`,
  # which is right for a file Faber owns inside its own `0700` dir and wrong here. settings.json
  # belongs to the user (typically `0644`), and silently narrowing the mode of a shared file we did
  # not create is the enumerate-and-claim mistake in another costume. So: preserve the existing mode
  # when there is one, and let a genuinely new file take the umask default.
  #
  # RESIDUAL, deliberately not "fixed" here: read→merge→write is still not serialized, so a writer
  # that lands inside our window has its change reverted — a lost update, **not** a corrupt file.
  # That claim is only true because the tmp path is unique per write (see `tmp_path/1`); with a fixed
  # name it was false, and this comment was the thing asserting it. The window is the read→write gap
  # and every writer is human-triggered behind a confirm — the CLI and the dashboard;
  # `faber_propose_hook` does not write at all. Closing it properly needs a cross-process lock, and a
  # stale lockfile from a crashed run that blocks every future install is a worse and much more
  # likely failure than the race it prevents. Named rather than papered over.
  defp save_settings(path, obj) do
    # `rename` REPLACES the name it is given — so renaming onto a symlink replaces the LINK with a
    # regular file, silently orphaning whatever it pointed at. Symlinking `~/.claude/settings.json`
    # into a dotfiles repo is ordinary, and this failed it silently in the worst direction:
    # `File.write/2` (what this used to be) FOLLOWS a link, so the old code wrote through to the
    # dotfiles copy and the "safer" atomic rename is what broke it. Reproduced: the link became a
    # regular file, the dotfiles target kept the pre-install content, and nothing errored.
    target = resolve_link(path)
    tmp = tmp_path(target)
    body = Jason.encode!(obj, pretty: true) <> "\n"

    with :ok <- File.mkdir_p(Path.dirname(target)),
         :ok <- File.write(tmp, body),
         :ok <- copy_mode(target, tmp),
         :ok <- File.rename(tmp, target) do
      :ok
    else
      {:error, _} = err ->
        File.rm(tmp)
        err
    end
  end

  # Follow a symlink to the file that must actually be replaced. Bounded rather than recursive
  # without a limit: a link cycle is a hang otherwise, and `~/.claude/settings.json` is a path the
  # user owns and can point wherever they like. Out of links (or over the bound) → use what we have;
  # a broken or circular link is not this function's error to raise, and the `File.write` below
  # reports it honestly.
  @link_hops 8

  defp resolve_link(path, hops \\ @link_hops)
  defp resolve_link(path, 0), do: path

  defp resolve_link(path, hops) do
    case File.read_link(path) do
      # A relative link resolves against the LINK's directory, not the cwd.
      {:ok, dest} -> dest |> Path.expand(Path.dirname(path)) |> resolve_link(hops - 1)
      {:error, _} -> path
    end
  end

  # A unique tmp per write. `path <> ".faber.tmp"` was a FIXED name, so two writers in different OS
  # processes (the CLI and the dashboard) shared one path: B's `O_TRUNC` write landed mid-flight and
  # A renamed the truncated bytes into place — reporting `{:ok, …}`. That is a corrupt file through a
  # window as wide as a `write`, i.e. wider than the one the atomic rename closed, and it made the
  # RESIDUAL note above untrue. It also closes a guessable-path pre-plant: an attacker who symlinks
  # the predictable tmp name at a file they want clobbered no longer knows where to aim.
  #
  # Not `File.rename`-safe across filesystems, hence a SIBLING: `rename(2)` is atomic only within one
  # filesystem, and the tmp sits beside the resolved target precisely so it is on the same one.
  defp tmp_path(target) do
    suffix = 6 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    target <> ".faber-" <> suffix <> ".tmp"
  end

  # Carry the target's mode onto the replacement. `rename` swaps the inode, so without this an
  # install would silently reset settings.json to the umask default.
  defp copy_mode(path, tmp) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} -> File.chmod(tmp, mode)
      # No file yet — first hook on a fresh machine. The umask default is the right answer.
      {:error, :enoent} -> :ok
      # DEFENCE, not a live path: `read_settings/1` has already read this file, so every stat-level
      # failure (:eacces, :eloop, :eisdir) is reported there and returns before `save_settings/2` is
      # called. Reachable only by a race between the read and this line. Kept because it costs one
      # clause and the alternative — a `{:ok, _} =` match — would turn that race into a crash.
      # Deliberately NOT given a test that fakes reachability: a test that has to bypass the public
      # API to fail proves the mock works, not the code.
      {:error, _} = err -> err
    end
  end

  # The merge. `:unchanged` is returned as-is by `save_settings`'s caller writing identical bytes —
  # cheap, and it keeps the function total.
  defp merge_pointer(settings, event, matcher, script_path, opts) do
    hooks = oget(settings, "hooks", empty())
    entries = oget(hooks, event, [])

    with {:ok, entries} <- put_command(entries, matcher, script_path, opts) do
      {:ok, oput(settings, "hooks", oput(hooks, event, entries))}
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
    |> Enum.reduce_while(:none, fn hook, _acc ->
      # S2. Was an `Enum.reduce` carrying an `acc != :none -> acc` guard, i.e. it walked the whole
      # list and then ignored everything after the first match. Same answer, but it described a
      # fold over all entries when the operation is "find the first" — and the guard was the only
      # thing standing between that and a later entry overwriting the verdict.
      if hook == ours,
        do: {:halt, {:exact, script_path}},
        else: {:halt, {:altered, oget(hook, "command", script_path)}}
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
