defmodule Faber.Store.Format do
  @moduledoc """
  **The on-disk format contract.** Every store that writes a versioned artifact to the user's disk
  declares — in one place, checked at compile time — what version it writes, what versions it can
  still read, and what class of data it is holding.

  ## Why this exists

  Faber grew four on-disk formats with four different postures, only one of which was declared:

  | Store | Version | Read policy | Data class |
  |---|---|---|---|
  | `Faber.Proposal.Store` | 2 | reads 1 and 2 | **paid** — LLM artifacts the user spent money on |
  | `Faber.Scan.Cache` | 1 | drops anything else | **derived** — costs a rescan to rebuild |
  | `Faber.Loop.Journal` | 1 | lenient; skips corrupt lines | **history** |
  | `Faber.Install` marker | 1 | lenient; any map | **provenance**, in the user's shared `~/.claude` |

  Three of those postures were tribal knowledge: the cache reasoned about it in a comment, the
  store learned it the hard way (a `%{"format" => @format}` match that silently ate every v1
  record — a latent data-loss bug, fixed in `e223c8b`), and two formats never considered it at all.

  The rule this encodes: **every on-disk format declares its version and its read policy, and the
  policy is a decision about the data class.** Dropping is *correct* for derived data and *fatal*
  for paid data. Making it a declaration turns that from an accident of pattern-matching into a
  choice someone made on purpose, in public, where a reviewer can see it.

  ## Usage

      defmodule Faber.Proposal.Store do
        use Faber.Store.Format,
          format: 2,
          readable_formats: [1, 2],
          data_class: :paid,
          unstamped: :unreadable
      end

  This generates `format/0`, `readable_formats/0`, `data_class/0`, `unstamped/0` and `readable?/1`.

  ## `:unstamped` — what a record with no version *means*

  The half of a read policy that is easiest to get wrong in either direction, so it must be stated:

    * `unstamped: 1` — records written **before this store declared a format** are already on the
      user's disk. They predate the key, so they are format 1 and a reader that demanded the key
      would orphan every one of them. This is the journal's and the install marker's situation.
    * `unstamped: :unreadable` — this store has stamped every record it ever wrote, so a file with
      no version did not come from here (it is foreign, corrupt, or hand-made) and reading it would
      invent a record out of whatever keys happened to parse. This is the proposal store's
      situation: format 1 wrote `"format": 1` from the start — its bug was the *reader*, which
      matched `%{"format" => @format}` exactly and so ate v1 the moment v2 shipped.

  Guessing wrong in the first direction orphans real data; guessing wrong in the second fabricates
  records from junk. Neither is a default anyone should get by accident.

  ## The compile-time assertions

  A store that bumps its version and forgets to keep reading the old one must **fail to compile**,
  not fail in production against the user's only copy of paid work:

    * `format()` must be in `readable_formats()` — a store that cannot read what it just wrote.
    * a `:paid` store must read **every** format it has ever written (`1..format()`). Paid records
      leave `readable_formats` only when they are actually gone from disk, and then loudly and on
      purpose — never as a side effect of a bump. This is exactly the bug that shipped once.
    * `unstamped: n` must name a readable format — otherwise the policy is a no-op that reads as
      an intention.

  A `:derived` store is free to drop: rebuilding costs a rescan, not money.
  """

  @typedoc "What the stored data *is* — which is what decides whether dropping it is acceptable."
  @type data_class :: :paid | :derived | :history | :provenance

  @doc "The format version this store **writes**."
  @callback format() :: pos_integer()

  @doc "Every format version this store can still **read** — not just the one it writes."
  @callback readable_formats() :: [pos_integer(), ...]

  @doc "What class of data this store holds. Decides whether dropping an old format is acceptable."
  @callback data_class() :: data_class()

  @doc "What a record carrying no version means: a format number, or `:unreadable`."
  @callback unstamped() :: pos_integer() | :unreadable

  @data_classes [:paid, :derived, :history, :provenance]

  # Classes where losing a record costs the user something no rescan can recreate, so every format
  # ever written must stay readable.
  @must_read_all [:paid]

  defmacro __using__(opts) do
    format = fetch!(opts, :format)
    readable = fetch!(opts, :readable_formats)
    data_class = fetch!(opts, :data_class)
    unstamped = fetch!(opts, :unstamped)

    validate!(format, readable, data_class, unstamped, __CALLER__)

    unstamped_readable? = unstamped != :unreadable

    quote do
      @behaviour Faber.Store.Format

      @impl Faber.Store.Format
      def format, do: unquote(format)

      @impl Faber.Store.Format
      def readable_formats, do: unquote(readable)

      @impl Faber.Store.Format
      def data_class, do: unquote(data_class)

      @impl Faber.Store.Format
      def unstamped, do: unquote(unstamped)

      @doc """
      Whether a record stamped `version` can be read by this store.

      `nil` (no version on the record) resolves via `unstamped/0` — see `Faber.Store.Format`. A
      version that is present but not an integer is never readable: it did not come from any
      encoder here.
      """
      @spec readable?(term()) :: boolean()
      def readable?(nil), do: unquote(unstamped_readable?)
      def readable?(version) when is_integer(version), do: version in unquote(readable)
      def readable?(_), do: false
    end
  end

  # `use` opts must be literals: the whole point is that these are checked when the store compiles,
  # so they cannot be values only known at runtime.
  defp fetch!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} ->
        value

      :error ->
        raise ArgumentError,
              "use Faber.Store.Format requires #{inspect(key)}. A store that writes to the " <>
                "user's disk must declare its version, its read policy, and its data class."
    end
  end

  # Shape first, then meaning: the later assertions read `format`/`readable` as numbers and lists,
  # so they are only sound once the shape checks have passed.
  defp validate!(format, readable, data_class, unstamped, caller) do
    where = "#{Path.relative_to_cwd(caller.file)}:#{caller.line}"

    well_formed_format!(where, format)
    well_formed_readable!(where, readable)
    known_data_class!(where, data_class)
    unstamped_means_something!(where, unstamped, readable)
    reads_what_it_writes!(where, format, readable)
    keeps_what_it_cannot_recreate!(where, format, readable, data_class)
  end

  defp well_formed_format!(where, format) do
    unless is_integer(format) and format > 0 do
      raise ArgumentError, "#{where}: :format must be a positive integer, got #{inspect(format)}"
    end
  end

  defp well_formed_readable!(where, readable) do
    unless is_list(readable) and readable != [] and
             Enum.all?(readable, &(is_integer(&1) and &1 > 0)) do
      raise ArgumentError,
            "#{where}: :readable_formats must be a non-empty list of positive integers, " <>
              "got #{inspect(readable)}"
    end
  end

  defp known_data_class!(where, data_class) do
    unless data_class in @data_classes do
      raise ArgumentError,
            "#{where}: :data_class must be one of #{inspect(@data_classes)}, " <>
              "got #{inspect(data_class)}"
    end
  end

  # An `:unstamped` naming a format nobody reads is a no-op that reads as an intention: "unstamped
  # records are v1" while v1 isn't readable still drops them, just less obviously.
  defp unstamped_means_something!(where, unstamped, readable) do
    unless unstamped == :unreadable or (is_integer(unstamped) and unstamped in readable) do
      raise ArgumentError,
            "#{where}: :unstamped must be :unreadable or a format in :readable_formats " <>
              "#{inspect(readable)}, got #{inspect(unstamped)}. It says what a record carrying " <>
              "no version means — records that predate the key (:unstamped 1), or nothing this " <>
              "store ever wrote (:unreadable)."
    end
  end

  defp reads_what_it_writes!(where, format, readable) do
    unless format in readable do
      raise ArgumentError,
            "#{where}: this store writes format #{format} but cannot read it " <>
              "(:readable_formats is #{inspect(readable)}). It would not be able to read " <>
              "back what it just wrote."
    end
  end

  # The assertion this module exists for: bump the version, forget the old records, ship.
  defp keeps_what_it_cannot_recreate!(where, format, readable, data_class)
       when data_class in @must_read_all do
    case Enum.reject(1..format//1, &(&1 in readable)) do
      [] ->
        :ok

      dropped ->
        raise ArgumentError, """
        #{where}: this store holds #{inspect(data_class)} data at format #{format}, but \
        :readable_formats #{inspect(readable)} drops format(s) #{inspect(dropped)}.

        Records in those formats may still be on the user's disk, and #{inspect(data_class)} data \
        cannot be recreated by rescanning — the user paid for it. Dropping a format is a \
        deliberate act (the records are actually gone), not a side effect of a version bump.

        Keep #{inspect(dropped)} in :readable_formats, or change :data_class if this store no \
        longer holds #{inspect(data_class)} data.
        """
    end
  end

  # Every other class may drop: rebuilding derived data costs a rescan, not money.
  defp keeps_what_it_cannot_recreate!(_where, _format, _readable, _data_class), do: :ok
end
