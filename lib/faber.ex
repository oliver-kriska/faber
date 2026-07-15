defmodule Faber do
  @moduledoc """
  Faber — a local-first, cross-agent, stack-aware improvement engine for AI coding agents.

  Faber mines your real coding-agent sessions for repetitive, painful workflows, then
  generates **skills** that automate them — but only skills that a stack-specific
  **adapter** vouches for and that pass an **evaluation gate**. Over time it runs a
  self-improving loop to make those skills better.

  > *"It mines your sessions for pain and emits skills your stack's expert adapter vouches for."*

  This module is the public entry point. The pipeline is split across contexts that map
  one-to-one onto the loop stages (see `HANDOFF.md` §7):

    * `Faber.Ingest`  — parse coding-agent session transcripts into a normalized form.
    * `Faber.Detect`  — score friction / repetition (generic + adapter signatures).
    * `Faber.Adapter` — load the declarative adapter pack (laws, eval criteria, templates).
    * `Faber.Eval`    — gate proposed skills via the Python eval sidecar.
    * `Faber.Loop`    — the autoresearch loop: generate → eval → keep-winner, until plateau.

  See `HANDOFF.md` for the full product thesis, architecture decision, and milestones.
  """

  @default_adapter "faber-elixir"

  @doc """
  Resolve the reference adapter directory, working both from the repo and from a packaged release.

  Order: explicit `config :faber, :adapter_dir` → the release root (`RELEASE_ROOT`, where the
  single binary unpacks the bundled `adapters/`) → the repo-relative `adapters/<name>` for dev/test.
  """
  @spec adapter_dir(String.t()) :: Path.t()
  def adapter_dir(name \\ @default_adapter) do
    cond do
      dir = Application.get_env(:faber, :adapter_dir) -> dir
      root = System.get_env("RELEASE_ROOT") -> Path.join([root, "adapters", name])
      true -> Path.join("adapters", name)
    end
  end

  @doc """
  Faber's own state directory (`~/.faber` by default).

  Order: `config :faber, :home_dir` → `FABER_HOME` → `~/.faber`. The `FABER_HOME` step matches
  `config/runtime.exs`, which resolves the same dir to persist `secret_key_base` — if the two
  disagreed, a user who set `FABER_HOME` would get their secret in one tree and their cache and
  proposals in another.

  Distinct from the *agents'* dirs (`~/.claude`, …), which Faber only ever writes into through
  `Faber.Install`'s provenance-marked path. This one is Faber's alone, so it can be created,
  pruned, and wiped without touching anything the user owns.
  """
  @spec home_dir() :: Path.t()
  def home_dir do
    Application.get_env(:faber, :home_dir) || System.get_env("FABER_HOME") ||
      Path.join([System.user_home() || File.cwd!(), ".faber"])
  end

  @doc """
  `mkdir -p` a directory in Faber's home, keeping the tree private (`0700`).

  Everything Faber stores here is derived from the user's private session transcripts — project
  paths, cwds, touched files, LLM output — so the tree gets the same treatment as the eval temp
  dir and `secret_key_base`, and for the same reason: a umask default of `0755` leaves it readable
  to every local user who can traverse the home dir.

  The home dir is tightened too, not just the leaf: `mkdir_p` creates `~/.faber` as a side effect,
  and a private `cache/` inside a world-readable `.faber/` still leaks what is in there. That step
  is **best-effort** on purpose — `:cache_dir` and `:proposals_dir` are independently overridable,
  so `dir` need not live under the home dir at all (the test suite points them elsewhere), and
  failing to chmod an unrelated — possibly nonexistent — directory must not fail the write.
  """
  @spec mkdir_private(Path.t()) :: :ok | {:error, File.posix()}
  def mkdir_private(dir) do
    with :ok <- File.mkdir_p(dir) do
      _ = File.chmod(home_dir(), 0o700)
      File.chmod(dir, 0o700)
    end
  end

  @doc """
  Write `contents` to `path` atomically and privately: tmp file → `0600` → rename.

  The chmod lands on the **tmp file, before the rename**. Doing it after would leave the contents
  world-readable for the entire duration of the write, which is the window that matters. The
  containing dir's `0700` (see `mkdir_private/1`) is the real control; this is defense in depth for
  the moment the dir's mode is wrong or overridden.

  Write-then-rename also means a crash mid-write leaves the previous file intact rather than a
  truncated one. Note `rename` returning is not an `fsync` — this survives a BEAM crash, not a
  power cut.
  """
  @spec write_private(Path.t(), iodata()) :: :ok | {:error, File.posix()}
  def write_private(path, contents) do
    tmp = path <> ".tmp"

    with :ok <- File.write(tmp, contents),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, _} = err ->
        File.rm(tmp)
        err
    end
  end

  @doc """
  Where recomputable derived state lives (`~/.faber/cache`).

  Everything under here is a **cache**: safe to delete at any time, and any read that fails for
  any reason must fall back to recomputing rather than erroring. Contrast `proposals_dir/0`.
  """
  @spec cache_dir() :: Path.t()
  def cache_dir do
    Application.get_env(:faber, :cache_dir) || Path.join(home_dir(), "cache")
  end

  @doc """
  Where proposals are kept (`~/.faber/proposals`).

  **Not** a cache: a proposal costs real LLM tokens to produce, so it is never invalidated or
  evicted on Faber's initiative — only the user deletes one. See `Faber.Proposal.Store`.
  """
  @spec proposals_dir() :: Path.t()
  def proposals_dir do
    Application.get_env(:faber, :proposals_dir) || Path.join(home_dir(), "proposals")
  end
end
