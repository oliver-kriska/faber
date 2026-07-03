defmodule Faber.Consolidate do
  @moduledoc """
  **Merge overlapping skill proposals into one stronger skill.** Scanning many sessions produces
  near-duplicate proposals — dogfooding against a real external project yielded several variants
  of the same "investigate before retrying" skill. Installing all of them pollutes routing (three
  descriptions competing for the same request); this module consolidates them, in two deliberately
  separated stages:

    * `cluster/2` — **pure and deterministic**: group proposals whose name + description + trigger
      fixtures share vocabulary (token Jaccard, single-linkage, greedy in input order). No LLM,
      unit-testable, and the caller can inspect clusters before spending tokens.
    * `merge/3` — **LLM-written**: one call per multi-proposal cluster, producing a single merged
      proposal through the SAME structured schema the proposer uses (`Faber.Propose.schema/0`).

  `run/3` composes them and gates every merge through `Faber.Eval.gate/2` — a merged skill that
  scores below the bar is rejected and the originals are kept, so consolidation can never trade
  quality for tidiness. Library-level v1: collect proposals (e.g. across `Faber.Propose` runs),
  then consolidate before installing.
  """

  alias Faber.{Adapter, Eval, LLM, Propose, Proposal}

  @default_threshold 0.3

  @typedoc """
  One consolidation outcome per cluster, in input order:

    * `{:kept, proposal}` — singleton cluster, passed through untouched (no LLM call).
    * `{:merged, merged, eval, originals}` — the merge passed the eval gate.
    * `{:kept_originals, originals, eval}` — the merge FAILED the gate; originals survive.
    * `{:error, originals, reason}` — the merge LLM call failed; originals survive.
  """
  @type outcome ::
          {:kept, Proposal.t()}
          | {:merged, Proposal.t(), map(), [Proposal.t()]}
          | {:kept_originals, [Proposal.t()], map()}
          | {:error, [Proposal.t()], term()}

  @doc """
  Cluster `proposals` by token overlap. Returns a list of clusters (each a list of proposals),
  deterministic for a given input order (greedy single-linkage: a proposal joins the first
  existing cluster containing any member with Jaccard similarity ≥ `:threshold`, default
  `#{@default_threshold}`).
  """
  @spec cluster([Proposal.t()], keyword()) :: [[Proposal.t()]]
  def cluster(proposals, opts \\ []) do
    threshold = opts[:threshold] || @default_threshold

    proposals
    |> Enum.map(&{&1, tokens(&1)})
    |> Enum.reduce([], fn {p, toks}, clusters ->
      case Enum.split_while(clusters, fn members ->
             not Enum.any?(members, fn {_mp, mtoks} -> jaccard(toks, mtoks) >= threshold end)
           end) do
        {_all, []} -> clusters ++ [[{p, toks}]]
        {before, [hit | rest]} -> before ++ [hit ++ [{p, toks}] | rest]
      end
    end)
    |> Enum.map(fn members -> Enum.map(members, &elem(&1, 0)) end)
  end

  @doc """
  Merge one cluster of proposals into a single proposal via the configured LLM (same `:llm` /
  `:model` / `:stub_response` opts as `Faber.Propose.propose/3`). The merged proposal's `source`
  records `merged_from` (names) and the union of source session ids.
  """
  @spec merge([Proposal.t()], Adapter.t(), keyword()) :: {:ok, Proposal.t()} | {:error, term()}
  def merge([%Proposal{} = only], _adapter, _opts), do: {:ok, only}

  def merge([%Proposal{} | _] = proposals, %Adapter{} = adapter, opts) do
    opts = Keyword.put(opts, :system_prompt, merge_system_prompt(adapter))

    case LLM.generate_object(merge_user_prompt(proposals), Propose.schema(), opts) do
      {:ok, object} -> {:ok, build_merged(object, proposals, adapter)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Cluster, merge every multi-proposal cluster, and gate each merge through `Faber.Eval.gate/2`
  (opts are forwarded — `:threshold` here is the CLUSTER threshold; pass `:eval_threshold` to
  override the gate's bar). Returns one `t:outcome/0` per cluster, in input order.
  """
  @spec run([Proposal.t()], Adapter.t(), keyword()) :: [outcome()]
  def run(proposals, %Adapter{} = adapter, opts \\ []) do
    gate_opts =
      opts
      |> Keyword.take([:llm, :model, :sidecar, :engine, :eval_set, :trigger, :trigger_samples])
      |> Keyword.put(:adapter, adapter)
      |> then(fn go ->
        case opts[:eval_threshold] do
          nil -> go
          t -> Keyword.put(go, :threshold, t)
        end
      end)

    proposals
    |> cluster(opts)
    |> Enum.map(fn
      [only] ->
        {:kept, only}

      members ->
        case merge(members, adapter, opts) do
          {:ok, merged} ->
            case Eval.gate(merged, gate_opts) do
              {:pass, eval} -> {:merged, merged, eval, members}
              {:fail, eval} -> {:kept_originals, members, eval}
              {:error, reason} -> {:error, members, reason}
            end

          {:error, reason} ->
            {:error, members, reason}
        end
    end)
  end

  # ── similarity ──────────────────────────────────────────────────────────────

  # The vocabulary a proposal competes for at routing time: its name, description, and trigger
  # phrasings. Words < 3 chars drop out (articles/stopwords dominate Jaccard otherwise).
  defp tokens(%Proposal{} = p) do
    [p.name || "", p.description || ""]
    |> Kernel.++(p.should_trigger || [])
    |> Enum.join(" ")
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/, trim: true)
    |> Enum.filter(&(String.length(&1) >= 3))
    |> MapSet.new()
  end

  defp jaccard(a, b) do
    union = MapSet.union(a, b) |> MapSet.size()

    if union == 0 do
      0.0
    else
      MapSet.intersection(a, b) |> MapSet.size() |> Kernel./(union)
    end
  end

  # ── merge prompt / struct ───────────────────────────────────────────────────

  defp merge_system_prompt(%Adapter{} = adapter) do
    """
    You are a skill editor for AI coding agents. You will be given SEVERAL overlapping draft
    skills that were proposed independently for the same kind of friction on the same stack
    (#{adapter.name} v#{adapter.version}). Merge them into EXACTLY ONE skill that supersedes all
    of them.

    Merge rules:
    - Keep the sharpest name (or coin a clearer one, lowercase-kebab).
    - description: 50–250 chars, "what + when" — cover the UNION of the drafts' trigger scenarios
      without becoming vague; add a "NOT for …" clause if the drafts disambiguated one.
    - iron_laws: dedupe semantically; keep every distinct non-negotiable (≥3 total).
    - workflow / patterns: keep the most actionable union, deduped, ≤6 steps / ≤4 patterns.
    - usage / example: keep the single strongest of each (examples must be ≥2 lines).
    - should_trigger / should_not_trigger: union of the drafts' fixtures, deduped, so the merged
      skill still routes for every phrasing the drafts covered.

    Return the structured object only.
    """
  end

  defp merge_user_prompt(proposals) do
    drafts =
      proposals
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {p, i} ->
        """
        ### Draft #{i}: #{p.name}
        - description: #{p.description}
        - rationale: #{p.rationale}
        - iron_laws: #{fmt_list(p.iron_laws)}
        - usage: #{p.usage || "(none)"}
        - example: #{p.example || "(none)"}
        - workflow: #{fmt_list(p.workflow)}
        - patterns: #{fmt_list(p.patterns)}
        - should_trigger: #{fmt_list(p.should_trigger)}
        - should_not_trigger: #{fmt_list(p.should_not_trigger)}
        """
      end)

    """
    Merge these #{length(proposals)} overlapping draft skills into one:

    #{drafts}
    """
  end

  defp build_merged(object, proposals, %Adapter{} = adapter) do
    sessions =
      proposals
      |> Enum.map(& &1.source[:session_id])
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    %Proposal{
      name: get(object, :name),
      description: get(object, :description),
      effort: get(object, :effort) || "medium",
      rationale: get(object, :rationale),
      iron_laws: get_list(object, :iron_laws),
      usage: get(object, :usage),
      example: get(object, :example),
      workflow: get_list(object, :workflow),
      patterns: get_list(object, :patterns),
      should_trigger: get_list(object, :should_trigger),
      should_not_trigger: get_list(object, :should_not_trigger),
      adapter: adapter.name,
      source: %{
        merged_from: Enum.map(proposals, & &1.name),
        session_ids: sessions
      }
    }
  end

  # LLM objects may key on atoms or strings depending on the provider/schema compiler (same
  # tolerance as Faber.Propose).
  defp get(map, key) when is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, v} -> v
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp get_list(map, key) do
    case get(map, key) do
      list when is_list(list) -> list
      nil -> []
      other -> [other]
    end
  end

  defp fmt_list([]), do: "(none)"
  defp fmt_list(nil), do: "(none)"
  defp fmt_list(list), do: Enum.join(list, " | ")
end
