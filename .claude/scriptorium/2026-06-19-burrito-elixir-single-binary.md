---
scriptorium: true
action: create
title: "Burrito — single-binary distribution for Elixir/Phoenix CLIs"
type: tool
domain: claude-elixir-phoenix
tags: [elixir, phoenix, distribution, burrito, release, cli, packaging, zig]
verdict: use
---

# Burrito — Elixir single-binary distribution

**Verdict: use** (for distributing an Elixir/Phoenix CLI or local app as one file). v1.5.0,
actively maintained, de-facto standard. Successor to Bakeware (dormant — skip Bakeware).

## What it is
Wraps a `mix release` into a single **self-extracting binary with ERTS bundled** — no Erlang
required on the target. Cross-compiles to macOS (x86_64 + aarch64), Linux (x86_64), Windows
(x86_64) from one build host using **Zig**.

## Setup essentials
- dep `{:burrito, "~> 1.0"}`; `releases/0` with `steps: [:assemble, &Burrito.wrap/1]` and
  `burrito: [targets: [...]]`; `releases: releases()` in `project/0`.
- Read CLI args inside the app with `Burrito.Util.Args.argv()`; one-shot commands run then
  `System.halt(0)`; a `serve` command starts the endpoint and blocks.
- Build host needs **Zig 0.15.2 + xz** (+ `7z` for the Windows target). Build on macOS/Linux
  (not Windows — use WSL). A CI matrix cross-builds all targets. Output in `burrito_out/`.
- First run self-extracts ERTS to a per-OS dir; built-in `./bin maintenance uninstall|directory|meta`.

## ⚠️ Zig version vs host macOS SDK (real gotcha, hit 2026-06-19)

Burrito 1.5.0 pins **Zig 0.15.2**. Zig bundles its own macOS libSystem stubs for a *range* of
macOS versions. On a **bleeding-edge host** (macOS 26.5, SDK `MacOSX26.5.sdk`), Zig 0.15.2 has no
stubs for that SDK, so it can't even compile Burrito's host-side `build.zig` — the build fails at
the wrapper **link** step with `undefined symbol: _sysctlbyname / _fork / _realpath$DARWIN_EXTSN`
(macOS libSystem). This blocks **all** targets locally (the host `build.zig` runs before any
cross-compile), and `SDKROOT=<older SDK>` does NOT help (Zig uses its own bundled stubs, not the SDK).

**Fix:** build on a runner whose SDK the pinned Zig supports — GitHub `macos-14` (Sonoma, SDK 14.x)
for darwin targets, `ubuntu-latest` for linux. Don't try to build the binary on a just-released macOS.
OTP version ERTS (even OTP 29) was a non-issue — Burrito fetched it fine.

## When it's easy vs hard
- **Easy** when prod deps are pure Elixir/Erlang (no NIFs) and assets are prebuilt into
  `priv/static`. Burrito *can* cross-compile NIFs via Zig, but that's where the pain is.
- **Phoenix specifics**: `config/runtime.exs` must set `server: true` and `check_origin: false`;
  precompile assets before wrapping; soften any `SECRET_KEY_BASE`-required `raise` for a local
  binary (generate + persist a secret on first run under e.g. `~/.appname/`).
- **Gotcha**: a `mix release` boots the whole supervision tree at start. For a CLI that shouldn't
  always run the web server, make the Phoenix Endpoint start **conditional** on the subcommand.

## Alternatives
- **escript** — no ERTS bundling (needs Erlang on target), awkward with Phoenix assets → dev-only.
- **plain mix release tarball** — per-OS directory, not one file; fine as a Homebrew-from-source path.
- **Tauri + Burrito (`ex_tauri`)** — only if you want a *native desktop window* instead of
  "open localhost in the browser". Adds the Rust/Tauri toolchain. For a browser-UI app, skip.

## Distribution on top
GitHub Releases (CI matrix artifacts) + Homebrew tap + `curl … | sh` installer.

First applied: Faber (local-first AI-coding-agent improvement engine) — see its
`.claude/research/2026-06-19-single-binary-distribution.md`. Related: [[genserver-job-crash-isolation]].
