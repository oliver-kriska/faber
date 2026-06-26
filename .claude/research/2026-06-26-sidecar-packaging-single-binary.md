# Sidecar packaging & single-binary distribution

**Date:** 2026-06-26 · **Status:** research → recommendation
**Question:** How should Faber ship the Python eval sidecar so a user needs NO system Python when running as a single Burrito binary?

---

## Faber's current native/sidecar split (as-is)

- **`Faber.Eval.Native`** — in-process Elixir implementation of all 8 eval dimensions plus the full matcher set (~400 LOC `matchers.ex`, ~180 LOC `native.ex`). Default engine; zero Python required. Guarded by the no-egress test suite.
- **`Faber.Sidecar.System`** — shells out to `python3 -m faber_eval score/optimize`. Pure stdlib; no virtualenv needed. Exists for: (a) parity testing (native↔sidecar parity is a tested invariant at the `@describetag :sidecar` level), and (b) the future dspy.GEPA optimizer path (currently stubs to `status: "not_implemented"`).
- **`Faber.Optimize.reflect/3`** — the *actual* v1 optimizer. Uses the reflective GEPA-style loop (keyless, native eval, `claude -p`). No Python, no API key. This is the shipped, working optimizer.
- **`Faber.Optimize.run/2`** — the GEPA sidecar seam. Currently returns `{:error, {:not_implemented, …}}` unless `dspy` is installed and an API key is present. Not exercised in v1 workflows.

**Key insight:** The Python sidecar is already *optional at runtime*. The Burrito binary runs the full scan→propose→eval→install pipeline with zero Python because `Faber.Eval.Native` is the default and `Faber.Optimize.reflect/3` is the v1 loop. The sidecar is only needed for (a) parity tests during development, and (b) the unimplemented heavy GEPA path.

---

## Option 1: Pythonx (embedded CPython in the BEAM)

### What it is
Livebook-dev project (`livebook-dev/pythonx`, v0.4.10 as of May 2026). Embeds CPython as a NIF — the interpreter lives in the same OS process as the BEAM. Dependencies specified in `pyproject.toml` and downloaded at compile time into the `priv/` directory.

### Maturity
- Pre-1.0, v0.4.10 (311 stars, 17 forks). Active, but explicitly designed around Livebook workflows.
- Dashbit's own blog post ("it's Fine") recommends it for "rapid prototyping, then transition to Elixir-native solutions."

### Key constraints for Faber

**GIL bottleneck.** The GIL prevents concurrent Python execution across BEAM processes. For Faber, the eval hot-path is already native; the sidecar is one-shot per proposal. Low concurrency pressure = GIL is tolerable. But the point stands: you can't call Pythonx from multiple Elixir processes safely.

**NIF = no Burrito cross-compilation.** Pythonx is a NIF that embeds a per-platform libpython. Burrito cross-compiles NIFs using Zig as a C compiler — but it needs the NIF source compiled for the *target* platform. Pythonx's NIF wraps a full CPython interpreter DSO (`libpython3.x.so`/`.dylib`), not a simple C extension. There is no evidence (GitHub issues, forum posts, or community reports) that Pythonx + Burrito cross-compilation has been successfully used in production. This is the critical gap: cross-compiling a full embedded CPython interpreter via Zig into a Burrito binary is uncharted, high-risk territory. Even if it worked, the priv directory with bundled Python deps would need to be per-target-platform, which Burrito's current build pipeline does not support out of the box.

**Build dependency.** `uv` must be available at compile time (on the CI runner, not the end-user machine). This adds a build-time dependency but not a runtime one.

**Size.** A minimal CPython 3.11 embed with no third-party deps is ~25–40MB of compiled native code per platform, before any Python packages are added. With `dspy` for GEPA this would be hundreds of MB.

**Verdict for Faber:** Pythonx is a non-starter for the Burrito path unless its NIF cross-compilation story with Burrito is proven (currently it is not). Even if solvable, the binary size penalty is paid for a feature that is not yet needed in v1.

---

## Option 2: Bundled Python runtime sidecar (python-build-standalone / PyInstaller)

### What it is
Bundle a self-contained Python runtime alongside the Burrito binary. Two sub-options:

