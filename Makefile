# Faber — dev tasks: deps, verify, and building/installing the single binary.
#
# The binary is built with Burrito (see mix.exs releases/0). `make install` puts it on your PATH
# so `faber <cmd>` works from any directory — the point being to dogfood Faber against other repos.
#
# Quick start:
#   make deps && make verify     # download deps, run the Iron Law #22 gate
#   make install                 # build the host binary + drop it in ~/.local/bin
#   make help                    # every target

.DEFAULT_GOAL := help

APP          := faber
APP_VERSION  := $(shell grep -m1 -o 'version: "[^"]*"' mix.exs | cut -d'"' -f2)

# Where `make install` puts the binary. Override: `make install PREFIX=/usr/local` (may need sudo).
PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin

UNAME_S := $(shell uname -s)
UNAME_M := $(shell uname -m)

ifeq ($(UNAME_S),Darwin)
  ifeq ($(UNAME_M),arm64)
    HOST_TARGET := macos_silicon
    ZIG_SLICE   := arm64-macos
  else
    HOST_TARGET := macos
    ZIG_SLICE   := x86_64-macos
  endif
  BURRITO_CACHE := $(HOME)/Library/Application Support/.burrito
else
  HOST_TARGET := linux
  BURRITO_CACHE := $(if $(XDG_DATA_HOME),$(XDG_DATA_HOME),$(HOME)/.local/share)/.burrito
endif

BIN_OUT := burrito_out/$(APP)_$(HOST_TARGET)

# --- macOS SDK workaround ----------------------------------------------------
# Burrito 1.5.0 hard-pins Zig 0.15.2, which predates the macOS 26 SDK. In that SDK the umbrella
# libSystem.B.tbd advertises only `arm64e-macos` (no plain `arm64-macos`), so Zig resolves ZERO libc
# symbols and the build dies with hundreds of `undefined symbol: _abort/_getenv/...`. Zig 0.16 fixes
# it but Burrito rejects it outright ("We need `0.15.2`").
#
# The seam: Zig ignores SDKROOT and `--sysroot` can't reach the build-runner compile, but it DOES
# honor DEVELOPER_DIR — an env var, which Burrito's `System.cmd` inherits. So point Zig at a
# throwaway developer dir whose SDKs/MacOSX.sdk symlinks to an SDK that still has our arch slice
# (the Command Line Tools ship older ones alongside the current SDK).
#
# ZIG_SDK empty => the default SDK is fine (or we're on Linux) and none of this engages.
# Override with `make build ZIG_SDK=/path/to/MacOSX15.4.sdk`, or ZIG_SDK= to force it off.
ifeq ($(UNAME_S),Darwin)
  # libSystem.B.tbd is a ~40-document YAML file and `arm64-macos` appears in many of the reexported
  # sub-library docs — a plain grep over the file gives a false OK. Only the FIRST document (the
  # umbrella /usr/lib/libSystem.B.dylib, the one Zig links against) decides, hence the awk.
  #
  # NOTE: keep this snippet free of `(` / `)` — Make matches parens inside $(shell ...) and an
  # unbalanced one (from a `case` pattern or `$(cmd)`) silently truncates it. Backticks only.
  ZIG_SDK ?= $(shell \
    tbd=usr/lib/libSystem.B.tbd; \
    ok () { awk '/^--- !tapi-tbd/{n++} n==1' "$$1/$$tbd" 2>/dev/null | grep -q '$(ZIG_SLICE)'; }; \
    if ok "`xcrun --show-sdk-path 2>/dev/null`"; then exit 0; fi; \
    for s in /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk \
             /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX*.sdk; do \
      if ok "$$s"; then echo "$$s"; exit 0; fi; \
    done)
endif

SDK_DIR  := _build/macos-sdk
SDK_LINK := $(SDK_DIR)/SDKs/MacOSX.sdk

# Engage the workaround only when detection found a replacement SDK.
ZIG_ENV     := $(if $(ZIG_SDK),DEVELOPER_DIR="$(CURDIR)/$(SDK_DIR)",)
ZIG_PREREQ  := $(if $(ZIG_SDK),$(SDK_LINK),)

.PHONY: help deps deps-python compile format credo dialyzer verify test test-full test-live \
        test-live-api doctor build build-all install uninstall purge-cache clean clean-all

help: ## Show this help
	@echo "Faber $(APP_VERSION) — host target: $(HOST_TARGET)"
	@echo ""
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Install dir: $(BINDIR)  (override with PREFIX=/usr/local)"

