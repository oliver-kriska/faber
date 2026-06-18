defmodule Faber.Adapter do
  @moduledoc """
  **The adapter abstraction.** Load and validate a declarative adapter pack; the engine
  itself stays domain-free.

  An adapter supplies BOTH the *generation knowledge* (Iron Laws, investigation playbooks)
  AND the *stack-specific eval criteria* — the part a generic skill-creator cannot
  commoditize, because correct-for-Elixir ≠ correct-for-Rails. Adapters are purely
  declarative (YAML + markdown + prompt templates), so community authors write no
  host-language code.

  The pack layout and manifest schema are specified in `docs/ADAPTER_CONTRACT.md`. This
  module reads the manifest and the bulk knowledge files (`laws/laws.yaml`,
  `detect/signatures.yaml`, `investigate/playbooks.yaml`) and the eval reference
  (`eval/eval.yaml`). Validation is hand-rolled for now (required fields, types, enums,
  unique ids, `name` == directory); a richer validator (Peri/Ecto) lands when
  community-author-grade error messages are needed.
  """

  alias __MODULE__

  @severities ~w(low medium high)
  @semver ~r/^\d+\.\d+\.\d+$/
  @name_re ~r/^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/

  @type t :: %Adapter{
          name: String.t(),
          version: String.t(),
          agent_targets: [String.t()],
          file_globs: [String.t()],
          contract: String.t() | nil,
          metadata: map(),
          laws: [map()],
          signatures: [map()],
          playbooks: [map()],
          eval: map() | nil,
          dir: Path.t()
        }

  defstruct name: nil,
            version: nil,
            agent_targets: [],
            file_globs: [],
            contract: nil,
            metadata: %{},
            laws: [],
            signatures: [],
            playbooks: [],
            eval: nil,
            dir: nil

  @doc """
  Load and validate an adapter pack from `dir`.

  Returns `{:ok, %Faber.Adapter{}}` or `{:error, {:invalid_adapter, [reason]}}` with a list
  of human-readable validation failures.
  """
  @spec load(Path.t()) :: {:ok, t()} | {:error, term()}
  def load(dir) do
    with {:ok, manifest} <- read_yaml(Path.join(dir, "faber.adapter.yaml")),
         laws <- read_list(Path.join(dir, "laws/laws.yaml"), "laws"),
         signatures <- read_list(Path.join(dir, "detect/signatures.yaml"), "signatures"),
         playbooks <- read_list(Path.join(dir, "investigate/playbooks.yaml"), "playbooks"),
         eval <- read_optional_yaml(Path.join(dir, "eval/eval.yaml")),
         adapter <- build(dir, manifest, laws, signatures, playbooks, eval),
         [] <- validate(adapter) do
      {:ok, adapter}
    else
      {:error, _} = err -> err
      reasons when is_list(reasons) -> {:error, {:invalid_adapter, reasons}}
    end
  end

  @doc """
  Validate a built adapter, returning a (possibly empty) list of human-readable problems.
  Exposed for testing and for adapter authors.
  """
  @spec validate(t()) :: [String.t()]
  def validate(%Adapter{} = a) do
    dir_name = a.dir && Path.basename(a.dir)

    []
    |> req(a.name, "name is required")
    |> req(a.version, "version is required")
    |> check(
      is_list(a.agent_targets) and a.agent_targets != [],
      "agent_targets must be a non-empty list"
    )
    |> check(is_list(a.file_globs) and a.file_globs != [], "file_globs must be a non-empty list")
    |> check(is_map(a.metadata), "metadata must be a mapping")
    |> check(a.name == nil or Regex.match?(@name_re, a.name), "name must be lowercase kebab-case")
    |> check(
      a.version == nil or Regex.match?(@semver, a.version),
      "version must be MAJOR.MINOR.PATCH"
    )
    |> check(
      dir_name == nil or a.name == nil or a.name == dir_name,
      "name must equal directory name '#{dir_name}'"
    )
    |> validate_entries(a.laws, "law", &law_problems/1)
    |> validate_entries(a.signatures, "signature", &signature_problems/1)
    |> validate_entries(a.playbooks, "playbook", &playbook_problems/1)
    |> unique_ids(a.laws, "law")
    |> unique_ids(a.signatures, "signature")
    |> unique_ids(a.playbooks, "playbook")
    |> Enum.reverse()
  end

  # ── building ──────────────────────────────────────────────────────────────

  defp build(dir, manifest, laws, signatures, playbooks, eval) do
    %Adapter{
      name: manifest["name"],
      version: manifest["version"],
      agent_targets: manifest["agent_targets"] || [],
      file_globs: manifest["file_globs"] || [],
      contract: manifest["contract"],
      metadata: manifest["metadata"] || %{},
      laws: Enum.map(laws, &law/1),
      signatures: Enum.map(signatures, &signature/1),
      playbooks: Enum.map(playbooks, &playbook/1),
      eval: eval,
      dir: dir
    }
  end

  defp law(m) when is_map(m) do
    %{
      id: m["id"],
      category: m["category"],
      severity: m["severity"],
      statement: m["statement"],
      check: m["check"]
    }
  end

  defp signature(m) when is_map(m) do
    %{id: m["id"], severity: m["severity"], weight: m["weight"], body: m["body"]}
  end

  defp playbook(m) when is_map(m) do
    %{id: m["id"], source: m["source"], symptoms: m["symptoms"] || [], body: m["body"]}
  end

  # ── per-entry validation ──────────────────────────────────────────────────

  defp law_problems(%{id: id, severity: sev, statement: st}) do
    []
    |> req(id, "law missing id")
    |> req(st, "law #{id || "?"} missing statement")
    |> check(
      sev in @severities,
      "law #{id || "?"} severity must be one of #{inspect(@severities)}"
    )
  end

  defp signature_problems(%{id: id, severity: sev, weight: w}) do
    []
    |> req(id, "signature missing id")
    |> check(
      sev in @severities,
      "signature #{id || "?"} severity must be one of #{inspect(@severities)}"
    )
    |> check(is_number(w) and w >= 0 and w <= 1, "signature #{id || "?"} weight must be 0.0–1.0")
  end

  defp playbook_problems(%{id: id, symptoms: sym}) do
    []
    |> req(id, "playbook missing id")
    |> check(is_list(sym), "playbook #{id || "?"} symptoms must be a list")
  end

  defp validate_entries(acc, entries, _label, fun) do
    Enum.reduce(entries, acc, fn entry, acc -> acc ++ fun.(entry) end)
  end

  defp unique_ids(acc, entries, label) do
    dupes =
      entries
      |> Enum.map(& &1.id)
      |> Enum.reject(&is_nil/1)
      |> Enum.frequencies()
      |> Enum.filter(fn {_id, n} -> n > 1 end)
      |> Enum.map(&elem(&1, 0))

    case dupes do
      [] -> acc
      ids -> ["duplicate #{label} ids: #{inspect(ids)}" | acc]
    end
  end

  # ── small validation helpers ──────────────────────────────────────────────

  defp req(acc, nil, msg), do: [msg | acc]
  defp req(acc, "", msg), do: [msg | acc]
  defp req(acc, _value, _msg), do: acc

  defp check(acc, true, _msg), do: acc
  defp check(acc, false, msg), do: [msg | acc]

  # ── YAML readers ──────────────────────────────────────────────────────────

  defp read_yaml(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, other} -> {:error, {:not_a_mapping, path, other}}
      {:error, reason} -> {:error, {:yaml_error, path, reason}}
    end
  end

  defp read_optional_yaml(path) do
    if File.exists?(path) do
      case read_yaml(path) do
        {:ok, map} -> map
        {:error, _} -> nil
      end
    end
  end

  # Bulk list file (laws.yaml / signatures.yaml / playbooks.yaml). Absent → []. Returns the
  # top-level list under `key`, or [] if the file or key is missing.
  defp read_list(path, key) do
    case read_optional_yaml(path) do
      %{^key => list} when is_list(list) -> list
      _ -> []
    end
  end
end
