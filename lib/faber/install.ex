defmodule Faber.Install do
  @moduledoc """
  **Pipeline tail — install.** Write an accepted proposal's `SKILL.md` into a skills directory so a
  coding agent can load it.

  The default target is `config :faber, :skills_dir` (falling back to `~/.claude/skills`). Existing
  skills are never silently overwritten — pass `force: true` to replace. Gating (did the proposal
  pass the eval bar?) is the caller's responsibility; `Faber.Eval.gate/2` is the natural guard.
  """

  alias Faber.{Adapter, Propose, Proposal}
  alias Faber.Install.ManagedBlock

  # A skill name becomes a path segment, so it must be a single lowercase-kebab token — same shape
  # the adapter enforces for its own name. This is the security boundary: the name originates from
  # LLM output mined from UNTRUSTED transcripts, so an unvalidated `name` like "../../etc/foo" (or
  # an absolute path, which `Path.join` would honor) would escape the skills directory.
  @name_re ~r/\A[a-z0-9][a-z0-9-]{0,63}\z/

  @doc """
  Install `proposal` (or a `{name, skill_md}` pair) under `<dir>/<name>/SKILL.md`.

  Options: `:dir` (target skills root; defaults to the configured dir), `:adapter` (render a
  `%Proposal{}` via the adapter's template, matching what `Faber.Eval` gated), `:force` (overwrite
  an existing skill). Returns `{:ok, path}` or `{:error, reason}` — including
  `{:error, {:exists, path}}` when already installed and `force` is not set, or
  `{:error, {:invalid_name, name}}` when the name isn't a safe path segment.
  """
  @spec install(Proposal.t() | {String.t(), String.t()}, keyword()) ::
          {:ok, Path.t()} | {:error, term()}
  def install(proposal_or_pair, opts \\ [])

  def install(%Proposal{} = p, opts) do
    md =
      case opts[:adapter] do
        %Adapter{} = adapter -> Propose.render_skill_md(p, adapter)
        _ -> Propose.render_skill_md(p)
      end

    install({p.name, md}, opts)
  end

  def install({name, skill_md}, opts) when is_binary(name) and is_binary(skill_md) do
    with :ok <- validate_name(name) do
      path = Path.join([opts[:dir] || default_dir(), name, "SKILL.md"])

      if File.exists?(path) and not Keyword.get(opts, :force, false) do
        {:error, {:exists, path}}
      else
        with :ok <- File.mkdir_p(Path.dirname(path)),
             :ok <- File.write(path, skill_md) do
          {:ok, path}
        end
      end
    end
  end

  defp validate_name(name) do
    if Regex.match?(@name_re, name), do: :ok, else: {:error, {:invalid_name, name}}
  end

  @doc "The configured skills directory (`config :faber, :skills_dir`, default `~/.claude/skills`)."
  @spec default_dir() :: Path.t()
  def default_dir do
    Application.get_env(:faber, :skills_dir, Path.join(home(), ".claude/skills"))
  end

  # ── cross-agent pointers (managed block) ───────────────────────────────────
  #
  # Installing a skill writes a dedicated `<dir>/<name>/SKILL.md`, but an agent only loads it if it
  # knows it exists. `sync_pointer/2` injects an idempotent, digest-guarded managed block listing
  # the installed skills into the agent's shared context file (`CLAUDE.md` / `AGENTS.md`), so a
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
  Sync the managed pointer block for `agent` into its shared context file from the skills currently
  installed in the skills dir. Options: `:file` (override the target file), `:dir` (override the
  skills dir), `:force` (overwrite a hand-edited block). Returns `{:ok, :written | :unchanged}`,
  `{:error, :block_modified}`, or `{:error, {:unknown_agent, agent}}`.
  """
  @spec sync_pointer(String.t(), keyword()) ::
          {:ok, :written | :unchanged} | {:error, term()}
  def sync_pointer(agent, opts \\ []) do
    case opts[:file] || agent_context_file(agent) do
      nil ->
        {:error, {:unknown_agent, agent}}

      file ->
        body = render_pointer_body(list_installed(opts[:dir] || default_dir()))
        install_pointer(file, body, opts)
    end
  end

  @doc """
  Read-only counterpart to `sync_pointer/2`: report whether `agent`'s context file is `:in_sync`,
  has `:drift` (a stale Faber block), is `:modified` (hand-edited block — won't be overwritten
  without `:force`), or `:absent` (no block yet). Never writes.
  """
  @spec check_pointer(String.t(), keyword()) ::
          :in_sync | :drift | :modified | :absent | {:error, term()}
  def check_pointer(agent, opts \\ []) do
    case opts[:file] || agent_context_file(agent) do
      nil ->
        {:error, {:unknown_agent, agent}}

      file ->
        existing = if File.exists?(file), do: File.read!(file), else: ""
        body = render_pointer_body(list_installed(opts[:dir] || default_dir()))

        cond do
          not ManagedBlock.has_block?(existing) -> :absent
          ManagedBlock.tampered?(existing) -> :modified
          ManagedBlock.in_sync?(existing, body) -> :in_sync
          true -> :drift
        end
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

  # One-line frontmatter scalar (tolerates an optional surrounding double-quote, as render emits).
  defp frontmatter(content, field) do
    case Regex.run(~r/^#{field}:\s*"?(.+?)"?\s*$/m, content) do
      [_, val] -> String.trim(val)
      _ -> nil
    end
  end

  defp home, do: System.user_home() || File.cwd!()
end