**2a. python-build-standalone** (astral-sh/python-build-standalone, formerly indygreg). Produces redistributable, stripped CPython tarballs for macOS aarch64, linux x86_64, etc. Updated actively (latest: 2026-06-23). Used by `uv`, `rye`, `pyenv`. The `install_only_stripped` archive removes debug symbols. Rough compressed sizes: ~20–30MB per platform for Python 3.11 stdlib-only; grows significantly with `dspy`/`torch` for GEPA.

**2b. PyInstaller frozen exe.** Freeze `python -m faber_eval` into a single self-contained executable per platform. Works well for stdlib-only code; GEPA/dspy support would require bundling numpy/torch (~200MB per platform). PyInstaller 6.21 (2025/2026) is mature, actively maintained, ~4.76M downloads/month.

### Integration with Burrito
Burrito's build pipeline has a **Patch phase** where custom files can be copied into the release dir before archiving. This is the hook to add a Python runtime or frozen sidecar. The release's `priv/` directory is available at runtime via `Application.app_dir/2` or `RELEASE_ROOT`. The Elixir sidecar layer (`Faber.Sidecar.System`) already configures the `python` path via `config :faber, :python` — changing that to point at the bundled runtime is a config-only change.

### Tradeoffs
- **Size:** stdlib-only python-build-standalone for 2 platforms (macOS arm64 + linux x86_64) adds ~40–60MB to the binary. PyInstaller frozen sidecar (stdlib-only) adds ~20–30MB per platform.
- **Cross-platform build complexity:** Must build (or download) per-platform Python artifacts and inject them into the Burrito build matrix. The CI matrix already splits macOS/linux; downloading the matching python-build-standalone tarball per target is straightforward and automated.
- **`faber.sidecar_path/0` concern:** The sidecar path must resolve correctly from within the self-extracted Burrito directory at runtime. Burrito sets `RELEASE_ROOT`; `Application.app_dir(:faber, "priv/python-runtime")` resolves correctly from a release.
- **GEPA case:** dspy requires ~200MB per platform (includes torch). That's prohibitive for a default binary. Should remain an opt-in sidecar installed separately (e.g. `pip install dspy` in a venv the user points `FABER_PYTHON` at).

**Verdict for Faber:** Option 2a (python-build-standalone, stdlib-only) is technically sound and lower-risk than Pythonx + Burrito. But it solves a problem that does not yet exist in v1: the sidecar is not exercised in the default workflow.

---

## Option 3: Port matchers to pure Elixir (native eval as the full implementation)

### Current state
This is already substantially done. `Faber.Eval.Native` + `Faber.Eval.Matchers` implement all 8 eval dimensions (6-dimension `:default` set + 2 in `:full`), plus trigger accuracy via `Faber.Eval.Trigger`. The native↔sidecar parity test (`@describetag :sidecar`) guards that both engines agree within 0.05 on the composite score. The native path is tested, hermetic, and the default.

### What would be lost
- **dspy.GEPA optimizer** (not v1; `Optimize.run/2` stubs to `not_implemented`). The v1 optimizer is the keyless reflective loop which is pure Elixir.
- **Parity tests** that cross-check Elixir vs Python. These are development-time tests; they don't need to ship in the binary.
- **Future sidecar extensions** — if someone wanted to write a new matcher in Python and have Faber pick it up without recompiling.

### What this means in practice
For the v1 single binary: the Python sidecar is **already not needed**. The binary ships with native eval only, and the sidecar is a development/advanced-use concern. No porting work is required — the porting is complete.

**Verdict for Faber:** This is the path already taken. The single-binary plan correctly notes "Native eval is the default — the binary runs keyless with zero Python at runtime." No additional work needed for v1.

---

## Option 4: Burrito extra-payload mechanics

### How Burrito handles non-BEAM files
Burrito's **Patch phase** allows custom build steps (`&MyModule.custom_step/1`) that receive and return the build context struct. During Patch, you can copy arbitrary files into the release directory before archiving. At runtime, the self-extracted directory is under `RELEASE_ROOT`, and `Application.app_dir(:faber, "priv/<subdir>")` resolves relative to it.