doctor: ## Show the detected build toolchain (useful when a build fails)
	@echo "host target : $(HOST_TARGET)"
	@echo "zig         : $$(command -v zig || echo MISSING) $$(zig version 2>/dev/null)"
	@echo "burrito wants: 0.15.2"
	@echo "arch slice  : $(ZIG_SLICE)"
	@echo "default SDK : $$(xcrun --show-sdk-path 2>/dev/null || echo n/a)"
	@echo "SDK override: $(if $(ZIG_SDK),$(ZIG_SDK),none needed)"
	@echo "burrito cache: $(BURRITO_CACHE)"

# ---------------------------------------------------------------------------- deps

deps: ## Fetch Elixir deps
	mix deps.get

deps-python: ## Fetch Python eval sidecar deps (optional — needs uv; normal use is keyless/native)
	@command -v uv >/dev/null 2>&1 || { \
		echo "uv not found — install it (https://docs.astral.sh/uv/) or skip:"; \
		echo "the sidecar is optional, Faber defaults to Faber.Eval.Native."; exit 1; }
	cd python && uv sync

# ---------------------------------------------------------------------------- dev loop

compile: ## Compile with warnings as errors
	mix compile --warnings-as-errors

format: ## Format the codebase
	mix format

credo: ## Lint (static analysis)
	mix credo --strict

dialyzer: ## Type-check (first run builds the PLT into _build/plts — takes a few minutes)
	mix dialyzer

test: ## Hermetic suite (no python3/sqlite3/key needed)
	mix test

test-full: ## Suite + sidecar/ccrider/opencode tags (needs python3 + sqlite3)
	mix test.full

test-live: ## Keyless end-to-end run against a real model via `claude -p` (spends quota)
	mix test.live

test-live-api: ## Paid ReqLLM/Anthropic live run (needs CLAUDE_API in .env)
	mix test.live.api

verify: ## The pre-commit gate (Iron Law #22): format, compile, credo, dialyzer, test
	mix verify

# ---------------------------------------------------------------------------- build

$(SDK_LINK):
	@mkdir -p $(SDK_DIR)/SDKs
	@ln -sfn "$(ZIG_SDK)" $(SDK_LINK)

build: $(ZIG_PREREQ) ## Build the single binary for this host only
	@$(if $(ZIG_SDK),echo "note: default SDK has no $(ZIG_SLICE) slice for zig 0.15.2 — using $(ZIG_SDK)",true)
	$(ZIG_ENV) BURRITO_TARGET=$(HOST_TARGET) MIX_ENV=prod mix release $(APP) --overwrite
	@echo "→ $(BIN_OUT)"

build-all: $(ZIG_PREREQ) ## Cross-build every target in mix.exs (macos, macos_silicon, linux)
	$(ZIG_ENV) MIX_ENV=prod mix release $(APP) --overwrite
	@ls -1 burrito_out/

# ---------------------------------------------------------------------------- install

# The purge is load-bearing, not hygiene. Burrito's wrapper keys its extraction dir on
# `$(APP)_erts-<erts>_<app_version>` and re-extracts ONLY when that dir's _metadata.json is absent
# (wrapper.zig: `needs_install`); clean-install is disabled in prod builds (IS_PROD=1). Since
# version stays pinned during dev, a rebuilt+reinstalled binary would silently keep running the
# STALE extracted release. Burrito's own `maintenance uninstall` prompts [y/n] on stdin, so it's
# unusable here — delete the dir directly. Cost of over-purging is one slower next start.
purge-cache: ## Drop Burrito's extracted runtime so the next run re-extracts (fixes stale code)
	@rm -rf "$(BURRITO_CACHE)"/$(APP)_erts-* && echo "purged: $(BURRITO_CACHE)/$(APP)_erts-*"

install: build purge-cache ## Build + install `faber` onto your PATH so it works in any directory
	@mkdir -p "$(BINDIR)"
	@install -m 0755 "$(BIN_OUT)" "$(BINDIR)/$(APP)"
	@echo "installed: $(BINDIR)/$(APP) ($(APP_VERSION), $(HOST_TARGET))"
	@case ":$$PATH:" in \
		*":$(BINDIR):"*) echo "run: $(APP) scan" ;; \
		*) echo ""; \
		   echo "WARNING: $(BINDIR) is not on your PATH. Add to ~/.zshrc:"; \
		   echo "  export PATH=\"$(BINDIR):\$$PATH\"" ;; \
	esac

uninstall: purge-cache ## Remove the installed binary and its extracted runtime
	@rm -f "$(BINDIR)/$(APP)" && echo "removed: $(BINDIR)/$(APP)"

# ---------------------------------------------------------------------------- clean

clean: ## Remove build output
	rm -rf burrito_out $(SDK_DIR)
	mix clean

clean-all: clean purge-cache ## Remove build output, _build, deps, and the extracted runtime
	rm -rf _build deps
