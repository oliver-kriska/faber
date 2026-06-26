defmodule Faber.MCP.Tools.ProposeSkillTest do
  # async: false — mutates global app config (:mcp_allow_propose, :mcp_scan_opts, :skills_dir).
  # Runs with the Stub LLM (config/test.exs), so it is hermetic — no `claude` call, no tokens.
  use ExUnit.Case, async: false

  alias Anubis.Server.Frame
  alias Faber.MCP.Tools.ProposeSkill

  @raw_transcript_phrase "please add a feature to the parser"

  defp frame, do: Frame.new()

  defp ok_reply({:reply, %{content: [%{"text" => text} | _]} = resp, _frame}) do
    refute resp.isError, "expected a success reply, got an error: #{text}"
    Jason.decode!(text)
  end

  defp error_reply({:reply, %{content: [%{"text" => text} | _]} = resp, _frame}) do
    assert resp.isError, "expected an error reply, got success"
    text
  end

  describe "opt-in gate" do
    setup do
      prev = Application.get_env(:faber, :mcp_allow_propose)
      Application.delete_env(:faber, :mcp_allow_propose)
      on_exit(fn -> if prev, do: Application.put_env(:faber, :mcp_allow_propose, prev) end)
      :ok
    end

    test "disabled by default: returns a structured error explaining how to enable it" do
      msg = error_reply(ProposeSkill.execute(%{rank: 1}, frame()))
      assert msg =~ "mcp_allow_propose"
      assert msg =~ "tokens"
    end
  end

  describe "enabled" do
    setup do
      prev_allow = Application.get_env(:faber, :mcp_allow_propose)
      prev_scan = Application.get_env(:faber, :mcp_scan_opts)
      Application.put_env(:faber, :mcp_allow_propose, true)
      Application.put_env(:faber, :mcp_scan_opts, base: "test/fixtures", min_messages: 0)

      on_exit(fn ->
        restore(:mcp_allow_propose, prev_allow)
        restore(:mcp_scan_opts, prev_scan)
      end)

      :ok
    end

    test "rank 1 (on-stack) proposes + scores and returns the full payload" do
      reply = ok_reply(ProposeSkill.execute(%{rank: 1}, frame()))

      assert is_binary(reply["name"]) and reply["name"] != ""
      assert is_binary(reply["description"])
      assert is_number(reply["composite"])
      assert is_number(reply["threshold"])
      assert is_boolean(reply["passed"])
      assert is_map(reply["dimensions"]) and map_size(reply["dimensions"]) > 0
      assert reply["skill_md"] =~ "name:"
      # No install requested → nothing written.
      assert reply["installed"] == false
    end

    test "rank 2 (off-stack JS session) is gated; force: true bypasses it" do
      msg = error_reply(ProposeSkill.execute(%{rank: 2}, frame()))
      assert msg =~ "stack"

      # force bypasses the stack gate and proceeds to a real proposal.
      reply = ok_reply(ProposeSkill.execute(%{rank: 2, force: true}, frame()))
      assert is_binary(reply["name"])
    end

    test "an out-of-range rank is a clean structured error, not a crash" do
      msg = error_reply(ProposeSkill.execute(%{rank: 999}, frame()))
      assert msg =~ "No friction finding at rank 999"
    end

    test "install: true writes the skill ONLY when it passes the gate" do
      dir =
        Path.join(System.tmp_dir!(), "faber-propose-mcp-#{System.unique_integer([:positive])}")

      prev_dir = Application.get_env(:faber, :skills_dir)
      Application.put_env(:faber, :skills_dir, dir)

      on_exit(fn ->
        restore(:skills_dir, prev_dir)
        File.rm_rf(dir)
      end)

      reply = ok_reply(ProposeSkill.execute(%{rank: 1, install: true}, frame()))

      if reply["passed"] do
        assert is_binary(reply["installed"])
        assert File.exists?(reply["installed"])
        # Provenance marker stamped beside it.
        assert reply["installed"] |> Path.dirname() |> Path.join(".faber.json") |> File.exists?()
      else
        assert reply["installed"] =~ "skipped"
        refute File.exists?(dir)
      end
    end

    test "PRIVACY: the reply never contains raw transcript text or the internal transcript path" do
      {:reply, resp, _} = ProposeSkill.execute(%{rank: 1}, frame())
      blob = resp.content |> Enum.map_join(" ", & &1["text"])

      # Sanity: the phrase really is in the fixture being scanned.
      assert File.read!("test/fixtures/sample_session.jsonl") =~ @raw_transcript_phrase
      refute blob =~ @raw_transcript_phrase

      # The internal transcript path (an internal location the privacy boundary excludes) never leaks.
      refute blob =~ "test/fixtures/sample_session.jsonl"
    end
  end

  defp restore(key, nil), do: Application.delete_env(:faber, key)
  defp restore(key, val), do: Application.put_env(:faber, key, val)
end
