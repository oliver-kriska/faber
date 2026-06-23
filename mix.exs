defmodule Faber.MixProject do
  use Mix.Project

  def project do
    [
      app: :faber,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      description: description(),
      aliases: aliases(),
      releases: releases(),
      deps: deps()
    ]
  end

  # Single-binary distribution via Burrito (see .claude/research/2026-06-19-single-binary-*).
  # Scoped to macOS + Linux only — no Windows target (which also drops the `7z` build dependency).
  # `MIX_ENV=prod mix release faber` cross-builds with Zig; output lands in `burrito_out/`.
  defp releases do
    [
      faber: [
        # Copy the declarative adapter pack into the release root so the packaged binary can load
        # it (resolved at runtime via Faber.adapter_dir/0 → RELEASE_ROOT). Runs after assemble,
        # before Burrito wraps the release dir into the self-extracting binary.
        steps: [:assemble, &copy_adapters/1, &Burrito.wrap/1],
        burrito: [
          targets: [
            macos: [os: :darwin, cpu: :x86_64],
            macos_silicon: [os: :darwin, cpu: :aarch64],
            linux: [os: :linux, cpu: :x86_64]
          ]
        ]
      ]
    ]
  end

  # Release step: bundle the declarative adapter pack into the release root (resolved at runtime by
  # Faber.adapter_dir/0 via RELEASE_ROOT). The engine itself is domain-free; the adapter ships beside it.
  defp copy_adapters(release) do
    File.cp_r!("adapters", Path.join(release.path, "adapters"))
    release
  end

  # `mix test` skips the `@tag :sidecar` parity tests (they spawn python3); `mix test.full` runs
  # them so native↔sidecar engine drift is caught. See CLAUDE.md / README.
  defp aliases do
    ["test.full": ["test --include sidecar --include ccrider"]]
  end

  def cli do
    [preferred_envs: ["test.full": :test]]
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
      # Single-binary packaging (mix release → self-extracting binary with ERTS bundled). Only the
      # release path uses it; runtime code guards on it so dev/test never call into Burrito.
      {:burrito, "~> 1.0"},
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end
end