This means: if Faber wanted to bundle a Python runtime (Option 2), the mechanism exists. You add a custom Patch step that downloads and injects the python-build-standalone artifact for each target. The CI build matrix (mac/linux) downloads the matching tarball and copies it to `priv/python-runtime/<target>/`.

### Sizing implications
Each bundled python-build-standalone (install_only_stripped, 3.11, stdlib-only) is roughly 20–30MB compressed per platform. The Burrito binary already carries ERTS (~40MB). Adding Python would approximately double the binary size. For a "no system Python required" guarantee on the sidecar path, this is the cost.

---

## Recommendation (staged)

### Stage 1 (v1, now): Declare the sidecar optional, document it clearly
**No new packaging work needed.** The Burrito binary already works with zero Python because `Faber.Eval.Native` is the default and `Faber.Optimize.reflect/3` is the v1 loop. The single-binary plan in `.claude/plans/single-binary/plan.md` already documents "Python not needed" as a runtime assumption.

Action: Add a clear section to `README`/help output — "The `faber` binary requires no Python. The `claude` CLI is the only external dependency. Python is only needed if you opt into the experimental dspy.GEPA optimizer."

### Stage 2 (if sidecar parity tests need to ship or be run without system Python)
Use **PyInstaller** (frozen `faber_eval` sidecar) bundled via a Burrito Patch step. Since the sidecar is currently stdlib-only, the frozen exe is ~15–20MB per platform. This is the pragmatic middle ground:
- No NIF cross-compilation risk (binary, not a NIF)
- `Faber.Sidecar.System` needs one config change: point `python` at the bundled exe
- Build step: `pyinstaller --onefile python/faber_eval/__main__.py -n faber_eval` per platform in CI

This stage is not needed until sidecar parity is a user-facing feature rather than a dev-time invariant.

### Stage 3 (if/when dspy.GEPA is activated)
Keep GEPA as a separate user-installed capability: `faber setup-gepa` that creates/installs a venv with dspy and stores the path in `~/.faber/config.json`. The Elixir sidecar already reads `config :faber, :python` from runtime config. GEPA's ~200MB dependency footprint rules it out as a bundled default.

**Pythonx is not recommended for any stage** given the unproven Burrito NIF cross-compilation path and the "single process" GIL constraint that conflicts with BEAM's concurrency model.

---

## Summary of options

| Option | v1 binary Python-free? | Risk | Effort | Recommended? |
|---|---|---|---|---|
| Pythonx (embedded CPython NIF) | No (NIF; Burrito cross-compile unproven) | High | High | No |
| python-build-standalone bundled | Yes (after Patch step) | Medium | Medium | Stage 2 alt |
| PyInstaller frozen sidecar bundled | Yes (after Patch step) | Low-Medium | Low | Stage 2 |
| Native eval (already done) | Yes (default today) | None | None | Stage 1 ✓ |

---

## Sources

- Pythonx hex: https://hex.pm/packages/pythonx (v0.4.10, 2026-05)
- Pythonx hexdocs: https://pythonx.hexdocs.pm/Pythonx.html
- Dashbit blog "Running Python in Elixir, it's Fine": https://dashbit.co/blog/running-python-in-elixir-its-fine
- Pythonx GitHub (livebook-dev): https://github.com/livebook-dev/pythonx
- Burrito hexdocs v1.5.0: https://hexdocs.pm/burrito/readme.html
- Burrito GitHub: https://github.com/burrito-elixir/burrito
- python-build-standalone (astral-sh): https://github.com/astral-sh/python-build-standalone
- python-build-standalone docs: https://gregoryszorc.com/docs/python-build-standalone/main/
- PyInstaller 6.21 docs: https://www.pyinstaller.org/
- KB: `qmd://scriptorium/wiki/burrito-single-binary-distribution.md`
- KB: `qmd://scriptorium/raw/articles/research-faber-2026-06-19-single-binary-distribution.md`
- KB: `qmd://scriptorium/raw/articles/research-faber-2026-06-23-python-parity-headtohead.md`
- Faber source: `lib/faber/eval.ex`, `lib/faber/eval/native.ex`, `lib/faber/sidecar/system.ex`, `lib/faber/optimize.ex`
- Faber plan: `.claude/plans/single-binary/plan.md`
