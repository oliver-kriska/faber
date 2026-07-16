defmodule Faber.Eval.Matchers do
  @moduledoc """
  Native Elixir port of the eval matchers (mirrors `python/faber_eval/matchers.py`).

  Each matcher is `(content, params) -> {pass?, evidence}` — pure, no I/O. Having these in Elixir
  lets the common structural-eval path run in-process (`Faber.Eval.Native`) with no `python3`
  process spawn; the Python sidecar remains for parity and as the future home for GEPA / trigger
  accuracy. Thresholds and patterns match the Python defaults so the two engines agree.
  """

  @vague_default ~w(general various etc sometimes might possibly)

  @dangerous_default [
    ~r/rm\s+-rf\s+\//,
    ~r/sudo\s+rm\b/,
    ~r/curl\s+[^|\n]*\|\s*(?:sudo\s+)?(?:ba)?sh/,
    ~r/:\(\)\s*\{/
  ]

  @safe_section_hints ["iron law", "anti-pattern", "red flag", "detection", "checklist", "gotcha"]

  @imperative ~r/^\s*(?:Run|Add|Create|Check|Read|Use|Set|Write|Install|Configure|Verify|Ensure|Avoid|Prefer|Call|Make|Define|Update|Remove|Replace|Apply|Pass|Return|Build|Test|Fix|Trace|Inspect|Confirm|Mark|Stage|Commit|Render|Parse|Score|Propose|Gate|Keep|Revert|Stop|Load|Skip|Move|Spawn|Group|Rank|Detect|Compute|Scan|Mine|Wire|Open|Close|Start|Find|List)\b/

  @concrete [
    ~r/`[^`]+`/,
    ~r/^\s*\|/,
    ~r/\w+\.\w+\.\w+/,
    ~r/\/\w+[\/\w]*\.\w+/,
    ~r/--\w+/,
    ~r/^\s*-\s*\[\s*\]/
  ]

  # ── frontmatter / sections ─────────────────────────────────────────────────

  @doc "Split a `---` frontmatter block from the body. `{fm_map, body}` (`{%{}, content}` if none)."
  @spec split_frontmatter(String.t()) :: {map(), String.t()}
  def split_frontmatter(content) do
    {fm, body} = split_raw(content)
    {fm |> String.split("\n") |> parse_fields(), body}
  end

  # The unparsed split: `{frontmatter_text, body}`, or `{"", content}` when there is no frontmatter.
  # Split out from `split_frontmatter/1` (whose contract is unchanged) because the safety scan needs
  # the RAW frontmatter text: `parse_fields/1` keeps only the `key: value` lines it understands and
  # silently drops everything else — block scalars, list items, continuations. Handing a safety check
  # a map built by a lossy parser rebuilds the empty-haystack vacuous pass one layer up: the payload
  # simply isn't in the map to be found. Every other matcher wants the parsed fields and calls
  # `split_frontmatter/1`.
  defp split_raw(content) do
    lines = String.split(content, "\n")

    with ["---" | rest] <- lines,
         idx when is_integer(idx) <- Enum.find_index(rest, &(String.trim(&1) == "---")) do
      body = rest |> Enum.drop(idx + 1) |> Enum.join("\n") |> String.replace(~r/\A\n+/, "")
      {rest |> Enum.take(idx) |> Enum.join("\n"), body}
    else
      _ -> {"", content}
    end
  end

  defp parse_fields(lines) do
    Enum.reduce(lines, %{}, fn line, acc ->
      case Regex.run(~r/^([A-Za-z0-9_-]+):\s*(.*)$/, line) do
        [_, key, val] -> Map.put(acc, key, unquote_val(String.trim(val)))
        _ -> acc
      end
    end)
  end

  defp unquote_val(<<q, _::binary>> = v) when q in [?", ?'] do
    if String.length(v) >= 2 and String.last(v) == <<q>>, do: String.slice(v, 1..-2//1), else: v
  end

  defp unquote_val(v), do: v

  @doc "Return `[{heading, body_lines}, ...]` for `##`/`###` sections of `body`."
  @spec sections(String.t()) :: [{String.t(), [String.t()]}]
  def sections(body) do
    body |> regions() |> Enum.reject(fn {name, _} -> is_nil(name) end)
  end

  # Every line of `body`, grouped as `{heading_or_nil, lines}` — including the **pre-heading**
  # region (`nil`), which `sections/1` drops. Anything that must not miss content has to walk this,
  # not `sections/1`: the region between the H1 and the first `##` is where a skill's opening prose
  # goes (the renderer emits `# Title` right before `## Usage`), and a body with no headings at all
  # — a hook script — is *entirely* pre-heading, i.e. entirely invisible to `sections/1`.
  @spec regions(String.t()) :: [{String.t() | nil, [String.t()]}]
  defp regions(body) do
    body
    |> String.split("\n")
    |> Enum.reduce({nil, [], []}, fn line, {cur, buf, acc} ->
      case Regex.run(~r/^\#\#+\s+(.*)$/, line) do
        [_, name] -> {String.trim(name), [], push(acc, cur, buf)}
        _ -> {cur, [line | buf], acc}
      end
    end)
    |> close()
  end

  # A pre-heading region of pure whitespace is not a region (a body that opens on a heading).
  defp push(acc, nil, buf) do
    if Enum.any?(buf, &(String.trim(&1) != "")),
      do: [{nil, Enum.reverse(buf)} | acc],
      else: acc
  end

  defp push(acc, cur, buf), do: [{cur, Enum.reverse(buf)} | acc]
  defp close({cur, buf, acc}), do: Enum.reverse(push(acc, cur, buf))

  # ── structure ──────────────────────────────────────────────────────────────

  def section_exists(content, params) do
    section = params[:section]
    {_, body} = split_frontmatter(content)
    names = Enum.map(sections(body), &elem(&1, 0))

    if Enum.any?(names, &String.contains?(String.downcase(&1), String.downcase(section))) do
      {true, "Section '#{section}' found"}
    else
      {false, "Section '#{section}' missing. Available: #{inspect(names)}"}
    end
  end

  def max_section_lines(content, params) do
    max = params[:max] || 40
    {_, body} = split_frontmatter(content)

    over =
      for {name, lines} <- sections(body),
          n = Enum.count(lines, &(String.trim(&1) != "")),
          n > max,
          do: {name, n}

    if over == [],
      do: {true, "All sections <= #{max} lines"},
      else: {false, "Over #{max}: #{inspect(over)}"}
  end

  def line_count(content, params) do
    target = params[:target] || 100
    tolerance = params[:tolerance] || 85
    {_, body} = split_frontmatter(content)
    n = length(String.split(body, "\n"))

    cond do
      n <= target -> {true, "#{n} lines (<= target #{target})"}
      n <= target + tolerance -> {true, "#{n} lines (within tolerance)"}
      true -> {false, "#{n} lines (over #{target + tolerance})"}
    end
  end

  def token_estimate(content, params) do
    max = params[:max_tokens] || 2000
    {_, body} = split_frontmatter(content)
    tokens = round(length(String.split(body, ~r/\s+/, trim: true)) / 0.75)

    if tokens <= max,
      do: {true, "~#{tokens} tokens"},
      else: {false, "~#{tokens} tokens (over #{max})"}
  end

  # ── frontmatter fields ───────────────────────────────────────────────────────

  def frontmatter_field(content, params) do
    field = to_string(params[:field])
    {fm, _} = split_frontmatter(content)

    cond do
      not Map.has_key?(fm, field) ->
        {false, "frontmatter missing '#{field}'"}

      params[:expected] && to_string(fm[field]) != to_string(params[:expected]) ->
        {false, "#{field}=#{inspect(fm[field])}"}

      true ->
        {true, "#{field} present"}
    end
  end

  def description_length(content, params) do
    min = params[:min] || 50
    max = params[:max] || 250
    {fm, _} = split_frontmatter(content)
    n = String.length(Map.get(fm, "description", ""))

    if min <= n and n <= max,
      do: {true, "description #{n} chars"},
      else: {false, "description #{n} chars (want #{min}-#{max})"}
  end

  # Generic by default: with no keyword list this is a neutral pass — an adapter supplies its
  # stack's domain keywords through eval params (mirrors `matchers.py description_keywords`).
  def description_keywords(content, params) do
    case params[:keywords] do
      keywords when is_list(keywords) and keywords != [] ->
        min = params[:min] || 3
        {fm, _} = split_frontmatter(content)
        desc = fm |> Map.get("description", "") |> String.downcase()

        hits =
          Enum.filter(keywords, fn k ->
            is_binary(k) and String.contains?(desc, String.downcase(k))
          end)

        if length(hits) >= min,
          do: {true, "#{length(hits)} domain keywords: #{inspect(hits)}"},
          else: {false, "only #{length(hits)} domain keywords (want >= #{min})"}

      _ ->
        {true, "no keyword list configured (skipped)"}
    end
  end

  def description_no_vague(content, params) do
    forbidden = params[:forbidden] || @vague_default
    {fm, _} = split_frontmatter(content)
    desc = fm |> Map.get("description", "") |> String.downcase()
    found = Enum.filter(forbidden, &Regex.match?(~r/\b#{Regex.escape(&1)}\b/, desc))
    if found == [], do: {true, "no vague words"}, else: {false, "vague words: #{inspect(found)}"}
  end

  def description_structure(content, _params) do
    {fm, _} = split_frontmatter(content)
    desc = Map.get(fm, "description", "")
    # "What" = starts with a capitalized word of ≥2 chars. `[\w+-]` (not `[a-z]`) so real stack
    # vocabulary passes — "GenServer…", "LiveView…", "OTP…", "N+1…" — while a bare "A " still
    # fails. Keep in lockstep with python/faber_eval/matchers.py (parity test pins both).
    has_what = Regex.match?(~r/^[A-Z][\w+-]+\s/, desc)
    has_when = Regex.match?(~r/\b[Uu]se\s+(?:when|after|for|to)\b/, desc)

    if has_what and has_when,
      do: {true, "has what + when"},
      else: {false, "what=#{has_what} when=#{has_when}"}
  end

  # ── content search ────────────────────────────────────────────────────────────

  # `pattern` comes from an untrusted adapter pack — compile non-bang and fail closed to a failed
  # check on a bad regex, never raise. (The Python side has no such guard and would crash the
  # sidecar; on valid patterns the two agree.)
  def content_present(content, params) do
    with {:ok, re} <- compile_pattern(params[:pattern]) do
      if Regex.match?(re, content),
        do: {true, "pattern present: #{params[:pattern]}"},
        else: {false, "pattern absent: #{params[:pattern]}"}
    end
  end

  def content_absent(content, params) do
    with {:ok, re} <- compile_pattern(params[:pattern]) do
      case Regex.run(re, content) do
        nil -> {true, "pattern absent: #{params[:pattern]}"}
        [match | _] -> {false, "forbidden pattern present: #{inspect(match)}"}
      end
    end
  end

  defp compile_pattern(pattern) when is_binary(pattern) do
    case Regex.compile(pattern) do
      {:ok, re} -> {:ok, re}
      {:error, _} -> {false, "invalid pattern: #{inspect(pattern)}"}
    end
  end

  defp compile_pattern(other), do: {false, "invalid pattern: #{inspect(other)}"}

  # ── safety ───────────────────────────────────────────────────────────────────

  def has_iron_laws(content, params) do
    min = params[:min_count] || 1
    {_, body} = split_frontmatter(content)

    candidates =
      Enum.filter(sections(body), fn {n, _} ->
        String.contains?(String.downcase(n), "iron law")
      end)

    case candidates do
      [] ->
        {false, "no Iron Laws section"}

      _ ->
        items = candidates |> Enum.map(fn {_, lines} -> count_items(lines) end) |> Enum.max()

        if items >= min,
          do: {true, "#{items} Iron Laws"},
          else: {false, "only #{items} Iron Laws (want #{min})"}
    end
  end

  defp count_items(lines),
    do: Enum.count(lines, &Regex.match?(~r/^\s*(?:\d+[\.\)]\s+|[-*]\s+)/, &1))

  def no_dangerous_patterns(content, params) do
    # NOT `params[:patterns] || @dangerous_default`: `[]` is **truthy in Elixir**, so an empty list
    # survived the `||` and became an empty regex set — `Enum.find([], …)` is `nil`, i.e. `{true,
    # "no dangerous patterns"}` on an artifact containing `rm -rf /`. The assertion was present AND
    # passing, so it read as a clean safety score rather than a skipped check. That is the same
    # vacuous-pass class as the empty-haystack bug this function was just fixed for, one config key
    # away, and reachable from an untrusted pack's `eval.yaml`.
    #
    # It was also a silent **native↔sidecar divergence**: Python's `patterns or _DANGEROUS_DEFAULT`
    # falls back correctly because `[]` is *falsy* there. Restoring the fallback restores parity.
    #
    # An empty pattern list can never mean "nothing is dangerous here" — for a safety check the only
    # safe reading of "no patterns configured" is "use the engine's".
    patterns =
      case params[:patterns] do
        list when is_list(list) and list != [] -> list
        _ -> @dangerous_default
      end

    # The frontmatter is scanned too, and this is not a detail: it used to be dropped outright
    # (`split_frontmatter/1` returns only the body), so `description: … rm -rf / …` was invisible
    # here. Reproduced before fixing — a well-formed skill scored **composite 1.0, passed, vetoed:
    # []**, byte-identical in score to the same skill with a benign description, and installed. The
    # payload cost the attacker exactly nothing, in the one field an agent reliably loads into
    # context to decide whether to run the skill at all.
    {fm, body} = split_raw(content)

    # Two haystacks because the exemptions differ; both are searched. The frontmatter is taken raw
    # and whole — no safe-section exemption (it has no headings, so it can announce nothing) and no
    # table filter (a leading `|` there is a YAML block scalar, not a table row).
    #
    # `regions/1`, not `sections/1`: this is the gate deciding what gets written into the user's
    # `~/.claude/skills`, so it must search the *whole* body. Searching `sections/1` let a valid
    # SKILL.md carrying `rm -rf /` between its H1 and first `##` score a clean pass, and made any
    # heading-less body (a hook script) a vacuous pass against an empty haystack.
    body_haystack =
      body
      |> regions()
      |> Enum.reject(fn {name, _} -> safe_section?(name) end)
      |> Enum.flat_map(fn {_, lines} ->
        Enum.reject(lines, &String.starts_with?(String.trim(&1), "|"))
      end)
      |> Enum.join("\n")

    haystack = fm <> "\n" <> body_haystack

    # `patterns` may come from an untrusted adapter pack as YAML strings (not compiled `%Regex{}`),
    # so normalize each fail-closed: a bad regex is a failed safety check, never a raise mid-scan.
    with {:ok, regexes} <- compile_patterns(patterns) do
      case Enum.find(regexes, &Regex.match?(&1, haystack)) do
        nil -> {true, "no dangerous patterns"}
        pat -> {false, "dangerous pattern: #{inspect(Regex.source(pat))}"}
      end
    end
  end

  # `@safe_section_hints` exempts a section that *announces* it documents dangerous patterns — a
  # skill listing `rm -rf /` under "Anti-patterns" is doing its job. Unheaded prose announces
  # nothing, so the pre-heading region is never exempt.
  defp safe_section?(nil), do: false

  defp safe_section?(name) do
    downcased = String.downcase(name)
    Enum.any?(@safe_section_hints, &String.contains?(downcased, &1))
  end

  # Accepts a mix of compiled `%Regex{}` (e.g. `@dangerous_default`) and strings from a pack's
  # YAML. Short-circuits to a failed check on the first uncompilable pattern.
  defp compile_patterns(patterns) do
    Enum.reduce_while(patterns, {:ok, []}, fn pat, {:ok, acc} ->
      case normalize_pattern(pat) do
        {:ok, re} -> {:cont, {:ok, [re | acc]}}
        {false, _} = failed -> {:halt, failed}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      failed -> failed
    end
  end

  defp normalize_pattern(%Regex{} = re), do: {:ok, re}
  defp normalize_pattern(pat) when is_binary(pat), do: compile_pattern(pat)
  defp normalize_pattern(other), do: {false, "invalid pattern: #{inspect(other)}"}

  # ── clarity / specificity ─────────────────────────────────────────────────────

  def has_examples(content, params) do
    min_blocks = params[:min_blocks] || 1
    min_lines = params[:min_lines] || 2
    {_, body} = split_frontmatter(content)

    good =
      Regex.scan(~r/```[\w]*\n(.*?)```/s, body)
      |> Enum.map(fn [_, inner] ->
        Enum.count(String.split(inner, "\n"), &(String.trim(&1) != ""))
      end)
      |> Enum.count(&(&1 >= min_lines))

    if good >= min_blocks,
      do: {true, "#{good} example blocks"},
      else: {false, "only #{good} example blocks"}
  end

  def action_density(content, params) do
    min_ratio = params[:min_ratio] || 0.25
    {_, body} = split_frontmatter(content)

    lines =
      body
      |> String.split("\n")
      |> Enum.filter(fn l ->
        t = String.trim(l)
        t != "" and not String.starts_with?(t, "#") and not String.starts_with?(t, "```")
      end)

    case lines do
      [] ->
        {false, "no content lines"}

      _ ->
        actionable = Enum.count(lines, &actionable?/1)
        ratio = actionable / length(lines)

        if ratio >= min_ratio,
          do: {true, "action density #{fmt(ratio)}"},
          else: {false, "action density #{fmt(ratio)} (want #{min_ratio})"}
    end
  end

  defp actionable?(line) do
    Regex.match?(@imperative, line) or
      Regex.match?(~r/^\s*\d+[\.\)]\s+/, line) or
      Regex.match?(~r/^\s*[-*]\s+\*\*/, line) or
      (String.starts_with?(String.trim(line), "|") and length(String.split(line, "|")) >= 3)
  end

  def specificity_ratio(content, params) do
    min_ratio = params[:min_ratio] || 0.15
    {_, body} = split_frontmatter(content)
    lines = body |> String.split("\n") |> Enum.filter(&(String.trim(&1) != ""))

    case lines do
      [] ->
        {false, "no content"}

      _ ->
        concrete = Enum.count(lines, fn l -> Enum.any?(@concrete, &Regex.match?(&1, l)) end)
        ratio = concrete / length(lines)

        if ratio >= min_ratio,
          do: {true, "specificity #{fmt(ratio)}"},
          else: {false, "specificity #{fmt(ratio)} (want #{min_ratio})"}
    end
  end

  # ── accuracy (cross-reference resolution) ─────────────────────────────────────
  #
  # The plugin's accuracy matchers list the filesystem (os.listdir/isfile) to resolve refs. To keep
  # these matchers PURE (the module's contract) and the native↔sidecar parity exact, Faber instead
  # validates refs against caller-supplied *known-sets* — plain lists threaded in via `params`. The
  # filesystem walk happens once at the boundary (`Faber.Eval`, from the adapter/install tree) and
  # the resolved names flow in as data. Without a known-set the check neutral-passes (it cannot
  # validate, and must never block the gate for missing context) — mirroring the reference's own
  # "cannot locate plugin root — skipping" behavior.

  @builtin_agents ~w(general-purpose Explore Plan code-simplifier)

  @doc "Own-skill `references/<file>` paths resolve against `:known_files` (basenames)."
  def valid_file_refs(content, params) do
    # Cross-skill refs (`other-skill/references/x.md`) are someone else's to validate — exclude them.
    cross =
      ~r{([\w-]+)/references/([\w.-]+\.md)}
      |> Regex.scan(content)
      |> Enum.reject(fn [_, prefix, _] -> prefix in ["CLAUDE_SKILL_DIR}", "CLAUDE_SKILL_DIR"] end)
      |> Enum.map(fn [_, _, file] -> file end)
      |> MapSet.new()

    refs =
      ~r{(?:CLAUDE_SKILL_DIR\}?/)?references/([\w.-]+\.md)}
      |> Regex.scan(content)
      |> Enum.map(fn [_, file] -> file end)
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(cross, &1))

    validate_refs(refs, params[:known_files], "reference file", &Path.basename/1)
  end

  @doc "Skill refs (`/ns:name`, `[[name]]`, `` `name` skill``) resolve against `:known_skills`."
  def valid_skill_refs(content, params) do
    refs =
      regex_names(~r{(?<!/)/\w[\w-]*:(\w[\w-]*)}, content) ++
        regex_names(~r{\[\[([\w-]+)\]\]}, content) ++
        regex_names(~r{`([\w-]+)`\s+skill}, content)

    validate_refs(Enum.uniq(refs), params[:known_skills], "skill", & &1)
  end

  @doc "Agent refs (`subagent_type:`, `` `name-role` ``) resolve against `:known_agents` + built-ins."
  def valid_agent_refs(content, params) do
    builtin = params[:builtin_agents] || @builtin_agents

    refs =
      regex_names(~r{subagent_type[=:]\s*["']?([\w-]+)}, content) ++
        regex_names(
          ~r{`([\w-]+-(?:reviewer|analyzer|architect|validator|runner|specialist|advisor|judge|supervisor|orchestrator|researcher|tracer))`},
          content
        )

    refs = refs |> Enum.uniq() |> Enum.reject(&(&1 in builtin))
    validate_refs(refs, params[:known_agents], "agent", & &1)
  end

  defp regex_names(re, content), do: re |> Regex.scan(content) |> Enum.map(&List.last/1)

  # nil known-set → neutral pass (cannot validate); empty refs → pass; else membership check.
  defp validate_refs(_refs, nil, label, _norm),
    do: {true, "no #{label} index supplied — skipping"}

  defp validate_refs([], _known, label, _norm), do: {true, "no #{label} references found"}

  defp validate_refs(refs, known, label, norm) do
    known_set = MapSet.new(known, norm)
    missing = Enum.reject(refs, &MapSet.member?(known_set, &1))

    if missing == [],
      do: {true, "all #{length(refs)} #{label} references valid"},
      else: {false, "missing #{label}s: #{inspect(Enum.sort(missing))}"}
  end

  @doc "Dispatch a check by type. Unknown types fail (caught by the scorer)."
  @spec run_check(atom() | String.t(), String.t(), map()) :: {boolean(), String.t()}
  # A flat name → matcher dispatch table, not branching logic: every clause is a single call and
  # the count only grows when a new matcher is added. Cyclomatic complexity scores it 21, but the
  # alternative (a %{} of captures) trades a greppable, arity-checked table for an opaque map.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def run_check(type, content, params) do
    case to_string(type) do
      "section_exists" -> section_exists(content, params)
      "max_section_lines" -> max_section_lines(content, params)
      "line_count" -> line_count(content, params)
      "token_estimate" -> token_estimate(content, params)
      "frontmatter_field" -> frontmatter_field(content, params)
      "description_length" -> description_length(content, params)
      "description_keywords" -> description_keywords(content, params)
      "description_no_vague" -> description_no_vague(content, params)
      "description_structure" -> description_structure(content, params)
      "content_present" -> content_present(content, params)
      "content_absent" -> content_absent(content, params)
      "has_iron_laws" -> has_iron_laws(content, params)
      "no_dangerous_patterns" -> no_dangerous_patterns(content, params)
      "has_examples" -> has_examples(content, params)
      "action_density" -> action_density(content, params)
      "specificity_ratio" -> specificity_ratio(content, params)
      "valid_file_refs" -> valid_file_refs(content, params)
      "valid_skill_refs" -> valid_skill_refs(content, params)
      "valid_agent_refs" -> valid_agent_refs(content, params)
      other -> {false, "unknown check_type: #{other}"}
    end
  end

  defp fmt(r), do: :erlang.float_to_binary(r * 1.0, decimals: 2)
end
