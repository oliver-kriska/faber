# Plan: Faber single-binary distribution (mac/linux only)

**Source:** `.claude/research/2026-06-19-single-binary-distribution.md`. Tool: **Burrito** v1.5.0.
**Scope directive:** keep ONLY macOS + Linux targets (drop Windows → no `7z` dep, simpler CI).
**Build host confirmed ready:** zig 0.15.2 + xz present; OTP 29 (ERTS availability = build risk).

Targets: `macos` (darwin/x86_64), `macos_silicon` (darwin/aarch64), `linux` (linux/x86_64).

## Phase 1 — Burrito release config

- [x] [P1-T1] mix.exs: add `{:burrito, "~> 1.0"}`; add `releases/0` with the 3 mac/linux targets and
  `steps: [:assemble, &Burrito.wrap/1]`; wire `releases: releases()` into `project/0`.

## Phase 2 — CLI dispatcher + conditional web

- [x] [P2-T1] `Faber.CLI`: parse argv (OptionParser) → `{command, opts}`; `command/0` returns the
  parsed command ONLY when running as a Burrito release (gate on `RELEASE_NAME` + Burrito argv);
  `nil` in dev/test/iex so `mix phx.server` and LiveView tests are unchanged.
- [x] [P2-T2] Subcommands: `scan` (ranked table, halt), `propose [--rank N] [--install]`
  (propose+eval+optional install, halt), `serve [--port P] [--no-open]` (start endpoint, print URL,
  open browser, stay up), `help`/`--version`. One-shot commands `System.halt(status)`.
- [x] [P2-T3] `Faber.Application.start/2`: include `FaberWeb.Endpoint` only when command ∈
  `[nil, :serve]` (so `faber scan` never binds a port); after the supervisor starts, run the CLI
  command (one-shot → halt; serve → print URL + open browser).
- [x] [P2-T4] Browser open: `open` (macOS) / `xdg-open` (Linux) via `System.cmd`; injectable/guarded
  so it's testable and a no-op under `--no-open`.

## Phase 3 — prod runtime + local config

- [x] [P3-T1] `config/runtime.exs` (prod): generate+persist `secret_key_base` under `~/.faber/`
  (localhost-only app), default port `4710` (`PORT`/`--port` override), `server: true`,
  `check_origin: false`. No more hard `raise` on missing env (it's a local binary).
- [x] [P3-T2] config: ensure `:faber, :skills_dir` / `:adapter_dir` resolve sensibly from the binary
  (adapters are bundled in the release `priv` or referenced; confirm adapter load path works from a
  release — bundle `adapters/faber-elixir` into priv if needed).

## Phase 4 — CI cross-build (mac/linux)

- [x] [P4-T1] `.github/workflows/release.yml`: matrix building macOS + Linux Burrito artifacts on
  tag; install zig 0.15.2 + xz; upload to the GitHub Release. (Windows omitted by directive.)

## Phase 5 — tests

- [x] [P5-T1] `Faber.CLI` tests: arg parsing for each subcommand; scan/propose run against
  `test/fixtures` + stub LLM produce expected output; browser-open injected & asserted not called
  under `--no-open`; `command/0` returns nil outside a release.

## Verification
Per phase: `mix format` + `mix compile --warnings-as-errors` + `mix test`. Final: `mix test.full`
(+ Python unaffected) and a REAL `MIX_ENV=prod mix release` of the local target, run with Erlang
removed from PATH to prove ERTS bundling. If Burrito lacks OTP 29 precompiled ERTS, document the
constraint (pin OTP / `custom_erts`) — code/config still ship green. One commit per phase.
Co-author trailer. Never push.

## Decisions (recommendation followed, per user)
- **Burrito over Bakeware/escript** — only viable single-file-with-ERTS option (research).
- **Browser UI, not Tauri** — user wants "open in browser"; Tauri deferred.
- **No `--daemon` fork in v1** — `faber serve` foreground; `faber service install` (launchd/systemd)
  is a follow-up. Keeps v1 honest and verifiable.
- **mac/linux only** — per directive; Windows target dropped (also removes the `7z` build dep).
</content>
