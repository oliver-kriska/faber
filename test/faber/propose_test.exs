defmodule Faber.ProposeTest do
  use ExUnit.Case, async: true

  alias Faber.{Adapter, Propose, Proposal, Scan}

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

    test "maps a custom stub_response (atom keys) into the struct" do
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
      {:ok, adapter} = Adapter.load("adapters/faber-elixir")
      {:ok, p} = Propose.propose(result(), adapter)
      md = Propose.render_skill_md(p, adapter)

      assert md =~ "name: #{p.name}"
      assert md =~ "## Iron Laws"
      assert md =~ "## References"
    end
  end
end
