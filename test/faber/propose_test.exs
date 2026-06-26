defmodule Faber.ProposeTest do
  use ExUnit.Case, async: true

  alias Faber.{Adapter, Propose, Proposal, Scan}

  @reference_adapter Path.expand("../../adapters/faber-elixir", __DIR__)

  # Namespaced module-level double (not defined inside a test body — that pollutes the global atom
  # table and can collide across async runs).
  defmodule FailingLLM do
    @behaviour Faber.LLM
    @impl true
    def generate_object(_prompt, _schema, _opts), do: {:error, :no_api_key}
  end

  defp adapter do
    %Adapter{
      name: "faber-elixir",
      version: "0.1.0",
      laws: [
        %{
          id: "verify",
          category: "process",
          severity: "high",
          statement: "Verify before claiming done",
          check: nil
        },
        %{
          id: "otp",
          category: "otp",
          severity: "high",
          statement: "No bare start_link outside a supervisor",
          check: nil
        }
      ],
      playbooks: [
        %{
          id: "compile-error",
          source: nil,
          symptoms: ["compile fails", "undefined function"],
          body: nil
        }
      ]
    }
  end

  defp result do
    %Scan.Result{
      path: "/Users/x/Projects/demo/abc.jsonl",
      session_id: "abc",
      friction: 0.9,
      raw: 12.0,
      dominant_signal: :retry_loops,
      signals: %{
        retry_loops: 2,
        user_corrections: 1,
        error_tool_ratio: 0.3,
        approach_changes: 0,
        context_compactions: 0,
        interrupted_requests: 0
      },
      fingerprint: "bug-fix",
      fingerprint_confidence: 0.6,
      opportunity: 0.4,
      missed: ["investigate"],
      skills_used: [],
      tool_count: 10,
      error_count: 3,
      message_count: 40,
      parse_errors: 0,
      tier2: true
    }
  end

  describe "build_prompt/2" do
    test "weaves in the friction finding and the adapter's laws" do
      {system, user} = Propose.build_prompt(result(), adapter())

      assert system =~ "faber-elixir"
      assert system =~ "Verify before claiming done"
      assert system =~ "compile-error"

      assert user =~ "retry_loops"
      assert user =~ "bug-fix"
      assert user =~ "investigate"
      # The adapter/stack context is woven into the user half too, not only the system prompt.
      assert user =~ "faber-elixir"

      # The proposer asks for an actionable body (workflow steps + do/don't patterns), not just laws.
      assert system =~ "workflow:"
      assert system =~ "patterns:"
    end

    test "injects the adapter's example_step, with a stack-neutral fallback" do
      # No metadata.example_step → neutral phrasing, no leaked stack command (e.g. `mix test`).
      {neutral, _} = Propose.build_prompt(result(), adapter())
      assert neutral =~ "Run the failing test in isolation"
      refute neutral =~ "mix test path:line"

      # An adapter that supplies metadata.example_step gets it verbatim.
      stacked = %{adapter() | metadata: %{"example_step" => "Run `pytest -x path::test`"}}
      {system, _} = Propose.build_prompt(result(), stacked)
      assert system =~ "Run `pytest -x path::test`"
    end
  end

  describe "schema/0" do
    test "declares the workflow + patterns fields the renderers depend on" do
      # The Stub returns its stub_response verbatim (ignoring the schema), so without this guard a
      # schema regression that drops these fields would pass every other test silently.
      schema = Propose.schema()
      assert Keyword.has_key?(schema, :workflow)
      assert Keyword.has_key?(schema, :patterns)
    end
  end

  describe "propose/3" do
    test "returns a Proposal from the configured stub LLM" do
      {:ok, %Proposal{} = p} = Propose.propose(result(), adapter())

      assert is_binary(p.name) and p.name != ""
      assert is_binary(p.description)
      assert length(p.iron_laws) >= 3
      assert p.adapter == "faber-elixir"
      assert p.source.session_id == "abc"
      assert p.source.dominant_signal == :retry_loops
    end

    test "maps a custom stub_response with string keys (the get/2 fallback) into the struct" do
      custom = %{
        "name" => "tidy-migrations",
        "description" => "A focused skill for keeping Ecto migrations reversible and small.",
        "rationale" => "because",
        "iron_laws" => ["one", "two", "three"]
      }

      {:ok, p} = Propose.propose(result(), adapter(), llm: Faber.LLM.Stub, stub_response: custom)
      assert p.name == "tidy-migrations"
      assert p.iron_laws == ["one", "two", "three"]
      assert p.effort == "medium"
      # Absent workflow/patterns default to empty lists (the section is then omitted at render).
      assert p.workflow == []
      assert p.patterns == []
    end

    test "maps a stub_response with atom keys (exercises the get/2 primary Map.fetch path)" do
      custom = %{
        name: "atomic-skill",
        description: "An atom-keyed object, as some providers return.",
        rationale: "because",
        iron_laws: ["one", "two", "three"],
        workflow: ["Step one"],
        patterns: ["Focused: do X, not Y"]
      }

      {:ok, p} = Propose.propose(result(), adapter(), llm: Faber.LLM.Stub, stub_response: custom)
      assert p.name == "atomic-skill"
      assert p.iron_laws == ["one", "two", "three"]
      assert p.workflow == ["Step one"]
      assert p.patterns == ["Focused: do X, not Y"]
    end

    test "maps workflow + patterns lists from the LLM object" do
      custom = %{
        "name" => "x",
        "description" => "d",
        "rationale" => "r",
        "iron_laws" => ["a", "b", "c"],
        "workflow" => ["Run the failing test in isolation", "Form one hypothesis"],
        "patterns" => ["Focused runs: mix test file:line, not the full suite"]
      }

      {:ok, p} = Propose.propose(result(), adapter(), llm: Faber.LLM.Stub, stub_response: custom)
      assert p.workflow == ["Run the failing test in isolation", "Form one hypothesis"]
      assert p.patterns == ["Focused runs: mix test file:line, not the full suite"]
    end

    test "surfaces an LLM error" do
      assert {:error, :no_api_key} = Propose.propose(result(), adapter(), llm: FailingLLM)
    end
  end

  describe "render_skill_md/1" do
    test "renders frontmatter and the required sections" do
      {:ok, p} = Propose.propose(result(), adapter())
      md = Propose.render_skill_md(p)

      assert md =~ ~r/\A---\n/
      assert md =~ "name: #{p.name}"
      assert md =~ "description: \""
      assert md =~ "## Usage"
      assert md =~ "## Iron Laws — Never Violate These"
      assert md =~ "## Examples"
      assert md =~ "## References"
      assert md =~ "```bash"

      # At least three numbered Iron Laws.
      law_numbers = Regex.scan(~r/^\d+\.\s/m, md)
      assert length(law_numbers) >= 3
    end

    test "renders Workflow (numbered) + Patterns (bold do/don't) when present" do
      p = %Proposal{
        name: "x",
        description: "d",
        rationale: "r",
        iron_laws: ["a", "b", "c"],
        workflow: ["Run `mix test path:line`", "Change one variable"],
        patterns: ["Focused runs: use mix test file:line, not the full suite"]
      }

      md = Propose.render_skill_md(p)

      assert md =~ "## Workflow"
      assert md =~ "1. Run `mix test path:line`"
      assert md =~ "2. Change one variable"
      assert md =~ "## Patterns"
      # "Name: rest" → bold-bulleted do/don't line (also satisfies action_density).
      assert md =~ "- **Focused runs**: use mix test file:line, not the full suite"
    end

    test "omits the Workflow/Patterns sections entirely when empty (no dangling header)" do
      {:ok, p} = Propose.propose(result(), adapter())
      assert p.workflow == [] and p.patterns == []
      md = Propose.render_skill_md(p)

      refute md =~ "## Workflow"
      refute md =~ "## Patterns"
    end

    test "the Examples fence carries a >=2-line worked example (has_examples passes)" do
      {:ok, p} = Propose.propose(result(), adapter())
      md = Propose.render_skill_md(p)

      # usage comment over the concrete example → two non-empty lines in one fence.
      assert {true, _} = Faber.Eval.Matchers.has_examples(md, %{min_blocks: 1})

      # Independent of the matcher: assert the fence itself directly, so a matcher regex change can't
      # silently "pass" this without the renderer actually guaranteeing the >=2-line minimum.
      assert fence_nonempty_lines(md) >= 2
    end

    test "the example fence stays >=2 lines even when usage/example are absent" do
      # The renderer must guarantee the structural minimum regardless of LLM cooperation.
      p = %Proposal{name: "x", description: "d", rationale: "r", iron_laws: ["a", "b", "c"]}
      md = Propose.render_skill_md(p)

      assert {true, _} = Faber.Eval.Matchers.has_examples(md, %{min_blocks: 1})
      assert fence_nonempty_lines(md) >= 2
    end

    test "a backtick-fenced LLM example can't break out of the Examples fence" do
      # An adversarial/sloppy model returns ``` inside the example; the renderer must defang it so
      # the surrounding fence stays intact (one well-formed block).
      p = %Proposal{
        name: "x",
        description: "d",
        rationale: "r",
        iron_laws: ["a", "b", "c"],
        usage: "when X",
        example: "```elixir\nIO.puts(:hi)\n```"
      }

      md = Propose.render_skill_md(p)

      # Exactly one fenced block survives (the value's triple-backticks were collapsed).
      assert length(Regex.scan(~r/```/, md)) == 2
      assert {true, _} = Faber.Eval.Matchers.has_examples(md, %{min_blocks: 1})
    end
  end

  describe "render_skill_md/2 (adapter template)" do
    test "renders via the adapter's skill scaffold when one is shipped" do
      {:ok, p} = Propose.propose(result(), adapter())

      adapter_with_tmpl = %{
        adapter()
        | templates: %{
            "skill" =>
              "name: {{skill_name}}\n{{#iron_laws}}{{index}}. {{law_statement}}\n{{/iron_laws}}"
          }
      }

      md = Propose.render_skill_md(p, adapter_with_tmpl)

      assert md =~ "name: #{p.name}"
      # The {{#iron_laws}} section expanded once per law.
      assert md =~ "1. #{Enum.at(p.iron_laws, 0)}"
      # Built-in-only markers do NOT appear — proof the template path was taken.
      refute md =~ "## References"
    end

    test "falls back to the built-in renderer when the adapter ships no skill template" do
      {:ok, p} = Propose.propose(result(), adapter())
      assert Propose.render_skill_md(p, adapter()) == Propose.render_skill_md(p)
    end

    test "the real faber-elixir template produces a complete, eval-passing skill" do
      {:ok, adapter} = Adapter.load(@reference_adapter)
      {:ok, p} = Propose.propose(result(), adapter)
      md = Propose.render_skill_md(p, adapter)

      assert md =~ "name: #{p.name}"
      assert md =~ "## Iron Laws"
      assert md =~ "## References"

      # "eval-passing" is a real claim, not just structural markers: score it through the native
      # (hermetic) engine and assert it clears the gate.
      assert {:ok, %{passed: true}} = Faber.Eval.score(md, engine: :native)
    end

    test "the real faber-elixir template presence-gates Workflow/Patterns" do
      {:ok, adapter} = Adapter.load(@reference_adapter)
      {:ok, base} = Propose.propose(result(), adapter)

      # Absent → the headers must not appear (the bug dogfooding caught: dangling empty sections).
      bare = Propose.render_skill_md(%{base | workflow: [], patterns: []}, adapter)
      refute bare =~ "## Workflow"
      refute bare =~ "## Patterns"

      # Present → numbered steps + bold do/don't bullets render through the template path.
      filled =
        Propose.render_skill_md(
          %{
            base
            | workflow: ["Read the actual error first"],
              patterns: ["Runs: focused, not full"]
          },
          adapter
        )

      assert filled =~ "## Workflow"
      assert filled =~ "1. Read the actual error first"
      assert filled =~ "## Patterns"
      assert filled =~ "- **Runs**: focused, not full"
    end

    test "the real faber-elixir template's Usage fence passes has_examples" do
      {:ok, adapter} = Adapter.load(@reference_adapter)
      {:ok, p} = Propose.propose(result(), adapter)
      md = Propose.render_skill_md(p, adapter)

      # The template ships a single fenced block (Usage); the renderer guarantees it holds the
      # usage comment + example, so the clarity dimension's has_examples check passes via the
      # adapter path — the gap dogfooding caught: clarity stuck at 0.50 (action_density ok, examples
      # missing).
      assert {true, _} = Faber.Eval.Matchers.has_examples(md, %{min_blocks: 1})

      # And it holds even when the LLM omits usage/example.
      bare = Propose.render_skill_md(%{p | usage: nil, example: nil}, adapter)
      assert {true, _} = Faber.Eval.Matchers.has_examples(bare, %{min_blocks: 1})
    end
  end

  # Count non-empty lines inside the first fenced block — a matcher-independent check that the
  # renderer really emits a >=2-line example.
  defp fence_nonempty_lines(md) do
    case Regex.run(~r/```[\w]*\n(.*?)```/s, md) do
      [_, inner] -> inner |> String.split("\n") |> Enum.count(&(String.trim(&1) != ""))
      _ -> 0
    end
  end
end
