defmodule Faber.Scan.Scope do
  @moduledoc """
  **Which project's sessions a scan is about.** Resolves the working directory into either one
  project (the default) or the whole corpus (`--all`), and gives `Faber.Scan` the two things it
  needs to honor that: a narrowed transcript base, and a per-result membership test.

  Running `faber scan` inside a project used to rank every session on the machine — 6,770
  transcripts across 60 projects on a real one, when 174 of them were the project you were standing
  in. Scoping to the cwd is both the useful default and a ~40x smaller read.

  ## Two mechanisms, because one is only an optimization

  A scope narrows through `c:Faber.Ingest.Format.project_base/2` **and** filters scored results by
  `cwd`. Neither alone is right:

    * Narrowing alone is wrong. Claude Code's directory names are a lossy flattening (`foo_bar` and
      `foo-bar` share a directory), so a directory can hold two projects' sessions.
    * Filtering alone is correct but slow — it parses the whole corpus to throw most of it away.

  So narrowing picks the cheap candidate set and the `cwd` filter decides membership. Formats that
  do not partition by project (Codex, Gemini, OpenCode) simply skip the first step: same answer,
  no speedup.

  ## Resolution order

    1. `all: true` — the user asked for the whole corpus.
    2. `base:` — an explicit root is a low-level override that already says which files to read;
       second-guessing it with a cwd filter would make `--base` unable to express "these files".
    3. Otherwise the cwd, walked **up to the git root**. Standing in `lib/faber/` scopes to the
       repo, not to a `lib/faber` "project" that has no transcripts. The walk stops at the repo
       boundary on purpose: unbounded, it would climb to `$HOME` and silently scope a scan of
       `~/Music` to whatever sessions were once run in the home directory.
    4. cwd is under no repo and has no transcript directory of its own → `:all` with
       `reason: :unknown_cwd`, which the caller must *say out loud* rather than showing an empty
       table (a scoped scan that silently finds nothing is indistinguishable from a broken one).
  """

  alias Faber.Ingest
  alias Faber.Ingest.Format

  @typedoc "`:project` (scoped to `root`) or `:all` (the whole corpus)."
  @type kind :: :project | :all

  @typedoc """
  Why a scope is `:all`, so the caller can explain itself. `nil` for `:project`.

  `:requested` (`--all`), `:explicit_base` (`--base` given), `:unknown_cwd` (no transcripts for
  this directory or its repo), `:no_cwd` (the cwd could not be read at all — a deleted working
  directory).
  """
  @type reason :: nil | :requested | :explicit_base | :unknown_cwd | :no_cwd

  @type t :: %__MODULE__{
          kind: kind(),
          # The project directory this scope covers — a session belongs iff its `cwd` is this.
          # `nil` for `:all`.
          root: Path.t() | nil,
          # Display name for the scope line (the root's basename).
          label: String.t() | nil,
          # The narrowed transcript base, when the format partitions by project. `nil` means "read
          # the format's whole base" — correct either way, just slower.
          base: Path.t() | nil,
          reason: reason()
        }

  defstruct kind: :all, root: nil, label: nil, base: nil, reason: nil

  @doc """
  Resolve a scope from scan options (`:all`, `:base`, `:format`).

  Touches the filesystem (the cwd, and whether a project's transcript directory exists), so it
  belongs to a command's run phase, never to argv parsing.
  """
  @spec resolve(keyword()) :: t()
  def resolve(opts \\ []) do
    cond do
      Keyword.get(opts, :all) == true -> %__MODULE__{kind: :all, reason: :requested}
      not is_nil(opts[:base]) -> %__MODULE__{kind: :all, reason: :explicit_base}
      true -> from_cwd(opts)
    end
  end

  defp from_cwd(opts) do
    case File.cwd() do
      {:ok, cwd} -> locate(Format.resolve(opts), Ingest.default_base(opts), cwd)
      {:error, _reason} -> %__MODULE__{kind: :all, reason: :no_cwd}
    end
  end

  # A format that partitions by project gets the directory walk; one that doesn't still scopes,
  # just without the narrowing — `base: nil` means `Faber.Scan` reads everything and lets
  # `member?/2` decide. Both paths produce the same ranking.
  defp locate(format, base, cwd) do
    case Format.project_base(format, base, cwd) do
      {:ok, _dir} -> walk(format, base, cwd)
      :error -> project(cwd, nil)
    end
  end

  defp walk(format, base, cwd) do
    case Enum.find_value(candidates(cwd), &existing_base(format, base, &1)) do
      {root, dir} -> project(root, dir)
      nil -> %__MODULE__{kind: :all, reason: :unknown_cwd}
    end
  end

  defp existing_base(format, base, dir) do
    with {:ok, project_base} <- Format.project_base(format, base, dir),
         true <- File.dir?(project_base) do
      {dir, project_base}
    else
      # `:error` (unrepresentable) and `false` (no such directory) both mean "keep walking". Matched
      # explicitly because `:error` is truthy — returning it from `find_value/2` would stop the walk
      # on the first candidate and hand back an atom where a tuple is expected.
      _ -> nil
    end
  end

  defp project(root, base),
    do: %__MODULE__{kind: :project, root: root, label: Path.basename(root), base: base}

  # cwd first, then each ancestor up to and including the git root. Without a repo the walk is just
  # the cwd: there is no principled place to stop, and guessing wrong scopes a scan to a directory
  # the user never meant.
  defp candidates(cwd) do
    chain = ancestors(cwd)

    case Enum.find(chain, &repo?/1) do
      nil -> [cwd]
      root -> Enum.take_while(chain, &(&1 != root)) ++ [root]
    end
  end

  defp ancestors(path) do
    Stream.unfold(path, fn
      nil -> nil
      p -> {p, parent(p)}
    end)
    |> Enum.to_list()
  end

  defp parent(path) do
    case Path.dirname(path) do
      # `Path.dirname("/") == "/"` — the only fixed point, and the walk's terminator.
      ^path -> nil
      up -> up
    end
  end

  # `File.exists?`, not `File.dir?`: in a git worktree `.git` is a *file* pointing at the real
  # gitdir, and a worktree is exactly the case where cwd-scoping has to keep working.
  defp repo?(dir), do: File.exists?(Path.join(dir, ".git"))

  @doc """
  Scan options that narrow discovery to this scope — `[base: dir]`, or `[]` when there is nothing
  to narrow (`:all`, a format that doesn't partition by project, or no scope at all).

  `nil` is a scope: it means "unscoped", the whole-corpus behavior `Faber.Scan.run/1` has always
  had when no caller asks for a project. Both this and `member?/2` accept it so `Faber.Scan` can
  stay branch-free.
  """
  @spec to_opts(t() | nil) :: keyword()
  def to_opts(%__MODULE__{base: base}) when is_binary(base), do: [base: base]
  def to_opts(_scope), do: []

  @doc """
  Does a scored session belong to this scope? Takes anything with a `:cwd` (a
  `Faber.Scan.Result`). `nil` (unscoped) and `:all` admit everything.

  A session whose transcript records no `cwd` falls back to the directory it was found in: that is
  evidence when discovery was narrowed to one project, and nothing at all when it wasn't.
  """
  @spec member?(t() | nil, %{optional(:cwd) => String.t() | nil}) :: boolean()
  def member?(nil, _result), do: true
  def member?(%__MODULE__{kind: :all}, _result), do: true

  def member?(%__MODULE__{} = scope, %{cwd: cwd}) when is_binary(cwd),
    do: Path.expand(cwd) == scope.root

  def member?(%__MODULE__{} = scope, _result), do: is_binary(scope.base)
end
