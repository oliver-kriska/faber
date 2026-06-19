defmodule Faber.Install do
  @moduledoc """
  **Pipeline tail — install.** Write an accepted proposal's `SKILL.md` into a skills directory so a
  coding agent can load it.

  The default target is `config :faber, :skills_dir` (falling back to `~/.claude/skills`). Existing
  skills are never silently overwritten — pass `force: true` to replace. Gating (did the proposal
  pass the eval bar?) is the caller's responsibility; `Faber.Eval.gate/2` is the natural guard.
  """

  alias Faber.{Adapter, Propose, Proposal}

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

  defp home, do: System.user_home() || File.cwd!()
end
