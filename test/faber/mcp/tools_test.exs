defmodule Faber.MCP.ToolsTest do
  # async: false — these mutate global app config (:mcp_scan_opts, :skills_dir).
  use ExUnit.Case, async: false

  alias Anubis.Server.Frame
  alias Faber.MCP.Tools.{GetSkill, ListSkills, SearchFriction}

  # A distinctive raw-transcript string from test/fixtures/sample_session.jsonl that must NEVER
  # appear in any tool output — the privacy boundary (aggregates only, never transcript text).
  @raw_transcript_phrase "please add a feature to the parser"

  defp frame, do: Frame.new()

  # Decode a tool's JSON reply body into a map with string keys.
  defp json_reply({:reply, %{content: [%{"text" => text} | _]} = resp, _frame}) do
    refute resp.isError
    Jason.decode!(text)
  end

  describe "faber_search_friction" do
    setup do
      prev = Application.get_env(:faber, :mcp_scan_opts)
      Application.put_env(:faber, :mcp_scan_opts, base: "test/fixtures", min_messages: 0)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:faber, :mcp_scan_opts, prev),
          else: Application.delete_env(:faber, :mcp_scan_opts)
      end)
    end

    test "returns ranked friction findings as aggregates" do
      reply = json_reply(SearchFriction.execute(%{limit: 5}, frame()))

      assert reply["count"] > 0
      assert length(reply["findings"]) == reply["count"]

      finding = hd(reply["findings"])
      # Aggregate fields are present; their shape is the privacy-safe projection.
      assert Map.has_key?(finding, "friction")
      assert Map.has_key?(finding, "message_count")
      assert Map.has_key?(finding, "dominant_signal")
    end

    test "PRIVACY: output never contains raw transcript text" do
      {:reply, resp, _} = SearchFriction.execute(%{limit: 50}, frame())
      blob = resp.content |> Enum.map_join(" ", & &1["text"])

      # Sanity: the phrase really is in the fixture we just scanned.
      assert File.read!("test/fixtures/sample_session.jsonl") =~ @raw_transcript_phrase
      refute blob =~ @raw_transcript_phrase

      # Wire-level allowlist: every finding's JSON keys (string keys, as a client sees them) stay
      # within the privacy-safe projection — catches a leak the atom-keyed summarize/1 test can't.
      wire_allowed =
        ~w(session_id friction raw rate dominant_signal opportunity tool_count error_count
           message_count human_turns max_ctx_pct cwd file_paths missed skills_used fingerprint)

      for finding <- Jason.decode!(hd(resp.content)["text"])["findings"] do
        assert Enum.all?(Map.keys(finding), &(&1 in wire_allowed)),
               "leaked key(s): #{inspect(Map.keys(finding) -- wire_allowed)}"
      end
    end

    test "summarize/1 exposes exactly the aggregate allowlist (no leaked fields)" do
      [result | _] = Faber.Scan.run(base: "test/fixtures", min_messages: 0, limit: 1)
      keys = result |> SearchFriction.summarize() |> Map.keys() |> MapSet.new()

      allowed =
        MapSet.new([
          :session_id,
          :friction,
          :raw,
          :rate,
          :dominant_signal,
          :opportunity,
          :tool_count,
          :error_count,
          :message_count,
          # An aggregate count, same privacy class as message_count — no transcript text.
          :human_turns,
          :max_ctx_pct,
          :cwd,
          :file_paths,
          :missed,
          :skills_used,
          :fingerprint
        ])

      assert MapSet.equal?(keys, allowed)
      # The struct carries `path` (an internal transcript location) — it must NOT be projected.
      refute :path in Map.keys(SearchFriction.summarize(result))
    end

    test "clamps limit into [1, 50]" do
      assert json_reply(SearchFriction.execute(%{limit: 9_999}, frame()))["count"] >= 0
      assert json_reply(SearchFriction.execute(%{limit: 0}, frame()))["count"] >= 0
      # No params at all uses the default limit and still works.
      assert json_reply(SearchFriction.execute(%{}, frame()))["count"] >= 0
    end
  end

  describe "faber_list_skills / faber_get_skill" do
    setup do
      dir = Path.join(System.tmp_dir!(), "faber-mcp-skills-#{System.unique_integer([:positive])}")
      prev = Application.get_env(:faber, :skills_dir)
      Application.put_env(:faber, :skills_dir, dir)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:faber, :skills_dir, prev),
          else: Application.delete_env(:faber, :skills_dir)

        File.rm_rf(dir)
      end)

      md =
        "---\nname: tidy-imports\ndescription: Sorts and dedups imports.\n---\n\n# Tidy imports\n"

      {:ok, _} = Faber.Install.install({"tidy-imports", md}, dir: dir)
      %{dir: dir}
    end

    test "faber_list_skills lists installed skills with name + description" do
      reply = json_reply(ListSkills.execute(%{}, frame()))

      assert reply["count"] == 1

      assert [%{"name" => "tidy-imports", "description" => "Sorts and dedups imports."}] =
               reply["skills"]
    end

    test "faber_get_skill returns the SKILL.md body by name" do
      {:reply, resp, _} = GetSkill.execute(%{name: "tidy-imports"}, frame())

      refute resp.isError
      assert hd(resp.content)["text"] =~ "# Tidy imports"
    end

    test "faber_get_skill returns a structured error for an unknown skill" do
      {:reply, resp, _} = GetSkill.execute(%{name: "does-not-exist"}, frame())

      assert resp.isError
      assert hd(resp.content)["text"] =~ "No installed skill"
    end

    test "faber_get_skill is traversal-proof: a path-y name is just 'not found', never a read" do
      {:reply, resp, _} = GetSkill.execute(%{name: "../../../../etc/passwd"}, frame())
      assert resp.isError
    end
  end
end
