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

  @format 2

  # Every format this reader understands, NOT just the one it writes. `read/1` drops anything it
  # cannot match (`_ -> nil`), so shipping `@format 2` without listing 1 here would make every
  # artifact written before the bump silently vanish from `list/0` — in the one module whose entire
  # purpose is that paid work survives. A format leaves this list only when its records are actually
  # gone, and then loudly, never by a bump.
  @readable_formats [1, 2]

  # The exact shape of `id/2`: two truncated-sha256 hex hashes. Used to validate ids that reach
  # `delete/1` from outside this module.
  @id_re ~r/\A[0-9a-f]{12}-[0-9a-f]{12}\z/

  @typedoc """
  What this artifact *is*, which changes what it means and how it can be reproduced:

    * `:single` — one session, one draft (`propose`/`refine`, or the dashboard).
    * `:merged` — an LLM merge of several drafts that passed the eval gate. Spans sessions, so
      `propose --rank N` cannot reproduce it: this record is the only copy.
    * `:kept` — a singleton cluster in a consolidate run, passed through untouched.
    * `:kept_original` — an original that survived because its cluster's merge did not: the merge
      scored below the gate, or the merge call itself failed. Either way the original is a real
      draft that cost real tokens.
  """
  @type outcome :: :single | :merged | :kept | :kept_original

  @type t :: %{
          id: String.t(),
          session_key: String.t(),
          session_path: String.t() | nil,
          session_stamp: term(),
          name: String.t(),
          md: String.t(),
          eval: map(),
          adapter: String.t() | nil,
          outcome: outcome(),
          source_sessions: [String.t()],
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

  `attrs` carries the paid output: `:name`, `:md`, and optionally `:eval`, `:adapter`, `:outcome`
  (default `:single`) and `:source_sessions`. Writing the same content twice for the same session is
  idempotent (same id, refreshed on disk); writing *different* content adds a record and leaves the
  earlier one alone.

  `:source_sessions` is every session that fed this artifact, defaulting to `[session_key]`. It
  exists for `:merged`, which is drawn from several sessions at once — `session_key` can only name
  one of them (it is what the id and the read glob are built from), so without this the other
  originals of a merge would be unrecorded, and a merge is exactly the artifact that no `propose
  --rank N` can reproduce.
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
      id: id(session_key, md),
      session_key: session_key,
      session_path: meta[:session_path],
      session_stamp: meta[:session_stamp],
      name: name,
      md: md,
      eval: Map.get(attrs, :eval, %{}),
      adapter: Map.get(attrs, :adapter),
      outcome: Map.get(attrs, :outcome, :single),
      source_sessions: Map.get(attrs, :source_sessions) || [session_key],
      created_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    with :ok <- if(enabled?(), do: :ok, else: {:error, :disabled}),
         # `:format` is added for the ENCODE only, never to the returned record: it is a property of
         # the file, not of the proposal, and `read/1` strips it back off. Returning it here made
         # `put/2` and `latest/1` hand back different shapes for the same record — the same
         # writer/reader asymmetry @eval_keys exists to prevent, and one dialyzer caught the moment
         # a caller first pattern-matched on `put/2` (the dashboard, the only writer until now,
         # ignores its return).
         {:ok, json} <- encode(Map.put(record, :format, @format)),
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
  Find one stored proposal by id or by an unambiguous **prefix** of one (git-style).

  Returns `{:ok, record}`, `{:error, :not_found}`, or `{:error, {:ambiguous, [record]}}` with every
  candidate so a caller can show them rather than guess.

  Ids are two 12-hex hashes, `<session>-<content>`, which is stable and greppable but not something
  anyone retypes. Note the FIRST segment is the session: every proposal drafted from one session
  shares that prefix, so a short prefix is ambiguous exactly where it gets used most (re-proposing
  the same session). That is why ambiguity is an error carrying the candidates, not a first-match.
  """
  @spec find(String.t()) :: {:ok, t()} | {:error, :not_found | {:ambiguous, [t()]}}
  def find(id_or_prefix) when is_binary(id_or_prefix) do
    case Enum.filter(list(), &String.starts_with?(&1.id, id_or_prefix)) do
      [record] -> {:ok, record}
      [] -> {:error, :not_found}
      # An exact id is never ambiguous, even though it is also a prefix of itself: prefer it over
      # the longer ids it happens to prefix.
      many -> exact_or_ambiguous(many, id_or_prefix)
    end
  end

  defp exact_or_ambiguous(candidates, id) do
    case Enum.find(candidates, &(&1.id == id)) do
      nil -> {:error, {:ambiguous, candidates}}
      record -> {:ok, record}
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
  Delete all but the `keep` newest proposals. Returns the records that were removed.

  This is the **only** thing that removes a proposal, and it exists solely because a human asked
  (`faber proposals --prune`). It is not eviction, not expiry, and nothing calls it on Faber's
  initiative — see the moduledoc's table: losing an entry here costs tokens, unrecoverably, so the
  decision belongs to the person who paid for them. Newest-first by `created_at`, matching what
  `list/0` shows, so the user prunes what they were looking at.
  """
  @spec prune(pos_integer()) :: [t()]
  def prune(keep) when is_integer(keep) and keep >= 0 do
    {_kept, dropped} = list() |> Enum.split(keep)

    Enum.each(dropped, &delete(&1.id))
    dropped
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
         {:ok, raw} <- Jason.decode(body),
         true <- raw["format"] in @readable_formats do
      decode(raw)
    else
      # A single unreadable file must not blind the reader to the rest of a session's proposals.
      _ -> nil
    end
  end

  defp decode(raw) do
    session_key = raw["session_key"]

    %{
      id: raw["id"],
      session_key: session_key,
      session_path: raw["session_path"],
      session_stamp: raw["session_stamp"],
      name: raw["name"],
      md: raw["md"],
      eval: normalize_eval(raw["eval"]),
      adapter: raw["adapter"],
      # Defaults that carry a format-1 record forward rather than dropping it. A v1 record is a
      # single-session draft by construction: the CLI did not write to this store at all when v1 was
      # the only format, and the dashboard's only writer proposes exactly one session.
      outcome: decode_outcome(raw["outcome"]),
      source_sessions: raw["source_sessions"] || List.wrap(session_key),
      created_at: raw["created_at"]
    }
  end

  # Allowlisted for the same reason as @eval_keys: these files are hand-editable, and
  # String.to_atom/1 on their contents grows a table that is never garbage-collected. An
  # unrecognized (or absent, i.e. format-1) outcome reads as :single.
  @outcomes %{
    "single" => :single,
    "merged" => :merged,
    "kept" => :kept,
    "kept_original" => :kept_original
  }

  defp decode_outcome(value), do: Map.get(@outcomes, value, :single)

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
  # Every key of `t:Faber.Eval.result/0`, plus `trigger` (folded in dynamically under `trigger:
  # true`). Listing only four of them was the very asymmetry the note above warns about: `:engine`
  # went in as an atom and came back as `"engine"`, so a reader that stored the eval and one that
  # re-read it disagreed about the same map. `:engine` matters most of all — it distinguishes the
  # adapter's stack-specific verdict from `"native:fallback"`, which certifies generic markdown
  # structure and not the stack's bar (see Faber.Eval's @typedoc). A reader must not have to guess
  # which one it is holding.
  @eval_keys %{
    "composite" => :composite,
    "passed" => :passed,
    "threshold" => :threshold,
    "dimensions" => :dimensions,
    "engine" => :engine,
    "schema_version" => :schema_version,
    "weight_total" => :weight_total,
    "trigger" => :trigger
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
