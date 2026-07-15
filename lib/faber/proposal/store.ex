defmodule Faber.Proposal.Store do
  @moduledoc """
  Durable storage for proposals — the artifacts that cost real LLM tokens.

  Producing a proposal runs `Faber.Propose.propose/2` and `Faber.Eval.score/2`, i.e. it spends the
  user's money. Until this module existed, that artifact lived only in the dashboard LiveView's
  assigns: refreshing the browser destroyed it, and the only way to get it back was to pay again.
  That is the bug this fixes.

  ## Not a cache

  `Faber.Scan.Cache` and this module look superficially alike and are governed by opposite rules,
  because their loss functions differ by orders of magnitude:

  | | `Scan.Cache` | `Proposal.Store` |
  |---|---|---|
  | losing an entry costs | ~9s of rescanning | tokens, unrecoverably |
  | on stale input | invalidate and recompute | **keep**, and mark stale |
  | write timing | debounced | immediate, before the caller is told it succeeded |
  | user may delete it | yes, freely | only the user, never Faber |

  So nothing here is ever evicted, expired, or invalidated on Faber's initiative. When the session
  a proposal came from changes, the proposal doesn't stop being worth what was paid for it — it
  just stops matching, which `stale?/2` reports and the reader decides about.

  ## Shape

  One JSON file per proposal under `~/.faber/proposals`, named `<session>-<content>.json` from the
  hashes of each. Plain files rather than an ETS table with a snapshot, for reasons that all follow
  from "this is the user's paid data on the user's disk":

    * a `put/2` is durable when it returns — there is no debounce window in which a crash costs
      money, which is exactly the tradeoff `Scan.Cache` is free to make and this isn't;
    * hashing the *content* into the name makes re-proposing the same skill idempotent while a
      genuinely different proposal lands beside its predecessor rather than overwriting it, so
      "keep everything paid for" holds without a history mechanism;
    * `<session>-*` is a glob, so reading one session's proposals touches only its own files;
    * it's greppable, and the user can read or delete a proposal with `cat` and `rm` — no Faber.
  """

  alias Faber.Scan

  require Logger

  @format 1

  # The exact shape of `id/2`: two truncated-sha256 hex hashes. Used to validate ids that reach
  # `delete/1` from outside this module.
  @id_re ~r/\A[0-9a-f]{12}-[0-9a-f]{12}\z/

  @type t :: %{
          id: String.t(),
          session_key: String.t(),
          session_path: String.t() | nil,
          session_stamp: term(),
          name: String.t(),
          md: String.t(),
          eval: map(),
          adapter: String.t() | nil,
          created_at: String.t()
        }

  @doc """
  Whether proposals are persisted at all (`config :faber, :proposal_store`, default `true`).

  Exists because writing to a fixed directory is global side-effecting state: the suite runs with
  this off so that async tests exercising the propose path stay independent of each other, and the
  store's own tests turn it on against a tmp dir. Off ⇒ `put/2` writes nothing and `latest/1` finds
  nothing, i.e. exactly the pre-store behavior.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:faber, :proposal_store, true) == true

  @doc """
  Persist a proposal for `result`'s session. Durable once it returns `{:ok, record}`.

  `attrs` carries the paid output: `:name`, `:md`, and optionally `:eval` and `:adapter`. Writing
  the same content twice for the same session is idempotent (same id, refreshed on disk); writing
  *different* content adds a record and leaves the earlier one alone.
  """
  @spec put(Scan.Result.t() | String.t(), map()) :: {:ok, t()} | {:error, term()}
  def put(result_or_key, attrs)

  def put(%Scan.Result{} = result, attrs) do
    result
    |> session_key()
    |> do_put(attrs, session_path: result.path, session_stamp: stamp_digest(result.stamp))
  end

  def put(session_key, attrs) when is_binary(session_key) do
    do_put(session_key, attrs, [])
  end

  defp do_put(session_key, attrs, meta) do
    name = Map.fetch!(attrs, :name)
    md = Map.fetch!(attrs, :md)

    record = %{
      format: @format,
      id: id(session_key, md),
      session_key: session_key,
      session_path: meta[:session_path],
      session_stamp: meta[:session_stamp],
      name: name,
      md: md,
      eval: Map.get(attrs, :eval, %{}),
      adapter: Map.get(attrs, :adapter),
      created_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    with :ok <- if(enabled?(), do: :ok, else: {:error, :disabled}),
         {:ok, json} <- encode(record),
         :ok <- Faber.mkdir_private(dir()),
         :ok <- Faber.write_private(path_for(record.id), json) do
      {:ok, record}
    else
      {:error, :disabled} ->
        {:error, :disabled}

      {:error, reason} = err ->
        # Loud: a failure here means a paid artifact did not reach disk. The caller still has it in
        # memory and can show it, but it will not survive a refresh — which is the whole point.
        Logger.warning("faber proposal store: could not persist #{name} — #{inspect(reason)}")
        err
    end
  end

  @doc """
  The most recent proposal for a session, or `nil`.

  This is what a dashboard mount calls to put back what a browser refresh would otherwise have
  thrown away.
  """
  @spec latest(Scan.Result.t() | String.t()) :: t() | nil
  def latest(result_or_key) do
    result_or_key
    |> list_for()
    |> List.first()
  end

  @doc """
  Every stored proposal for a session, newest first.
  """
  @spec list_for(Scan.Result.t() | String.t()) :: [t()]
  def list_for(%Scan.Result{} = result), do: result |> session_key() |> list_for()

  def list_for(session_key) when is_binary(session_key) do
    # Guarded on the read side too, not just the write: a dir left over from an earlier run would
    # otherwise still be served while the store is nominally off.
    if enabled?() do
      dir()
      |> Path.join("#{hash(session_key)}-*.json")
      |> Path.wildcard()
      |> read_all()
    else
      []
    end
  end

  @doc """
  Every stored proposal, newest first.
  """
  @spec list() :: [t()]
  def list do
    if enabled?() do
      dir()
      |> Path.join("*.json")
      |> Path.wildcard()
      |> read_all()
    else
      []
    end
  end

  @doc """
  Delete one stored proposal by id.

  Faber only ever calls this on the user's explicit instruction — see the moduledoc.
  """
  @spec delete(String.t()) :: :ok
  def delete(id) do
    # `id` is untrusted despite looking internal: `read/1` lifts it straight out of a proposal's
    # JSON, so a hand-edited file could carry `"../../../.ssh/known_hosts"` — and the obvious way to
    # wire a delete button is `Store.delete(record.id)`. `id/2` only ever produces two 12-char hex
    # hashes, so anything else is not ours to remove. Guarded now, while there are no callers and
    # it is free.
    if Regex.match?(@id_re, id), do: File.rm(path_for(id))
    :ok
  end

  @doc """
  Whether `record` was produced from a different version of the session than `result` is now.

  Reported, never acted on: a stale proposal is still a paid artifact, so this exists so a reader
  can *say* "the session has moved on since this was generated", not so anything can drop it.

  Compares `Scan.Result.stamp` — the source's content stamp. An earlier version of this compared
  `fingerprint`, which looks like a content signature and is not: it's a six-bucket session-*type*
  label keyed off the first ten human messages, so it stays `"bug-fix"` while a session grows from
  6 messages to 800. That made `stale?/2` answer `false` for almost every session that had in fact
  moved on. `nil` stamp (an uncacheable source, or a record predating this) ⇒ `false`: unknown is
  reported as not-stale, never as stale.
  """
  @spec stale?(t(), Scan.Result.t()) :: boolean()
  def stale?(record, %Scan.Result{} = result) do
    current = stamp_digest(result.stamp)

    not is_nil(record.session_stamp) and not is_nil(current) and record.session_stamp != current
  end

  # ── Internals ─────────────────────────────────────────────────────────────────────────────────

  defp dir, do: Faber.proposals_dir()

  # `session_id` is the real identity — the same session can be reached by different paths (and the
  # `:ccrider` source labels it differently from the `:files` one). Fall back to the label only when
  # a transcript carries no id.
  defp session_key(%Scan.Result{session_id: id}) when is_binary(id) and id != "", do: id
  defp session_key(%Scan.Result{path: path}), do: path

  defp id(session_key, md), do: "#{hash(session_key)}-#{hash(md)}"

  # A source stamp is an opaque term — `{mtime, size}` for files, a 3-tuple for ccrider — and Jason
  # cannot encode tuples at all, so the raw stamp can't be stored. Hash it to an integer: JSON-safe,
  # compared only for equality (which is all `stale?/2` needs), and `:erlang.phash2/1` is specified
  # to be stable across nodes and releases, so a stamp stored today still compares correctly to one
  # computed after a restart or an upgrade.
  defp stamp_digest(nil), do: nil
  defp stamp_digest(stamp), do: :erlang.phash2(stamp)

  defp hash(value) do
    :sha256
    |> :crypto.hash(value)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end

  defp path_for(id), do: Path.join(dir(), "#{id}.json")

  defp encode(record) do
    Jason.encode(record, pretty: true)
  rescue
    e -> {:error, e}
  end

  defp read_all(paths) do
    paths
    |> Enum.map(&read/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.created_at, :desc)
  end

  defp read(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"format" => @format} = raw} <- Jason.decode(body) do
      %{
        id: raw["id"],
        session_key: raw["session_key"],
        session_path: raw["session_path"],
        session_stamp: raw["session_stamp"],
        name: raw["name"],
        md: raw["md"],
        eval: normalize_eval(raw["eval"]),
        adapter: raw["adapter"],
        created_at: raw["created_at"]
      }
    else
      # A single unreadable file must not blind the reader to the rest of a session's proposals.
      _ -> nil
    end
  end

  # JSON has no atoms, so a naive round-trip hands back `%{"composite" => _}` for something that
  # went in as `%{composite: _}` — an asymmetry every caller would eventually get wrong. Map the
  # scores back to atoms so `put/2` and `latest/1` speak the same shape.
  #
  # Allowlisted rather than `String.to_atom/1`: these files are on disk and hand-editable, and
  # atomizing arbitrary keys from them would leak into a table that is never garbage-collected.
  # Anything unrecognized keeps its string key instead of being dropped — an unknown score is still
  # information the user paid for.
  # A literal string→atom map, so compiling THIS module creates the atoms. The previous version
  # used `String.to_existing_atom/1` over a `~w(...)` list of strings — which never creates them,
  # leaving it dependent on `Faber.Eval` (where `:dimensions` is defined) happening to be loaded
  # first. BEAM module loading is lazy, and `read/1`'s `else _ -> nil` catches *mismatches*, not
  # *raises*, so an unlucky ordering would propagate out of `list_for/1` instead of skipping a file.
  #
  # Still an allowlist, for the original reason: these files are hand-editable, and atomizing
  # arbitrary keys from them would grow a table that is never garbage-collected. An unrecognized
  # key keeps its string rather than being dropped — an unknown score is still paid-for information.
  @eval_keys %{
    "composite" => :composite,
    "passed" => :passed,
    "threshold" => :threshold,
    "dimensions" => :dimensions
  }

  defp normalize_eval(eval) when is_map(eval) do
    Map.new(eval, fn {k, v} = pair ->
      case @eval_keys do
        %{^k => atom} -> {atom, v}
        _ -> pair
      end
    end)
  end

  defp normalize_eval(_), do: %{}
end
