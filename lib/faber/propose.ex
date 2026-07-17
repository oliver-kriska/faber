defmodule Faber.Propose do
  @moduledoc """
  **Stage 3 — Skill proposer.** Turn a friction finding into a proposed skill, LLM-written and
  adapter-informed.

  The engine stays domain-free: everything stack-specific (the Iron Laws, investigation
  playbooks, idioms) comes from the `Faber.Adapter` and is woven into the prompt. The LLM call
  goes through the `Faber.LLM` behaviour, so this whole stage runs deterministically in tests
  (via `Faber.LLM.Stub`) with no key or network.

  Pipeline position: `Faber.Scan` ranks sessions → `propose/3` drafts a skill for a high-friction
  one → `Faber.Eval` gates it → `Faber.Loop` optionally refines it.

  ## Output shape

  `propose/3` returns `{:ok, %Faber.Proposal{}}`. `render_skill_md/1` renders that proposal into a
  `SKILL.md` string that satisfies the plugin's skill conventions (frontmatter with `name` +
  `description`, an `## Iron Laws` section with ≥3 entries, `## Usage`, a fenced example, and a
  `## References` pointer). Those conventions are what `Faber.Eval`'s structural matchers check.
  """

  alias Faber.{Adapter, LLM, Proposal, Scan, Template}

  # ReqLLM/NimbleOptions-style schema for the structured proposal the LLM must return.
  @schema [
    name: [type: :string, required: true],
    description: [type: :string, required: true],
    effort: [type: :string],
    rationale: [type: :string, required: true],
    iron_laws: [type: {:list, :string}, required: true],
    usage: [type: :string],
    example: [type: :string],
    workflow: [type: {:list, :string}],
    patterns: [type: {:list, :string}],
    should_trigger: [type: {:list, :string}],
    should_not_trigger: [type: {:list, :string}]
  ]

  # A hook is a different artifact, so it gets a different schema rather than a skill schema with
  # most fields left blank: asking for `iron_laws` on a shell script is how you get an LLM to invent
  # three. What a hook is: where it fires (`event` + `matcher`), what runs (`script`), and why.
  @hook_schema [
    name: [type: :string, required: true],
    description: [type: :string, required: true],
    rationale: [type: :string, required: true],
    event: [type: :string, required: true],
    matcher: [type: :string, required: true],
    script: [type: :string, required: true]
  ]

  @doc "The structured-output schema the proposer asks the LLM to fill for a skill."
  @spec schema() :: keyword()
  def schema, do: @schema

  @doc """
  The structured-output schema for a `kind: :hook` proposal.

  See `schema/0` for the skill shape. The two are disjoint by design — see `@hook_schema`'s
  reasoning and `Faber.Proposal`'s "the two kinds populate disjoint halves".
  """
  @spec hook_schema() :: keyword()
  def hook_schema, do: @hook_schema

  @doc """
  Propose a skill for a ranked session `result` under `adapter`.

  Options are forwarded to `Faber.LLM.generate_object/3` (e.g. `:llm` to override the
  implementation, `:model`, `:stub_response`). Returns `{:ok, %Faber.Proposal{}}` or
  `{:error, term()}` if the LLM call fails.

  `:feedback` (a string) turns this into a **reflective** re-proposal: it is appended to the user
  prompt so the LLM derives an improved draft from the current one and its eval weaknesses, rather
  than regenerating blind. `Faber.Loop`'s `:reflect` strategy supplies it (see `Faber.Optimize`).
  """
  @spec propose(Scan.Result.t(), Adapter.t(), keyword()) ::
          {:ok, Proposal.t()} | {:error, term()}
  def propose(%Scan.Result{} = result, %Adapter{} = adapter, opts \\ []) do
    {system, user} = build_prompt(result, adapter)
    user = augment_with_feedback(user, opts[:feedback])
    opts = Keyword.put(opts, :system_prompt, system)

    case LLM.generate_object(user, @schema, opts) do
      {:ok, object} -> {:ok, build_proposal(object, result, adapter)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Propose a **hook** for a `hazard` (a `Faber.Detect.Hazard.summary/0`) found in `result`, under
  `adapter`.

  The counterpart to `propose/3`, and the reason `Faber.Detect.Hazard` exists: a hazard is a
  frictionless danger, so no friction finding would ever have selected this session. The hazard
  carries its own evidence and the `event`/`matcher` pointer it implies, and those seed the prompt —
  the model is asked to write the interception, not to rediscover the problem.

  Same options as `propose/3` (forwarded to `Faber.LLM.generate_object/3`), including `:feedback`
  for reflective re-proposal. Returns `{:ok, %Faber.Proposal{kind: :hook}}` or `{:error, term()}`.
  """
  @spec propose_hook(Scan.Result.t(), map(), Adapter.t(), keyword()) ::
          {:ok, Proposal.t()} | {:error, term()}
  def propose_hook(%Scan.Result{} = result, hazard, %Adapter{} = adapter, opts \\ []) do
    user =
      result
      |> hook_user_prompt(hazard, adapter)
      |> augment_with_feedback(opts[:feedback])

    opts = Keyword.put(opts, :system_prompt, hook_system_prompt(adapter))

    case LLM.generate_object(user, @hook_schema, opts) do
      {:ok, object} -> {:ok, build_hook_proposal(object, result, hazard, adapter)}
      {:error, _} = err -> err
    end
  end

  # The events a hook may declare. Not open-ended: a typo'd event is a hook that silently never
  # fires, which is the same fail-quietly shape as everything else this plan closed. The eval
  # asserts membership too (`Faber.Eval.Native`'s hook set) — this just tells the model the truth.
  @hook_events ~w(PreToolUse PostToolUse SessionStart Stop)

  @doc "The Claude Code hook events Faber will propose and install. See `Faber.Install.Hook`."
  @spec hook_events() :: [String.t()]
  def hook_events, do: @hook_events

  defp hook_system_prompt(%Adapter{} = adapter) do
    """
    You are a hook author for Claude Code. Given a HAZARD mined from a real coding-agent session —
    a dangerous command shape the session ran WITHOUT any visible struggle — write EXACTLY ONE hook
    that intercepts it next time.

    Target stack: #{adapter.name} v#{adapter.version}.

    A hook is not a skill. It is a shell script Claude Code runs automatically, plus a pointer
    saying when to run it. Do not write prose, frontmatter, or advice.

    Hook rules:
    - event: one of #{Enum.join(@hook_events, " | ")}. Prefer PreToolUse to intercept a command
      BEFORE it runs. Note PostToolUse cannot see a successful command's exit code, so it is the
      wrong event for anything about a command lying about success.
    - matcher: the tool name the hook fires on (e.g. "Bash").
    - script: a complete POSIX/bash script. It MUST start with a `#!` shebang line. Claude Code
      pipes the tool call to it on stdin as JSON — read it (e.g. `input=$(cat)`) and pull the
      command out (the shape is `{"tool_name": "...", "tool_input": {"command": "..."}}`).
      Exit 0 to allow; exit 2 to BLOCK the call and show your stderr to the agent.
    - The script must be conservative: it fires on every matching tool call, so a false positive
      blocks legitimate work. Match the specific dangerous shape, not a broad family.
    - The script must be safe: it must not delete, download, or execute anything. It inspects a
      command and decides. Nothing else.
    - description: 50–250 chars, "what + when" — what it intercepts and why that shape is dangerous.
    - rationale: one line on why this hazard needs a hook rather than a skill.

    Return the structured object only.
    """
  end

  defp hook_user_prompt(%Scan.Result{} = r, hazard, %Adapter{name: name}) do
    """
    Hazard found in one #{name} session. It produced NO friction — no error, no retry, no
    correction — which is exactly why it needs a hook: nothing about the session looked wrong.

    - hazard class: #{hazard[:kind]}
    - evidence: #{hazard[:evidence]}
    - times this session ran that shape: #{hazard[:count] || 1}
    - session fingerprint: #{r.fingerprint}
    - implied hook pointer: event #{hazard[:suggested_event]}, matcher #{hazard[:matcher]}

    Write the hook that intercepts the shape in the evidence. Use the implied pointer unless it is
    wrong for the hazard, and warn/block ONLY on that shape — the safe form of the same command
    must pass untouched.
    """
  end

  defp build_hook_proposal(object, %Scan.Result{} = r, hazard, %Adapter{} = adapter) do
    %Proposal{
      kind: :hook,
      name: get(object, :name),
      description: get(object, :description),
      rationale: get(object, :rationale),
      event: get(object, :event),
      matcher: get(object, :matcher),
      script: get(object, :script),
      adapter: adapter.name,
      source: %{
        session_id: r.session_id,
        path: r.path,
        # What selected this session — a hazard class, NOT a friction signal. Recorded distinctly so
        # provenance can't imply the ranking found it (it can't; that is the whole point).
        hazard: hazard[:kind],
        hazard_evidence: hazard[:evidence],
        fingerprint: r.fingerprint
      }
    }
  end

  defp augment_with_feedback(user, nil), do: user
  defp augment_with_feedback(user, ""), do: user

  defp augment_with_feedback(user, feedback) when is_binary(feedback) do
    user <> "\n\n" <> feedback
  end

  @doc """
  Does `adapter`'s stack apply to `result`? `force?` short-circuits to `true`.

  The single stack-match decision, shared by every site that *selects* a session to draft for.
  `propose/3` deliberately does not call it (see `stack_gate/3`), so each selection site asks
  explicitly — but they must all ask the same question, of the same function.
  """
  @spec stack_match?(Adapter.t(), Scan.Result.t(), boolean()) :: boolean()
  def stack_match?(adapter, result, force? \\ false)
  def stack_match?(%Adapter{}, %Scan.Result{}, true), do: true

  def stack_match?(%Adapter{} = adapter, %Scan.Result{} = result, _force?),
    do: Adapter.matches_session?(adapter, result.file_paths)

  @doc """
  Stack-aware gate: refuse to draft a skill when `result` doesn't belong to `adapter`'s stack.

  Without it a Go session's friction is drafted into a Phoenix skill — and then graded against the
  Elixir bar by an equally adapter-scoped `Faber.Eval`, which is why a wrong-stack draft can still
  score a confident PASS. The eval cannot catch this; only the gate can.

  Lives here, at the propose *boundary*, rather than inside `propose/3`: `Faber.Loop` re-proposes
  the same result repeatedly and a gate in the call itself would break refinement. Every selection
  site (`Faber.CLI`, `FaberWeb.DashboardLive`, the MCP tool) must call it before `propose/3`.
  """
  @spec stack_gate(Adapter.t(), Scan.Result.t(), boolean()) ::
          :ok | {:error, {:stack_mismatch, Adapter.t(), Scan.Result.t()}}
  def stack_gate(%Adapter{} = adapter, %Scan.Result{} = result, force? \\ false) do
    if stack_match?(adapter, result, force?),
      do: :ok,
      else: {:error, {:stack_mismatch, adapter, result}}
  end

  @doc """
  The file extensions `result` touched, most-frequent first, as `{ext, count}` pairs.

  The evidence a stack mismatch is explained with (`.go×74` says more than "wrong stack"). Shared
  so the CLI's refusal and the dashboard's badge cite the same numbers.
  """
  @spec touched_extensions(Scan.Result.t()) :: [{String.t(), pos_integer()}]
  def touched_extensions(%Scan.Result{file_paths: paths}) do
    paths
    |> Enum.map(&Path.extname/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_ext, n} -> -n end)
  end

  @doc """
  Assemble the `{system, user}` prompt for a friction finding. Pure — no LLM call — so the
  prompt content is unit-testable.
  """
  @spec build_prompt(Scan.Result.t(), Adapter.t()) :: {String.t(), String.t()}
  def build_prompt(%Scan.Result{} = result, %Adapter{} = adapter) do
    {system_prompt(adapter), user_prompt(result, adapter)}
  end

  defp system_prompt(%Adapter{} = adapter) do
    """
    You are a skill author for AI coding agents. Given a friction finding mined from a real
    coding-agent session and the conventions of a specific tech stack, propose EXACTLY ONE new
    skill (a Claude Code SKILL.md) that would reduce that friction next time.

    Target stack: #{adapter.name} v#{adapter.version}.

    Skill rules:
    - description: 50–250 chars, "what + when". Lead with concrete sub-topics, then a "Use when …"
      clause naming concrete scenarios. Prefer specific tech/error names over category labels.
      Add a short "NOT for …" clause when it disambiguates from an adjacent skill.
    - iron_laws: at least 3 non-negotiable, stack-appropriate invariants, imperative voice.
    - usage: one line on how/when the skill fires.
    - example: a concrete, runnable snippet of AT LEAST TWO lines — e.g. the command plus the
      check that confirms it worked, or a 2-step invocation — never a bare one-liner.
    - workflow: 3–6 ordered, imperative steps the agent follows when the skill fires (e.g.
      "#{example_step(adapter)}"). Each is one actionable line.
    - patterns: 2–4 stack-specific idioms or anti-patterns, each as `Name: do X, not Y` (a concrete
      do/don't), not vague advice.
    - should_trigger / should_not_trigger: realistic user phrasings for routing tests.
    - Keep it tight: the body should read like ~100 lines of skill, not an essay.

    #{adapter_context(adapter)}

    Return the structured object only.
    """
  end

  defp adapter_context(%Adapter{laws: laws, playbooks: playbooks}) do
    law_lines =
      laws
      |> Enum.take(12)
      |> Enum.map_join("\n", fn l -> "  - #{l.statement}" end)

    play_lines =
      playbooks
      |> Enum.take(8)
      |> Enum.map_join("\n", fn p -> "  - #{p.id}: #{Enum.join(p.symptoms, ", ")}" end)

    [
      if(law_lines != "", do: "Stack Iron Laws to respect:\n#{law_lines}"),
      if(play_lines != "", do: "Known investigation playbooks (id: symptoms):\n#{play_lines}")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  # The worked example for the `workflow:` instruction. An adapter supplies a stack-idiomatic
  # one via `metadata.example_step` (contract §3); otherwise fall back to stack-neutral phrasing
  # so the engine never leaks a specific stack's command (e.g. `mix test`) into other adapters.
  defp example_step(%Adapter{metadata: metadata}) when is_map(metadata) do
    case metadata["example_step"] do
      step when is_binary(step) and step != "" -> step
      _ -> "Run the failing test in isolation"
    end
  end

  defp example_step(_adapter), do: "Run the failing test in isolation"

  defp user_prompt(%Scan.Result{} = r, %Adapter{name: name, version: version}) do
    signals =
      r.signals
      |> Enum.map_join("\n", fn {k, v} -> "  - #{k}: #{v}" end)

    """
    Friction finding from one #{name} (v#{version}) session — the skill must fit this stack's
    conventions and Iron Laws (above):

    - session fingerprint: #{r.fingerprint} (confidence #{fmt(r.fingerprint_confidence)})
    - dominant friction signal: #{r.dominant_signal || "none"}
    - raw friction: #{fmt(r.raw)} (#{r.human_turns} human turns across #{r.message_count} transcript events, #{r.tool_count} tools, #{r.error_count} errors)
    - friction signals:
    #{signals}
    - missed automation opportunities: #{fmt_list(r.missed)}
    - skills already used: #{fmt_list(r.skills_used)}

    Propose ONE skill that would most reduce this session's dominant friction. Do not duplicate a
    skill the session already used.
    """
  end

  @doc """
  Render a proposal into its artifact, using `adapter`'s `templates/` scaffold for the proposal's
  **kind** when the pack ships one, so the output matches the stack's idiom (section order,
  frontmatter, idiomatic examples).

  The template is selected by `to_string(proposal.kind)` — the same key
  `Faber.Adapter.read_templates/1` builds the map with, and the same enum
  `Faber.Adapter.validate/1` now guarantees. This used to be a hardcoded `Map.get(templates,
  "skill")`, the only key fetched repo-wide, which is why an adapter's `hook` template could load
  and never be reachable.

  Falling back to the built-in renderer is a **skill-only** affordance: there is a built-in
  `SKILL.md` scaffold to fall back *to*. Any other kind with no template raises — a missing hook
  template must not silently render a skill (or an empty string that sails through the eval).
  """
  @spec render(Proposal.t(), Adapter.t() | nil) :: String.t()
  def render(proposal, adapter \\ nil)

  def render(%Proposal{kind: kind} = p, %Adapter{templates: templates}) do
    case Map.get(templates, to_string(kind)) do
      tmpl when is_binary(tmpl) -> Template.render(tmpl, template_context(p))
      _ -> render_builtin(p)
    end
  end

  def render(%Proposal{} = p, nil), do: render_builtin(p)

  defp render_builtin(%Proposal{kind: :skill} = p), do: render_skill_md(p)

  defp render_builtin(%Proposal{kind: kind, name: name}) do
    raise ArgumentError,
          "no #{kind} template: the selected adapter ships no `produces: #{kind}` scaffold and " <>
            "the engine has no built-in one, so #{inspect(name)} cannot be rendered. Add a " <>
            "`#{kind}` entry to the pack's templates/manifest.yaml."
  end

  @doc """
  Render a `kind: :skill` proposal into a `SKILL.md` string using `adapter`'s scaffold.

  A thin delegator to `render/2`, kept because 13 callsites spell this name. New code that isn't
  skill-specific should call `render/2`.
  """
  @spec render_skill_md(Proposal.t(), Adapter.t()) :: String.t()
  def render_skill_md(%Proposal{} = p, %Adapter{} = adapter), do: render(p, adapter)

  # String-keyed context for a hook scaffold. A hook's artifact IS its script, so the template is a
  # thin wrapper (provenance header + the body) rather than a document with sections.
  #
  # **Every token here except `script` lands in a `#` comment, so every one of them is
  # `comment_safe/1`.** That is the invariant, and it is meant to be checkable by eye: a reviewer
  # should be able to see at a glance that nothing raw reaches the template. `event`, `matcher` and
  # `hook_name` were raw until 2026-07-17, which is exactly how a newline in `matcher` turned into a
  # live shell line under a *perfect* 1.0 eval score.
  defp template_context(%Proposal{kind: :hook} = p) do
    %{
      "hook_name" => comment_safe(p.name),
      "description" => comment_safe(p.description),
      "one_line_purpose" => comment_safe(p.rationale),
      "event" => comment_safe(p.event),
      "matcher" => comment_safe(p.matcher),
      "script" => script_body(p.script),
      "hazard" => comment_safe(p.source[:hazard] || ""),
      "hazard_evidence" => comment_safe(p.source[:hazard_evidence] || "")
    }
  end

  # String-keyed context for the Mustache-subset skill scaffold. Tokens the proposal can't fill
  # (steps, patterns, argument_hint, allowed_tools) resolve to empty — the renderer drops them.
  defp template_context(%Proposal{} = p) do
    %{
      "skill_name" => p.name,
      "skill_title" => titleize(p.name),
      "description" => escape(p.description),
      "effort" => p.effort,
      "one_line_purpose" => p.rationale,
      # Always ≥2 non-empty lines (usage comment + example), so the template's single fenced block
      # satisfies the eval's has_examples check the way the built-in renderer's `## Examples` does.
      "usage_examples" => usage_block(p),
      "iron_laws" =>
        p.iron_laws
        |> Enum.with_index(1)
        |> Enum.map(fn {law, i} -> %{"index" => i, "law_statement" => law} end),
      # Presence flags gate the section header in the template, so an empty workflow/patterns drops
      # the whole `## Section` (header included) rather than leaving a dangling empty heading.
      "workflow_present" => p.workflow != [],
      "steps" =>
        p.workflow
        |> Enum.with_index(1)
        |> Enum.map(fn {step, i} -> %{"step_index" => i, "step_body" => oneline(step)} end),
      "patterns_present" => p.patterns != [],
      "patterns" => Enum.map(p.patterns, fn pat -> %{"pattern_text" => format_pattern(pat)} end)
    }
  end

  # The template owns the shebang, so the model's must come off — a `#!` line is only a shebang on
  # line 1; anywhere else it is a comment, and two of them means the file says one thing and does
  # another. This is the renderer *guaranteeing* the eval's shebang check rather than the prompt
  # wishing for it: the check passes by construction for every hook, however the model replies.
  defp script_body(nil), do: ""

  defp script_body(script) when is_binary(script) do
    # Trim BEFORE looking for the shebang, not after: a model that opens with a blank line puts the
    # `#!` on line 2, where this would have missed it and the template's own shebang would then have
    # made two — the file saying `bash` on line 1 and `zsh` on line 3.
    script
    |> String.trim()
    |> String.split("\n")
    |> case do
      ["#!" <> _ | rest] -> rest
      lines -> lines
    end
    |> Enum.join("\n")
    |> String.trim()
  end

  @doc """
  Render a proposal into a `SKILL.md` string that satisfies the skill conventions
  (frontmatter, Iron Laws ≥3, Usage, a fenced example, References).
  """
  @spec render_skill_md(Proposal.t()) :: String.t()
  def render_skill_md(%Proposal{} = p) do
    laws =
      p.iron_laws
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {law, i} -> "#{i}. #{law}" end)

    """
    ---
    name: #{p.name}
    description: "#{escape(p.description)}"
    effort: #{p.effort}
    ---

    # #{titleize(p.name)}

    #{p.rationale}

    ## Usage

    #{p.usage || "Loaded automatically when the trigger conditions in the description match."}

    ## Iron Laws — Never Violate These

    #{laws}
    #{workflow_section(p.workflow)}#{patterns_section(p.patterns)}## Examples

    ```bash
    #{usage_block(p)}
    ```

    ## References

    - `${CLAUDE_SKILL_DIR}/references/#{p.name}.md` — supporting detail (stub for now)
    """
  end

  # Optional body sections — empty list ⇒ "" (no dangling header). Numbered/bold-bulleted lines so
  # they read as actionable (the clarity matcher's action_density), matching the adapter template.
  defp workflow_section([]), do: ""

  defp workflow_section(steps) do
    body =
      steps |> Enum.with_index(1) |> Enum.map_join("\n", fn {s, i} -> "#{i}. #{oneline(s)}" end)

    "\n## Workflow\n\n#{body}\n\n"
  end

  defp patterns_section([]), do: ""

  defp patterns_section(patterns) do
    body = Enum.map_join(patterns, "\n", fn p -> "- #{format_pattern(p)}" end)
    "\n## Patterns\n\n#{body}\n\n"
  end

  # A 2-line worked example: a usage comment over the concrete snippet. Always ≥2 non-empty lines so
  # a single fenced block satisfies the eval's has_examples (≥2 lines) check — shared by the built-in
  # `## Examples` fence and the adapter template's `## Usage` fence.
  defp usage_block(%Proposal{usage: usage, example: example}) do
    comment =
      "# " <> fence_safe(present(usage) || "When the trigger conditions in the description match")

    body = fence_safe(present(example) || "# (add a concrete example)")
    comment <> "\n" <> body
  end

  defp present(s) when is_binary(s) do
    case String.trim(s) do
      "" -> nil
      _ -> s
    end
  end

  defp present(_), do: nil

  # Defang an LLM value before it goes inside a ```fenced``` block: collapse any run of ≥3 backticks
  # to one (so the value can't close the fence early) and strip surrounding blank lines (so the fence
  # has no stray empty lines). The skill file is local, not a web sink, so this is hygiene, not RCE
  # defense — but it keeps generated skills well-formed regardless of what the model returns.
  defp fence_safe(text) do
    text |> to_string() |> String.replace(~r/`{3,}/, "`") |> String.trim()
  end

  # Flatten a list item to a single line — a multi-line workflow step or pattern would otherwise
  # inject extra markdown structure into the numbered list / bullet.
  defp oneline(text), do: text |> to_string() |> String.replace(~r/\s+/, " ") |> String.trim()

  # Make an LLM value safe to sit inside a `#` shell comment. Used for EVERY non-`{{script}}` token
  # of a hook (`template_context/1`), because `Faber.Template.render_vars/2` does `to_string(v)` with
  # no escaping — correct, since `{{script}}` is raw by necessity — which leaves this function as the
  # only place the defence can live. A renderer guarantee, per CLAUDE.md: safe by construction, not
  # because the model declined to send a newline.
  #
  # Two classes of character come out, and the second is the less obvious one:
  #
  #   * `\p{Cc}` (control) — a `#` comment ends at a newline, so a token carrying one stops being a
  #     comment and becomes a command. Reproduced live: `matcher: "Bash\n<payload>\n#"` rendered the
  #     payload as a live line and still scored `composite: 1.0, vetoed: []`.
  #
  #   * `\p{Cf}` (format: bidi overrides, zero-width joiners) — these change what a terminal
  #     *displays* without changing the bytes. That matters here more than it looks: Faber's install
  #     posture makes the human reading ~15 lines of bash THE security boundary (the veto is a
  #     backstop that 7 of 8 known vectors walk past). A character that can make the displayed script
  #     differ from the executed script is therefore an attack on the boundary itself, not a
  #     cosmetic issue. Same family as the bidi checks `/phx:deps-audit` already runs on Hex deps.
  #
  # Replaced with a space rather than deleted: deletion would silently splice two words together
  # ("Pre\nToolUse" -> "PreToolUse", a *valid*-looking event), which hides the tampering instead of
  # showing it. The remaining `\s+` collapse then flattens the lot to one line.
  defp comment_safe(text) do
    text
    |> to_string()
    |> String.replace(~r/[\p{Cc}\p{Cf}]/u, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # "Name: guidance" → "**Name**: guidance" (a bold-bulleted, actionable do/don't line); a line with
  # no colon is bolded whole. Collapsed to one line first (both render paths go through here).
  defp format_pattern(text) do
    case text |> oneline() |> String.split(":", parts: 2) do
      [name, rest] -> "**#{String.trim(name)}**:#{rest}"
      [only] -> "**#{String.trim(only)}**"
    end
  end

  # ── building the struct from the LLM object ───────────────────────────────

  defp build_proposal(object, %Scan.Result{} = r, %Adapter{} = adapter) do
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
        session_id: r.session_id,
        path: r.path,
        dominant_signal: r.dominant_signal,
        fingerprint: r.fingerprint,
        friction: r.raw,
        missed: r.missed
      }
    }
  end

  # LLM objects may key on atoms or strings depending on the provider/schema compiler.
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

  # ── formatting helpers ────────────────────────────────────────────────────

  defp fmt(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 2)
  defp fmt(n), do: to_string(n)

  defp fmt_list([]), do: "(none)"
  defp fmt_list(list), do: Enum.join(list, ", ")

  # The description lands inside a quoted YAML frontmatter scalar. It comes from LLM output mined
  # from untrusted transcripts, so collapse newlines/whitespace to single spaces (a raw newline or
  # a `---` line could otherwise forge frontmatter) and swap the quote char.
  defp escape(str) do
    (str || "")
    |> String.replace("\"", "'")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp titleize(name) do
    name
    |> to_string()
    |> String.split(~r/[-_]/)
    |> Enum.map_join(" ", &String.capitalize/1)
  end
end
