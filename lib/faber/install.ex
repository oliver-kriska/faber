defmodule Faber.Install do
  @moduledoc """
  **Pipeline tail — install.** Write an accepted proposal's `SKILL.md` into a skills directory so a
  coding agent can load it.

  The default target is `config :faber, :skills_dir` (falling back to `~/.claude/skills`). Existing
  skills are never silently overwritten — pass `force: true` to replace.

  **Quality gating** — did the proposal clear the eval bar? — is the caller's business
  (`Faber.Eval.gate/2` is the natural guard). **Safety** is not: `install/2` enforces the
  `Faber.Eval.vetoes/1` refusal on the bytes it is about to write, itself, so a dangerous artifact
  cannot be installed no matter what any caller checked or skipped. See `install/2`.
  """

  alias Faber.{Eval, Proposal, Propose}
  alias Faber.Install.ManagedBlock

  # A skill name becomes a path segment, so it must be a single lowercase-kebab token — same shape
  # the adapter enforces for its own name. This is the security boundary: the name originates from
  # LLM output mined from UNTRUSTED transcripts, so an unvalidated `name` like "../../etc/foo" (or
  # an absolute path, which `Path.join` would honor) would escape the skills directory.
  @name_re ~r/\A[a-z0-9][a-z0-9-]{0,63}\z/

  # Provenance sentinel written beside each installed SKILL.md. Its presence is how Faber tells the
  # skills IT installed apart from a user's own skills sharing the same dir (`~/.claude/skills` is
  # not Faber-dedicated). The cross-agent pointer + the MCP listing filter on it, so syncing never
  # claims a pre-existing skill as Faber-managed. Hidden + JSON so it never collides with skill
  # discovery (which reads `SKILL.md`) and can carry richer provenance later.
  @marker ".faber.json"

  # The marker's read policy. `unstamped: 1` is load-bearing and NOT a formality: markers written
  # before this declaration already exist in real `~/.claude` trees (Oliver's included), they
  # predate the key, and `faber_installed?/1` is what makes a skill Faber's to sync, list and
  # update. A reader that demanded `format` would classify every existing install as "not ours" —
  # orphaning them from the pointer and the MCP listing in one release. That is precisely the bug
  # `Faber.Store.Format` exists to prevent, so it is not re-introduced while fixing its class.
  #
  # `data_class: :provenance` — this is a claim about the user's shared dir, not paid work, but it
  # is not derived either: nothing can recompute which skills Faber installed once the markers are
  # gone. Reads stay lenient (any map) for the same reason they always were: a marker that fails to
  # parse must not make Faber disown a skill it installed.
  use Faber.Store.Format,
    format: 1,
    readable_formats: [1],
    data_class: :provenance,
    unstamped: 1

  @doc """
  Install `proposal` (or a `{name, skill_md}` pair) under `<dir>/<name>/SKILL.md`.

  Options: `:dir` (target skills root; defaults to the configured dir), `:adapter` (render a
  `%Proposal{}` via the adapter's template, matching what `Faber.Eval` gated), `:force` (overwrite
  an existing skill). Returns `{:ok, path}` or `{:error, reason}` — including
  `{:error, {:exists, path}}` when already installed and `force` is not set,
  `{:error, {:invalid_name, name}}` when the name isn't a safe path segment, or
  `{:error, {:vetoed, vetoes}}` when the content itself must never be written (see below).

  ## The safety veto is enforced here, not by the caller

  This function refuses to write an artifact that fails `Faber.Eval.vetoes/1` — dangerous shell and
  friends — regardless of what any eval said, whether an eval ran at all, or whether `force` is set.
  `:force` overrides an *overwrite conflict*; it is not a safety override, and the two are kept
  orthogonal deliberately.

  It lives here because this is the only function that writes into the user's `~/.claude/skills`,
  and it checks the exact bytes it is about to write — no window between the check and the use. The
  alternative, threading a verdict through every caller, was measured and failed: of four callers,
  `Faber.Schedule` and the MCP tool gated on `passed`, `Faber.CLI` passed the `--install` flag
  where the verdict belonged, and `FaberWeb.DashboardLive` gated on nothing. Each new caller is
  another chance to forget, and forgetting is silent. A veto every caller must remember to honor is
  a suggestion; one the writer enforces is a veto.

  Also writes a `#{@marker}` provenance sentinel beside the `SKILL.md` so `list_faber_installed/1`
  can distinguish Faber's skills from the user's own in a shared skills dir.
  """
  @spec install(Proposal.t() | {String.t(), String.t()}, keyword()) ::
          {:ok, Path.t()} | {:error, term()}
  def install(proposal_or_pair, opts \\ [])

  def install(%Proposal{} = p, opts) do
    md = Propose.render(p, opts[:adapter])

    # Carry where the skill came from into the provenance marker (no transcript `path` — that's an
    # internal location the privacy boundary keeps out of projections).
    provenance =
      drop_nils(%{
        "adapter" => p.adapter,
        "source_session" => p.source[:session_id],
        "fingerprint" => p.source[:fingerprint]
      })

    install(
      {p.name, md},
      opts
      |> Keyword.put(:provenance, provenance)
      # The artifact filename follows the kind (`Faber.Proposal.filename/1`) rather than being the
      # literal "SKILL.md" spelled out here. `put_new` so an explicit caller override still wins.
      |> Keyword.put_new(:filename, Proposal.filename(p))
      # How the veto must READ these bytes. A hook is executable, so it gets no safe-section
      # exemption — see `Faber.Eval.vetoes/2`.
      |> Keyword.put_new(:kind, p.kind)
    )
  end

  def install({name, skill_md}, opts) when is_binary(name) and is_binary(skill_md) do
    # `validate_name/1` and `refuse_vetoed/1` are the first two steps, so no path is touched on disk
    # until the (untrusted) name AND the (untrusted) content are both proven safe; the `=` bindings
    # below are pure (`Path.join`), run only after that. Same shape for both: this function is handed
    # two untrusted things, and neither gets to reach the filesystem unexamined.
    with :ok <- validate_name(name),
         # `:kind` reaches here from the `%Proposal{}` clause; a bare `{name, md}` pair defaults to
         # `:skill`, the stricter reading for markdown and the historical behavior.
         :ok <- refuse_vetoed(skill_md, opts[:kind] || :skill),
         skill_dir = Path.join(opts[:dir] || default_dir(), name),
         path = Path.join(skill_dir, opts[:filename] || "SKILL.md"),
         :ok <- ensure_writable(path, opts),
         :ok <- File.mkdir_p(skill_dir),
         :ok <- File.write(path, skill_md),
         :ok <- write_marker(skill_dir, name, Keyword.put(opts, :skill_md, skill_md)) do
      {:ok, path}
    end
  end

  defp validate_name(name) do
    if Regex.match?(@name_re, name), do: :ok, else: {:error, {:invalid_name, name}}
  end

  # The last line before the bytes hit the user's dir. Deliberately NOT overridable by `:force` and
  # not skippable by an `opts` key: an escape hatch here would be found and used by exactly the paths
  # that should never have one, and "the caller said it was fine" is what this check exists to
  # disbelieve. If a legitimate skill needs to document `rm -rf /`, it says so under a heading that
  # announces it (`## Anti-patterns`, `## Gotchas`) — the matcher exempts those by design, so the
  # honest case has a supported route and the smuggled case does not.
  defp refuse_vetoed(skill_md, kind) do
    case Eval.vetoes(skill_md, kind) do
      [] -> :ok
      vetoes -> {:error, {:vetoed, vetoes}}
    end
  end

  # `:ok` when nothing is installed there yet (or `:force` is set), else the already-installed error.
  defp ensure_writable(path, opts) do
    if File.exists?(path) and not Keyword.get(opts, :force, false),
      do: {:error, {:exists, path}},
      else: :ok
  end

  # Stamp the provenance sentinel so `list_faber_installed/1` (and thus the pointer + MCP listing)
  # can recognize this skill as Faber-installed. Best-effort richness, stable keys so it stays
  # deterministic for tests. `installed_at` lets `Faber.Feedback` scope its outer-loop usage
  # report to sessions that ran after the skill existed.
  defp write_marker(skill_dir, name, opts) do
    data =
      Map.merge(
        %{
          "format" => format(),
          "installed_by" => "faber",
          "name" => name,
          "installed_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
          # What Faber actually wrote. Without it, a later install can see that the file on disk
          # differs from what it is about to write, but not WHOSE change that is — Faber's own
          # newer draft, or the user's hand-edit. Only the second is destructive, and that is the
          # distinction `drift?/1` exists to make (same idea as the managed block's digest in
          # `sync`, which refuses to clobber hand-edited text).
          "skill_sha256" => digest(opts[:skill_md] || "")
        },
        opts[:provenance] || %{}
      )

    File.write(Path.join(skill_dir, @marker), Jason.encode!(data) <> "\n")
  end

  @doc """
  Whether the installed `SKILL.md` at `path` has been edited since Faber wrote it.

  `false` when there is no marker, no recorded hash (a skill installed before this was tracked), or
  the file is unreadable: **unknown is reported as not-drifted**, never as drifted. Claiming someone
  hand-edited a file we simply can't verify would train them to `--force` past a warning that cries
  wolf, which is worse than not warning at all.
  """
  @spec drift?(Path.t()) :: boolean()
  def drift?(path) do
    marker = path |> Path.dirname() |> Path.join(@marker)

    with {:ok, marker_body} <- File.read(marker),
         {:ok, %{"skill_sha256" => recorded}} when is_binary(recorded) <-
           Jason.decode(marker_body),
         {:ok, installed} <- File.read(path) do
      digest(installed) != recorded
    else
      _ -> false
    end
  end

  defp digest(contents) do
    :sha256 |> :crypto.hash(contents) |> Base.encode16(case: :lower)
  end

  defp drop_nils(map), do: :maps.filter(fn _k, v -> not is_nil(v) end, map)

  @doc "The configured skills directory (`config :faber, :skills_dir`, default `~/.claude/skills`)."
  @spec default_dir() :: Path.t()
  def default_dir do
    Application.get_env(:faber, :skills_dir, Path.join(home(), ".claude/skills"))
  end

  # ── cross-agent pointers (managed block) ───────────────────────────────────
  #
  # Installing a skill writes a dedicated `<dir>/<name>/SKILL.md`, but an agent only loads it if it
  # knows it exists. `sync_pointer/2` injects an idempotent, digest-guarded managed block listing
  # the **Faber-installed** skills (those with the `.faber.json` marker — never the user's own
  # skills sharing the dir) into the agent's shared context file (`CLAUDE.md` / `AGENTS.md`), so a
  # second agent picks them up too — without clobbering the user's own text.

  # Declarative agent → shared-context-file registry. The engine stays agent-agnostic; add a row to
  # extend. `~` is expanded at lookup.
  @agent_context_files %{
    "claude" => "~/.claude/CLAUDE.md",
    "codex" => "~/.codex/AGENTS.md"
  }

  @doc "The known agent → shared-context-file map (raw, `~`-relative)."
  @spec agent_context_files() :: %{String.t() => String.t()}
  def agent_context_files, do: @agent_context_files

  @doc "Expanded shared-context file for `agent`, or `nil` if the agent is unknown."
  @spec agent_context_file(String.t()) :: Path.t() | nil
  def agent_context_file(agent) do
    case Map.get(@agent_context_files, agent) do
      nil -> nil
      path -> Path.expand(path)
    end
  end

  @doc """
  Summaries (`%{name, description, path}`) of every skill installed under `dir` (a `*/SKILL.md`
  each), sorted by name.
  """
  @spec list_installed(Path.t()) :: [%{name: String.t(), description: String.t(), path: Path.t()}]
  def list_installed(dir \\ default_dir()) do
    [Path.expand(dir), "*", "SKILL.md"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.flat_map(&skill_summary/1)
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  Like `list_installed/1` but only the skills **Faber installed** — those carrying the `#{@marker}`
  provenance sentinel. This is what the cross-agent pointer and the MCP listing use, so a user's own
  skills sharing the dir are never claimed as Faber-managed.
  """
  @spec list_faber_installed(Path.t()) :: [
          %{name: String.t(), description: String.t(), path: Path.t()}
        ]
  def list_faber_installed(dir \\ default_dir()) do
    dir
    |> list_installed()
    |> Enum.filter(&faber_installed?/1)
  end

  # Existence, deliberately — NOT `provenance/1 != %{}`. These two disagree for a marker stamped
  # with a format this build cannot read (a newer Faber wrote it), and the disagreement is the
  # correct answer: the file is Faber's by name, so the skill IS Faber-installed even when its
  # details are unreadable. Gating ownership on a successful parse would make an older build disown
  # every skill a newer one installed, dropping them from the pointer and the MCP listing — the
  # orphaning failure again, just pointed at the future instead of the past. Unreadable provenance
  # degrades to "ours, details unknown", never to "not ours".
  defp faber_installed?(%{path: skill_path}) do
    skill_path |> Path.dirname() |> Path.join(@marker) |> File.exists?()
  end

  @doc """
  The decoded provenance marker (`#{@marker}`) beside the `SKILL.md` at `skill_path`, or `%{}` when
  it is absent or unreadable.

  This is THE reader for the marker: its filename and its dirname-of-`SKILL.md` location are
  private to this module, so callers go through here (e.g. `installed_at/1` reads its timestamp off
  this, and the dashboard reads `"source_session"` to show a session as already-installed) rather
  than restating the convention.

  A marker with **no** `format` predates the key and reads as format 1 (see `unstamped:` above) —
  every install written before versioning stays Faber's. A marker stamped with a format this build
  cannot read returns `%{}`, the same as an absent one.
  """
  @spec provenance(Path.t()) :: map()
  def provenance(skill_path) do
    marker = skill_path |> Path.dirname() |> Path.join(@marker)

    with {:ok, body} <- File.read(marker),
         {:ok, map} when is_map(map) <- Jason.decode(body),
         true <- readable?(map["format"]) do
      map
    else
      _ -> %{}
    end
  end

  @doc """
  When Faber installed the skill at `skill_path` (its `SKILL.md` path), read from the `#{@marker}`
  provenance marker beside it — `nil` for a missing or older-shape marker ("unknown install
  time", which `Faber.Feedback` treats as "count every session").
  """
  @spec installed_at(Path.t()) :: DateTime.t() | nil
  def installed_at(skill_path) do
    with iso when is_binary(iso) <- Map.get(provenance(skill_path), "installed_at"),
         {:ok, dt, _offset} <- DateTime.from_iso8601(iso) do
      dt
    else
      _ -> nil
    end
  end

  @doc "Render the managed-block body that lists `skills` for an agent's context file."
  @spec render_pointer_body([%{name: String.t(), description: String.t()}]) :: String.t()
  def render_pointer_body(skills) do
    header =
      "# Faber-managed skills\n\n" <>
        "Skills installed by Faber — load the matching one when its trigger applies:\n"

    case skills do
      [] -> header <> "\n_(none installed yet)_"
      list -> header <> "\n" <> Enum.map_join(list, "\n", &"- **#{&1.name}** — #{&1.description}")
    end
  end

  @doc """
  Sync the managed pointer block for `agent` into its shared context file from the **Faber-installed**
  skills in the skills dir (those carrying the `#{@marker}` marker — not the user's own skills).
  Options: `:file` (override the target file), `:dir` (override the skills dir), `:force` (overwrite a
  hand-edited block). Returns `{:ok, :written | :unchanged}`, `{:error, :block_modified}`, or
  `{:error, {:unknown_agent, agent}}`.
  """
  @spec sync_pointer(String.t(), keyword()) ::
          {:ok, :written | :unchanged} | {:error, term()}
  def sync_pointer(agent, opts \\ []) do
    case opts[:file] || agent_context_file(agent) do
      nil ->
        {:error, {:unknown_agent, agent}}

      file ->
        body = render_pointer_body(list_faber_installed(opts[:dir] || default_dir()))
        install_pointer(file, body, opts)
    end
  end

  @doc """
  Read-only counterpart to `sync_pointer/2`: report whether `agent`'s context file is `:in_sync`,
  has `:drift` (a stale Faber block), is `:modified` (hand-edited block — won't be overwritten
  without `:force`), or `:absent` (no block yet). Compares against the **Faber-installed** skills
  only. Never writes.
  """
  @spec check_pointer(String.t(), keyword()) ::
          :in_sync | :drift | :modified | :absent | {:error, term()}
  def check_pointer(agent, opts \\ []) do
    case opts[:file] || agent_context_file(agent) do
      nil ->
        {:error, {:unknown_agent, agent}}

      file ->
        existing = if File.exists?(file), do: File.read!(file), else: ""
        body = render_pointer_body(list_faber_installed(opts[:dir] || default_dir()))
        pointer_state(existing, body)
    end
  end

  # Order matters: a tampered block must be reported before an in-sync/drift verdict, so a
  # hand-edited block is never silently overwritten.
  defp pointer_state(existing, body) do
    cond do
      not ManagedBlock.has_block?(existing) -> :absent
      ManagedBlock.tampered?(existing) -> :modified
      ManagedBlock.in_sync?(existing, body) -> :in_sync
      true -> :drift
    end
  end

  @doc """
  Upsert `body` as a managed block in `file`. Returns `{:ok, :unchanged}` when already current,
  `{:ok, :written}` after writing, or `{:error, :block_modified}` when the existing block was
  hand-edited and `:force` isn't set.
  """
  @spec install_pointer(Path.t(), String.t(), keyword()) ::
          {:ok, :written | :unchanged} | {:error, term()}
  def install_pointer(file, body, opts \\ []) do
    existing = if File.exists?(file), do: File.read!(file), else: ""

    cond do
      ManagedBlock.in_sync?(existing, body) ->
        {:ok, :unchanged}

      ManagedBlock.tampered?(existing) and not Keyword.get(opts, :force, false) ->
        {:error, :block_modified}

      true ->
        content = ManagedBlock.upsert(existing, body)

        with :ok <- File.mkdir_p(Path.dirname(file)),
             :ok <- File.write(file, content) do
          {:ok, :written}
        end
    end
  end

  # `[summary]` or `[]` — a `SKILL.md` that vanished between the wildcard scan and this read (TOCTOU)
  # is skipped, not crashed (this feeds the MCP `faber_list_skills`/`faber_get_skill` tools).
  defp skill_summary(path) do
    case File.read(path) do
      {:ok, content} ->
        [
          %{
            name: frontmatter(content, "name") || Path.basename(Path.dirname(path)),
            description: frontmatter(content, "description") || "",
            path: path
          }
        ]

      {:error, _} ->
        []
    end
  end

  # Precompiled per known frontmatter field — `skill_summary/1` only ever asks for these two, so the
  # regex isn't rebuilt on every read. Unknown fields fall back to a one-off runtime compile.
  @frontmatter_res %{
    "name" => ~r/^name:\s*"?(.+?)"?\s*$/m,
    "description" => ~r/^description:\s*"?(.+?)"?\s*$/m
  }

  # One-line frontmatter scalar (tolerates an optional surrounding double-quote, as render emits).
  defp frontmatter(content, field) do
    re = @frontmatter_res[field] || Regex.compile!("^#{field}:\\s*\"?(.+?)\"?\\s*$", "m")

    case Regex.run(re, content) do
      [_, val] -> String.trim(val)
      _ -> nil
    end
  end

  defp home, do: System.user_home() || File.cwd!()
end
