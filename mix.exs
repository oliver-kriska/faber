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
  # Added per milestone (kept minimal):
  #   * jason / yaml_elixir   — foundation (ingest, adapter packs)
  #   * req_llm               — M3 proposer LLM client (generate_object/4)
  #   * phoenix / live_view / bandit — M6 dashboard (no Ecto: scan is read-only over the FS)
  # The Python eval sidecar (M4) is reached via System.cmd, so no :exile/NIF dep is needed.
  defp deps do
    [
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.12"},
      {:req_llm, "~> 1.0"},
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_html, "~> 4.1"},
      {:bandit, "~> 1.5"},
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end
end
