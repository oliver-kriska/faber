# Shipping Faber as a single binary (CLI + on-demand browser UI)

**Date:** 2026-06-19 · **Status:** research → recommendation (not yet implemented)
**Question:** ship Faber to users as one binary; run CLI commands, or `faber serve`/`faber ui`
to launch the LiveView dashboard in a browser. No Erlang/Elixir install on the target.

## Verdict: use **Burrito** (v1.5.0, active). Faber is a near-ideal candidate.

Burrito wraps a `mix release` into a single self-extracting binary with ERTS bundled — **no
Erlang required on the target**. Cross-compiles via Zig from one build host. It's the de-facto
tool for distributable Elixir CLIs (successor to Bakeware, which is effectively dormant).

### Why Faber fits unusually well (feasibility findings from the repo)
- **No production NIFs.** Every prod dep is pure Elixir/Erlang (jason, yaml_elixir, req_llm,
  phoenix, phoenix_live_view, phoenix_html, bandit). The only NIF dep, `lazy_html`, is
  `only: :test`. → clean cross-compilation, the usual Burrito pain point is absent.
  (Spike check: `mix deps.tree` to confirm req_llm→Req→Finch/Mint pull no NIF.)
- **Vendored UMD assets, no JS build step** (config/config.exs comment). Assets already live in
  `priv/static`; Burrito packages the whole release dir → UI just works in the binary.
- **Native eval is the default** (`Faber.Eval.Native`). The Python sidecar is optional
  (parity/future GEPA). → the binary runs keyless with **zero Python at runtime**.
- **No Ecto / no DB.** Read-only FS scan → nothing to migrate or provision at first run.

### The one runtime assumption to document
The default LLM backend is `Faber.LLM.ClaudeCLI` (`claude -p`, keyless). The binary therefore
assumes the `claude` CLI is on PATH — reasonable, since Faber mines Claude Code sessions, so its
users already have it. Alternative: `config :faber, :llm, Faber.LLM.ReqLLM` + `ANTHROPIC_API_KEY`.

## Burrito specifics (v1.5.0)
- `releases/0` step: `steps: [:assemble, &Burrito.wrap/1]`, `burrito: [targets: [...]]`.
- Targets needed: `macos` (x86_64), `macos_silicon` (aarch64), `linux` (x86_64), `windows`
  (x86_64). Output in `burrito_out/`.
- Build host needs **Zig 0.15.2 + xz** (+ `7z` for the Windows target). Build on macOS/Linux
  (Windows build host unsupported — use WSL). A CI matrix cross-builds all 4 from linux/mac.
- CLI args inside the app: `Burrito.Util.Args.argv()` → `[String.t()]`.
- First run self-extracts ERTS to a per-OS dir (Application Support / AppData / …); reused after.
  Built-in `./faber maintenance uninstall|directory|meta`.
- ERTS precompiled for OTP ≥ 25.3.

## Target architecture for the binary

One binary `faber`; the app's `start/2` (or a dispatcher) reads `Burrito.Util.Args.argv()` and
routes. One-shot commands run then `System.halt(0)`; `serve` starts the endpoint and blocks.

```
faber scan [--limit N] [--rank-by raw|rate]   # ranked friction table, then halt
faber propose [--rank N] [--install]           # propose+eval (+install) one session, then halt
faber serve [--port P] [--no-open] [--daemon]  # start LiveView, print URL, open browser
faber loop / faber schedule …                  # later
faber maintenance …                            # Burrito built-in
```

**Key code change:** today `Faber.Application` always starts `FaberWeb.Endpoint`. For a CLI,
`faber scan` must NOT spin a web server. Make the Endpoint start **conditional** on the command
(start it only in `serve`, or boot the tree with `server: false` and flip to true for serve).
This is the main wiring task.

**`serve` UX:** pick default port (e.g. 4710) + `--port`; on first run generate & persist a
`secret_key_base` and config under `~/.faber/`; print `http://localhost:PORT`; open the browser
via `open` (macOS) / `xdg-open` (linux) / `cmd /c start` (windows) unless `--no-open`.

**Daemon:** Burrito binaries are foreground.
- v1: `faber serve` foreground; user backgrounds with `&`.
- nicer: `faber service install` generates a **launchd plist** (macOS) / **systemd unit** (linux)
  for a real background service + autostart. Prefer this over a hand-rolled double-fork `--daemon`.

