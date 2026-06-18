defmodule Faber.MixProject do
  use Mix.Project

  def project do
    [
      app: :faber,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      description: description(),
      deps: deps()
    ]
  end

  defp description do
    "Local-first, cross-agent, stack-aware improvement engine for AI coding agents."
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Faber.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  #
  # Library choices are recorded in .claude/research/2026-06-18-elixir-dependency-needs.md.
  # Added per milestone (kept minimal): the two below are the confirmed foundation; later
  # stages add their deps when implemented — :exile (M4 sidecar), :req_llm (M3 proposer),
  # :oban + :ecto_sqlite3 (M6), :optimus/:owl (CLI, M5+).
  defp deps do
    [
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.12"}
    ]
  end
end
