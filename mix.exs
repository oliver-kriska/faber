defmodule Faber.MixProject do
  use Mix.Project

  def project do
    [
      app: :faber,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      # Phoenix 1.8 drives code reloading through a Mix listener, and warns (falling back to a
      # blunter purge) whenever `Phoenix.CodeReloader.reload/1` is called without one registered.
      # Faber never reloads on requests — dev.exs keeps `code_reloader: false`, since a CLI serving
      # a dashboard has no use for it — but Tidewave calls reload/1 unconditionally before every
      # `project_eval` so it evaluates against your latest edits. That's the only caller, and this
      # is what silences it. Mix-time only: listeners don't exist in a release.
      listeners: [Phoenix.CodeReloader],
      description: description(),
      aliases: aliases(),
      releases: releases(),
      dialyzer: dialyzer(),
      deps: deps()
    ]
  end

  # PLTs live in `_build/plts`, NOT the conventional `priv/plts`: Mix copies the app's `priv/`
  # verbatim into a release (`_build/<env>/lib/faber/priv` is a symlink to it), so the ~9MB of PLTs
  # parked there would be bundled into the Burrito single binary we ship. `_build` is already
  # gitignored and CI-cached, and `make clean-all` wipes it — the PLT's desired lifetime.
  defp dialyzer do
    [
      plt_local_path: "_build/plts",
      plt_core_path: "_build/plts",
      # `:mix` — the CLI ships `Mix.Tasks.Faber.*`; `:ex_unit` — test/support helpers.
      # `:owl` — it is `runtime: false` (see deps/0), so it is absent from the runtime tree the PLT
      # is built from, and `Owl.Data.tag/2` would read as `unknown_function`. The dep is real and
      # called; only its *application* is unused.
      plt_add_apps: [:mix, :ex_unit, :owl],
      ignore_warnings: ".dialyzer_ignore.exs",
      # Fail the gate if an entry in .dialyzer_ignore.exs stops matching, so the exception list
      # can't quietly outlive the code it was written for.
      list_unused_filters: true
    ]
  end

  # Single-binary distribution via Burrito (see .claude/research/2026-06-19-single-binary-*).
  # Scoped to macOS + Linux only — no Windows target (which also drops the `7z` build dependency).
  # `MIX_ENV=prod mix release faber` cross-builds with Zig; output lands in `burrito_out/`.
  defp releases do
    [
      faber: [
        # Ship Owl's modules, but never start its application. Faber calls exactly one Owl
        # function — the pure `Owl.Data.tag/2` — and deliberately never `Owl.LiveScreen` (that
        # path deadlocks when piped; see Faber.CLI.Render). Left alone, `Owl.Application` boots a
        # Registry, LiveScreen and three supervisors on every one-shot CLI run, none ever used.
        #
        # This line and `runtime: false` on the dep are a PAIR; neither works alone, and the two
        # failure modes are quite different:
        #
        #   * `runtime: false` alone → Mix omits the dep from the release entirely, so
        #     `Owl.Data.tag/2` raises UndefinedFunctionError in the binary. Burrito boots
        #     `-mode embedded` (no autoload), so it fails hard — and `mix test` never sees it,
        #     because dev/test run against the full tree. Every badge breaks in the shipped
        #     artifact while the suite stays green.
        #   * `applications: [owl: :load]` alone → Mix REFUSES to assemble: ":faber has mode
        #     :permanent but it depends on :owl which is set to :load". A permanent app's deps
        #     must be started, so the release would fail to boot.
        #
        # Together they work: `runtime: false` keeps owl out of `:faber`'s own applications list
        # (dissolving the permanent→load conflict), and this line puts it back into the release as
        # load-only. Verified against the real binary: `faber feedback` piped → 0 escape bytes,
        # under a pty → 24, both rc=0 — same as before the change.
        applications: [owl: :load],
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
  # them so native↔sidecar engine drift is caught. Its tags are the ones CI *can* satisfy with
  # tooling (python3, sqlite3), which is why it is CI's command.
  #
  # `:plugin_eval` is deliberately NOT in `test.full`: it scores against the real referenced plugin
  # repo at the adapter's machine-local `metadata.source_repo`, so it is unsatisfiable on a runner
  # no matter how that runner is provisioned — it is environment-bound in the same way `:live` /
  # `:live_api` are, and gets its own alias for the same reason. `mix test.plugin` runs it locally
  # to catch drift in that scorer's JSON shape that a fake scorer never would.
  #
  # `mix test.live` runs the keyless real-model smoke test (shells out to `claude -p`; spends
  # subscription quota). `mix test.live.api` runs the API-backed (ReqLLM) live test — needs a key
  # (`set -a; . ./.env; set +a` first) and costs money. See CLAUDE.md / README.
  defp aliases do
    [
      "test.full": ["test --include sidecar --include ccrider --include opencode"],
      "test.plugin": ["test --include plugin_eval"],
      "test.live": ["test --include live"],
      "test.live.api": ["test --include live_api"],
      # The Iron Law #22 pre-commit gate, in one command (`make verify` calls this).
      # `format` writes rather than checks — this is the local dev loop; CI re-checks with
      # `--check-formatted` so an unformatted tree still fails there. Ordered cheapest-first
      # so a typo fails in seconds instead of after dialyzer.
      verify: [
        "format",
        "compile --warnings-as-errors",
        "credo --strict",
        "dialyzer",
        "test"
      ]
    ]
  end

  def cli do
    [
      preferred_envs: [
        "test.full": :test,
        "test.plugin": :test,
        "test.live": :test,
        "test.live.api": :test,
        # Keep the gate in one env so `compile` and `test` share a build (and dialyzer analyses
        # the same beams the tests ran against) instead of compiling the tree twice.
        verify: :test,
        # …and pin the same env for the standalone tasks (`mix dialyzer`, `make dialyzer`), which
        # would otherwise default to :dev and build a SECOND divergent PLT — minutes and ~9MB spent
        # analysing different beams than the gate does.
        dialyzer: :test,
        credo: :test
      ]
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
      # Terminal styling for the CLI (verdict badges). Pure Elixir, no NIF.
      #
      # `runtime: false` + `applications: [owl: :load]` in releases/0 is a PAIR — see the comment
      # there. Faber only ever calls the pure `Owl.Data.tag/2`, so the app never needs starting;
      # this keeps it out of `:faber`'s own applications list so the release may load-not-start it.
      {:owl, "~> 0.13", runtime: false},
      {:req_llm, "~> 1.0"},
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_html, "~> 4.1"},
      {:bandit, "~> 1.5"},
      # MCP server (Anubis, formerly Hermes) — exposes mined skills/friction as read-only MCP tools
      # over streamable HTTP, mounted at /mcp and started only under `faber serve`. Localhost-bound,
      # single-user, no auth (see lib/faber/mcp/).
      {:anubis_mcp, "~> 1.6"},
      # Single-binary packaging (mix release → self-extracting binary with ERTS bundled). Only the
      # release path uses it; runtime code guards on it so dev/test never call into Burrito.
      {:burrito, "~> 1.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      # Static analysis gate (`mix verify`). credo >= 1.7.19 is a hard floor: 1.7.18 and older
      # crash on Elixir 1.20's sigil end-position tokens (`String.Chars` not implemented for
      # Tuple), and we pin `~> 1.20`. 1.7.19 backported the fix, so no github pin is needed.
      {:credo, "~> 1.7.19", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      # Runtime introspection for the dev server (project_eval, get_logs, get_source_location).
      # `only: :dev` is load-bearing, not hygiene: Tidewave evaluates arbitrary code against the
      # running node, so it must never exist in the shipped binary. The endpoint plug is guarded
      # by `Code.ensure_loaded?/1` so prod/test compile without it. Mounted at /tidewave/mcp.
      {:tidewave, "~> 0.6.1", only: :dev}
    ]
  end
end
