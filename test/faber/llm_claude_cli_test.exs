defmodule Faber.LLM.ClaudeCLITest do
  use ExUnit.Case, async: true

  alias Faber.LLM.ClaudeCLI

  @schema [
    name: [type: :string, required: true],
    description: [type: :string, required: true],
    iron_laws: [type: {:list, :string}, required: true],
    effort: [type: :string]
  ]

  describe "render_schema/1" do
    test "lists fields with types and required markers" do
      out = ClaudeCLI.render_schema(@schema)
      assert out =~ "name: string (required)"
      assert out =~ "iron_laws: array of strings (required)"
      assert out =~ "effort: string"
      assert out =~ "ONLY a single JSON object"
    end
  end

  describe "build_system/2" do
    test "appends the JSON instruction to the caller's system prompt" do
      out = ClaudeCLI.build_system("You are a skill author.", @schema)
      assert out =~ "You are a skill author."
      assert out =~ "name: string (required)"
    end

    test "handles a nil system prompt" do
      assert ClaudeCLI.build_system(nil, @schema) =~ "ONLY a single JSON object"
    end
  end

  describe "parse_envelope/1" do
    test "extracts the result field from the CLI json envelope" do
      env = Jason.encode!(%{"type" => "result", "result" => "hello"})
      assert ClaudeCLI.parse_envelope(env) == {:ok, "hello"}
    end

    test "falls back to raw output when not an envelope" do
      assert ClaudeCLI.parse_envelope("not json") == {:ok, "not json"}
      assert ClaudeCLI.parse_envelope(~s({"foo":1})) == {:ok, ~s({"foo":1})}
    end
  end

  describe "extract_json/1" do
    test "parses a bare JSON object" do
      assert {:ok, %{"a" => 1}} = ClaudeCLI.extract_json(~s({"a": 1}))
    end

    test "strips a ```json code fence" do
      assert {:ok, %{"a" => 1}} = ClaudeCLI.extract_json("```json\n{\"a\": 1}\n```")
    end

    test "slices an object out of surrounding prose" do
      text = "Here is the skill:\n{\"a\": 1, \"b\": [2,3]}\nHope that helps!"
      assert {:ok, %{"a" => 1, "b" => [2, 3]}} = ClaudeCLI.extract_json(text)
    end

    test "errors when there is no object" do
      assert {:error, :no_json_object} = ClaudeCLI.extract_json("no json here")
    end
  end

  describe "generate_object/3 (fake claude binary)" do
    @tag :tmp_dir
    test "shells out and returns the parsed object", %{tmp_dir: dir} do
      inner = ~s({"name":"demo-skill","description":"d","iron_laws":["a","b","c"]})
      envelope = Jason.encode!(%{"type" => "result", "result" => inner})
      script = Path.join(dir, "fake_claude")
      File.write!(script, "#!/bin/sh\ncat <<'EOF'\n#{envelope}\nEOF\n")
      File.chmod!(script, 0o755)

      assert {:ok, object} =
               ClaudeCLI.generate_object("prompt", @schema,
                 system_prompt: "sys",
                 claude_bin: script
               )

      assert object["name"] == "demo-skill"
      assert object["iron_laws"] == ["a", "b", "c"]
    end

    test "returns an error when the binary is missing" do
      assert {:error, {:claude_cli_unavailable, _}} =
               ClaudeCLI.generate_object("p", @schema,
                 claude_bin: "definitely-not-a-real-bin-xyz"
               )
    end

    @tag :tmp_dir
    test "a hung CLI is killed at :timeout instead of hanging the caller", %{tmp_dir: dir} do
      script = Path.join(dir, "hung_claude")
      File.write!(script, "#!/bin/sh\nsleep 30\n")
      File.chmod!(script, 0o755)

      {us, result} =
        :timer.tc(fn ->
          ClaudeCLI.generate_object("prompt", @schema, claude_bin: script, timeout: 150)
        end)

      assert result == {:error, {:claude_cli_timeout, 150}}
      assert us < 5_000_000
    end
  end
end