**prod config gotchas:** `mix release` runs `MIX_ENV=prod`. Current `config/runtime.exs` *raises*
if `SECRET_KEY_BASE` is missing — soften for the binary (generate+persist on first run). Set
`server: true` (or conditionally) and `check_origin: false` for localhost.

## Distribution channels (on top of the binary)
- **GitHub Releases** with the 4 Burrito artifacts (CI matrix).
- **Homebrew tap** (`brew install oliver-kriska/tap/faber`) — formula points at the release asset.
- **`curl … | sh`** installer script (detects OS/arch, downloads the right artifact).

## Alternatives considered
- **Bakeware** — Burrito's predecessor; dormant. Skip.
- **escript** — no ERTS bundling (needs Erlang on target), awkward with Phoenix assets. Dev-only.
- **Plain `mix release` tarball** — works but per-OS, a directory not one file. Fine as a fallback
  / the thing Homebrew could build from source.
- **Tauri + Burrito (`ex_tauri`)** — for a *native desktop window* instead of "open in browser".
  Heavier (Rust/Tauri toolchain). User explicitly wants browser UI, so **not needed now**;
  note as a future option if a dock-icon/native-window experience is wanted.

## Recommended phasing
1. **Spike (½–1 day):** add `:burrito` + `releases/0`; CLI dispatcher; conditional Endpoint;
   `faber scan` (halt) + `faber serve` (block). Build a local `macos_silicon` binary, run it with
   Erlang NOT on PATH to prove ERTS bundling. De-risks everything.
2. CLI surface: fold existing `mix faber.scan`/`faber.propose` behind the dispatcher (OptionParser).
3. `serve` UX: port/secret/config persistence under `~/.faber`, browser open.
4. Daemonize: `faber service install` (launchd/systemd).
5. CI cross-build matrix → GitHub Releases; Homebrew tap + curl|sh.
6. Docs: runtime assumptions (claude CLI vs API key; Python not needed).

## Build attempt (2026-06-19) — implemented; local build BLOCKED by host toolchain

Implemented end-to-end (committed): `:burrito` dep + `releases/0` (macos, macos_silicon, linux) +
`copy_adapters` step; `Faber.CLI` (scan/propose/serve/help/--version); conditional `FaberWeb.Endpoint`
start in `Faber.Application` (one-shot CLI never binds a port); prod `runtime.exs` (persisted
`secret_key_base` 0600, loopback bind, default port 4710); `Faber.adapter_dir/0` (RELEASE_ROOT-aware);
`.github/workflows/release.yml` (mac + linux). Verified: format, `compile --warnings-as-errors`,
`mix test` (132), `mix test.full` (133), `Faber.CLI` unit tests (10).

**Local `mix release` BLOCKED — not a code defect.** `MIX_ENV=prod mix release faber` fails at
Burrito's Zig wrapper **link** step with `undefined symbol: _sysctlbyname / _fork / _realpath$DARWIN_EXTSN`
(macOS libSystem). Root cause: this host runs **macOS 26.5** (active SDK `MacOSX26.5.sdk`, Zig native
target `aarch64-macos.26.5`), and **Zig 0.15.2** (the version Burrito 1.5.0 pins) predates macOS 26 — it
has no bundled libSystem stubs for it, so even compiling Burrito's own host-side `build.zig` fails.
Reproduced for both `macos_silicon` and `linux` targets (the host `build.zig` runs first, before any
cross-compile), and `SDKROOT=…MacOSX15.4.sdk` did not help (Zig uses its own bundled stubs, not the SDK's).
OTP 29 ERTS *was* fetched fine — that was the only risk I'd pre-flagged, and it's a non-issue.

**Fix = build on supported runners (this is what the CI does):** macOS targets on `macos-14` (Sonoma,
SDK 14.x — within Zig 0.15.2's range) and linux on `ubuntu-latest`. A too-new dev host is the only thing
that can't build locally; standard CI runners build fine. (Alternatives if building locally on macOS 26
is ever needed: a Burrito release pinned to a Zig that knows macOS 26, or a temporary OTP/Zig pin.)

## Sources
- Burrito README/hexdocs (v1.5.0): https://burrito.hexdocs.pm/readme.html
- Burrito repo: https://github.com/burrito-elixir/burrito
- Phoenix LiveView single binary guide (runtime.exs/server:true): https://mrpopov.com/posts/elixir-liveview-single-binary/
- ex_tauri (Phoenix desktop via Tauri, future option): https://github.com/filipecabaco/ex_tauri
- Tauri+Elixir background: https://crabnebula.dev/blog/tauri-elixir-phoenix/
