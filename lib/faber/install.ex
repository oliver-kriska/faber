defmodule Faber.Install do
  @moduledoc """
  **Pipeline tail — install.** Write an accepted proposal's `SKILL.md` into a skills directory so a
  coding agent can load it.

  The default target is `config :faber, :skills_dir` (falling back to `~/.claude/skills`). Existing
  skills are never silently overwritten — pass `force: true` to replace. Gating (did the proposal
  pass the eval bar?) is the caller's responsibility; `Faber.Eval.gate/2` is the natural guard.
  """

  alias Faber.{Propose, Proposal}

  @doc """
  Install `proposal` (or a `{name, skill_md}` pair) under `<dir>/<name>/SKILL.md`.

  Options: `:dir` (target skills root; defaults to the configured dir), `:force` (overwrite an
  existing skill). Returns `{:ok, path}` or `{:error, reason}` — including `{:error, {:exists, path}}`
  when the skill is already installed and `force` is not set.
  """
  @spec install(Proposal.t() | {String.t(), String.t()}, keyword()) ::
          {:ok, Path.t()} | {:error, term()}
  def install(proposal_or_pair, opts \\ [])

  def install(%Proposal{} = p, opts) do
    install({p.name, Propose.render_skill_md(p)}, opts)
  end

  def install({name, skill_md}, opts) when is_binary(name) and is_binary(skill_md) do
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

  @doc "The configured skills directory (`config :faber, :skills_dir`, default `~/.claude/skills`)."
  @spec default_dir() :: Path.t()
  def default_dir do
    Application.get_env(:faber, :skills_dir, Path.join(home(), ".claude/skills"))
  end

  defp home, do: System.user_home() || File.cwd!()
end
