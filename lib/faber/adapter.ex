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

  require Logger

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
          fingerprint_rules: [map()],
          opportunity_rules: [map()],
          skill_namespaces: [String.t()],
          playbooks: [map()],
          eval: map() | nil,
          templates: %{optional(String.t()) => String.t()},
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
            # Detection vocab (contract §4.1): stack-specific fingerprint command-bonuses,
            # opportunity→skill rules, and skill namespaces. Empty ⇒ engine defaults apply
            # only when this adapter isn't selected (see `Faber.Detect`).
            fingerprint_rules: [],
            opportunity_rules: [],
            skill_namespaces: [],
            playbooks: [],
            eval: nil,
            templates: %{},
            dir: nil

  @doc """
  Load and validate an adapter pack from `dir`.

  Returns `{:ok, %Faber.Adapter{}}` or `{:error, {:invalid_adapter, [reason]}}` with a list
  of human-readable validation failures.
  """
  @spec load(Path.t()) :: {:ok, t()} | {:error, term()}
  def load(dir) do
    with {:ok, manifest} <- read_yaml(Path.join(dir, "faber.adapter.yaml")),
         {:ok, laws} <- read_list(Path.join(dir, "laws/laws.yaml"), "laws"),
         {:ok, detect} <- read_detect(Path.join(dir, "detect/signatures.yaml")),
         {:ok, playbooks} <- read_list(Path.join(dir, "investigate/playbooks.yaml"), "playbooks"),
         {:ok, eval} <- read_optional_yaml(Path.join(dir, "eval/eval.yaml")),
         {:ok, templates} <- read_templates(Path.join(dir, "templates")),
         adapter <- build(dir, manifest, detect, laws, playbooks, eval, templates),
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
    |> validate_entries(a.fingerprint_rules, "fingerprint", &fingerprint_problems/1)
    |> validate_entries(a.opportunity_rules, "opportunity", &opportunity_problems/1)
    |> check(
      is_list(a.skill_namespaces) and Enum.all?(a.skill_namespaces, &is_binary/1),
      "skill_namespaces must be a list of strings"
    )
    |> check(
      Enum.all?(a.skill_namespaces, &regex_safe?/1),
      "skill_namespaces must each compile to a valid regex (no invalid UTF-8 / NUL)"
    )
    |> check(
      Enum.all?(a.file_globs, &glob_compiles?/1),
      "file_globs must each compile to a valid glob pattern"
    )
    |> validate_entries(a.playbooks, "playbook", &playbook_problems/1)
    |> unique_ids(a.laws, "law")
    |> unique_ids(a.signatures, "signature")
    |> unique_ids(a.playbooks, "playbook")
    |> Enum.reverse()
  end

  # ── stack matching (gating) ────────────────────────────────────────────────

  @doc """
  Does this adapter's stack apply to a session that touched `paths`?

  The manifest's `file_globs` declare which files mark a project as "this stack" (`mix.exs`,
  `**/*.{ex,exs}`, …); a session matches when any path it referenced (edited/read/patched) matches
  any glob. This is how Faber refuses to draft, say, an Elixir skill for a Next.js Codex session.

  Matching is **filesystem-independent** — it runs against the paths the session itself referenced,
  not the project on disk — so it works cross-machine and for sessions whose project has moved. A
  glob matches a path suffix (`lib/**/*.ex` matches `/Users/x/app/lib/a/b.ex`).
  """
  @spec matches_session?(t(), [String.t()]) :: boolean()
  def matches_session?(%Adapter{file_globs: globs}, paths) when is_list(paths) do
    regexes = Enum.map(globs, &glob_regex/1)
    Enum.any?(paths, fn p -> is_binary(p) and Enum.any?(regexes, &Regex.match?(&1, p)) end)
  end

  @doc """
  Translate an adapter `file_glob` into a `Regex` that matches a path **suffix** (anchored at a
  path boundary). Supports `**` (any dirs), `*`/`?` (within a segment), and `{a,b}` alternation.
  Exposed for testing.
  """
  @spec glob_regex(String.t()) :: Regex.t()
  def glob_regex(glob) do
    body =
      glob
      |> String.split(~r"(\*\*/|\*\*|\*|\?|\{[^}]*\})", include_captures: true, trim: true)
      |> Enum.map_join(&glob_token/1)

    Regex.compile!("(^|/)" <> body <> "$")
  end

  defp glob_token("**/"), do: "(?:.*/)?"
  defp glob_token("**"), do: ".*"
  defp glob_token("*"), do: "[^/]*"
  defp glob_token("?"), do: "[^/]"

  defp glob_token("{" <> _ = brace) do
    alts =
      brace |> String.slice(1..-2//1) |> String.split(",") |> Enum.map_join("|", &Regex.escape/1)

    "(?:" <> alts <> ")"
  end

  defp glob_token(literal), do: Regex.escape(literal)

  # ── building ──────────────────────────────────────────────────────────────

  defp build(dir, manifest, detect, laws, playbooks, eval, templates) do
    %Adapter{
      name: manifest["name"],
      version: manifest["version"],
      agent_targets: manifest["agent_targets"] || [],
      file_globs: manifest["file_globs"] || [],
      contract: manifest["contract"],
      metadata: manifest["metadata"] || %{},
      laws: Enum.map(laws, &law/1),
      signatures: Enum.map(detect.signatures, &signature/1),
      fingerprint_rules: Enum.map(detect.fingerprints, &fingerprint_rule/1),
      opportunity_rules: Enum.map(detect.opportunities, &opportunity_rule/1),
      skill_namespaces: detect.skill_namespaces,
      playbooks: Enum.map(playbooks, &playbook/1),
      eval: eval,
      templates: templates,
      dir: dir
    }
  end

  # Load the `templates/` scaffolds keyed by the artifact type they `produces` (e.g. "skill").
  # Reads `templates/manifest.yaml`, then the body of each named file. Absent dir/manifest → %{}.
  # A manifest entry whose file is missing is skipped (not fatal — validation can flag it later).
  defp read_templates(dir) do
    with {:ok, entries} <- read_list(Path.join(dir, "manifest.yaml"), "templates") do
      templates =
        for %{"file" => file, "produces" => produces} <- entries,
            {:ok, safe} <- [safe_template_path(file, dir)],
            {:ok, body} <- [File.read(Path.join(dir, safe))],
            into: %{},
            do: {produces, body}

      {:ok, templates}
    end
  end

  # The pack is untrusted input: a manifest `file` must stay inside `templates/` — reject
  # absolute paths and `..` traversal, or a malicious pack could slurp any readable file
  # (e.g. a private key) into a template body that gets rendered into a generated skill.
  defp safe_template_path(file, dir) when is_binary(file) do
    case Path.safe_relative(file) do
      {:ok, safe} ->
        {:ok, safe}

      :error ->
        Logger.warning(
          "adapter #{Path.basename(Path.dirname(dir))}: template file #{inspect(file)} " <>
            "escapes templates/ — rejected"
        )

        :error
    end
  end

  defp safe_template_path(file, dir) do
    Logger.warning(
      "adapter #{Path.basename(Path.dirname(dir))}: template file #{inspect(file)} " <>
        "is not a path — rejected"
    )

    :error
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

  # A fingerprint command-bonus rule (contract §4.1): when any `commands` substring appears in
  # the session's Bash calls, add `bonus` to `type`'s fingerprint score.
  defp fingerprint_rule(m) when is_map(m) do
    %{type: m["type"], commands: m["commands"] || [], bonus: m["bonus"]}
  end

  # An opportunity→skill rule (contract §4.1). `when` is mapped to a closed set of atoms the
  # engine dispatches on; anything else stays a string so validation can flag it.
  defp opportunity_rule(m) when is_map(m) do
    %{
      skill: m["skill"],
      when: atomize_when(m["when"]),
      commands: m["commands"] || [],
      threshold: m["threshold"],
      unless_used: Map.get(m, "unless_used", true)
    }
  end

  defp atomize_when("retry_loops"), do: :retry_loops
  defp atomize_when("tool_count"), do: :tool_count
  defp atomize_when("edit_count"), do: :edit_count
  defp atomize_when("commands"), do: :commands
  defp atomize_when(other), do: other

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

  defp fingerprint_problems(%{type: type, bonus: bonus}) do
    []
    |> req(type, "fingerprint rule missing type")
    |> check(is_number(bonus), "fingerprint rule #{type || "?"} bonus must be a number")
  end

  @opportunity_whens [:retry_loops, :tool_count, :edit_count, :commands]

  defp opportunity_problems(%{skill: skill, when: w} = rule) do
    []
    |> req(skill, "opportunity rule missing skill")
    |> check(
      w in @opportunity_whens,
      "opportunity rule #{skill || "?"} 'when' must be one of #{inspect(@opportunity_whens)}"
    )
    |> check(
      w not in [:tool_count, :edit_count, :commands] or is_integer(rule[:threshold]),
      "opportunity rule #{skill || "?"} requires an integer threshold for when: #{inspect(w)}"
    )
    |> check(
      w != :commands or (is_list(rule[:commands]) and rule[:commands] != []),
      "opportunity rule #{skill || "?"} with when: commands requires a non-empty commands list"
    )
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

  # A skill-namespace string is safe iff it survives Regex.escape + compile — catches NUL /
  # invalid UTF-8 that would otherwise make `Detect.skill_namespace_regex/1` raise mid-scan. Per
  # namespace is sufficient: the engine joins escaped namespaces with literal `|`, so if each
  # compiles, the joined pattern compiles too.
  defp regex_safe?(ns) when is_binary(ns), do: match?({:ok, _}, Regex.compile(Regex.escape(ns)))
  defp regex_safe?(_), do: false

  # A file_glob is valid iff `glob_regex/1` compiles it. Wrapped so a malformed glob is a
  # validation error at load, not a raise later in `matches_session?/2`.
  defp glob_compiles?(glob) when is_binary(glob) do
    glob_regex(glob)
    true
  rescue
    _ -> false
  end

  defp glob_compiles?(_), do: false

  # ── YAML readers ──────────────────────────────────────────────────────────

  defp read_yaml(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, other} -> {:error, {:not_a_mapping, path, other}}
      {:error, reason} -> {:error, {:yaml_error, path, reason}}
    end
  end

  # Absent file → `{:ok, nil}` (engine defaults apply). Present-but-malformed → propagate the
  # `{:error, ...}` so `load/1` rejects the pack at the boundary rather than silently ignoring a
  # broken optional file (fail-closed: a malformed stricter eval must not downgrade to defaults).
  defp read_optional_yaml(path) do
    if File.exists?(path), do: read_yaml(path), else: {:ok, nil}
  end

  # Bulk list file (laws.yaml / playbooks.yaml / templates manifest.yaml). Absent → `{:ok, []}`.
  # Returns the top-level list under `key`, or `{:ok, []}` if the key is missing; a malformed file
  # propagates its `{:error, ...}`.
  defp read_list(path, key) do
    with {:ok, yaml} <- read_optional_yaml(path) do
      case yaml do
        %{^key => list} when is_list(list) -> {:ok, list}
        _ -> {:ok, []}
      end
    end
  end

  # `detect/signatures.yaml` carries several sibling top-level keys (contract §4: `signatures`;
  # §4.1: `fingerprints`, `opportunities`, `skill_namespaces`). Read the file once and project
  # each. Absent file → all empty (engine-default behavior, see `Faber.Detect`); malformed file
  # propagates its `{:error, ...}`.
  defp read_detect(path) do
    with {:ok, yaml0} <- read_optional_yaml(path) do
      yaml = yaml0 || %{}

      {:ok,
       %{
         signatures: list_under(yaml, "signatures"),
         fingerprints: list_under(yaml, "fingerprints"),
         opportunities: list_under(yaml, "opportunities"),
         skill_namespaces: list_under(yaml, "skill_namespaces")
       }}
    end
  end

  defp list_under(map, key) do
    case Map.get(map, key) do
      list when is_list(list) -> list
      _ -> []
    end
  end
end
