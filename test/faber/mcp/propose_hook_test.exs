defmodule Faber.MCP.Tools.ProposeHookTest do
  @moduledoc """
  The MCP hook tool. Mirrors `Faber.MCP.Tools.ProposeSkillTest`, because the two must refuse in the
  same words at the same boundaries — a surface that quietly disagrees with the CLI about what is
  safe to write is the drift these tests exist to catch.

  Hermetic: the Stub LLM (config/test.exs), fixtures for a corpus, tmp dirs for both write targets.
  """
  # async: false — mutates global app config (:mcp_allow_propose, :mcp_scan_opts, :hooks_dir).
  use ExUnit.Case, async: false

  alias Anubis.Server.Frame
  alias Faber.MCP.Tools.ProposeHook

  @raw_transcript_phrase "add the changeset validation and run the gate"

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

    test "disabled by default, like its skill sibling — it spends tokens too" do
      msg = error_reply(ProposeHook.execute(%{}, frame()))
      assert msg =~ "mcp_allow_propose"
      assert msg =~ "tokens"
    end
  end

  describe "enabled" do
    setup %{tmp_dir: tmp_dir} do
      prev = %{
        allow: Application.get_env(:faber, :mcp_allow_propose),
        scan: Application.get_env(:faber, :mcp_scan_opts),
        hooks: Application.get_env(:faber, :hooks_dir),
        settings: Application.get_env(:faber, :settings_path)
      }

      Application.put_env(:faber, :mcp_allow_propose, true)
      Application.put_env(:faber, :mcp_scan_opts, base: "test/fixtures", min_messages: 0)
      Application.put_env(:faber, :hooks_dir, Path.join(tmp_dir, "faber-hooks"))
      Application.put_env(:faber, :settings_path, Path.join(tmp_dir, "settings.json"))

      on_exit(fn ->
        restore(:mcp_allow_propose, prev.allow)
        restore(:mcp_scan_opts, prev.scan)
        restore(:hooks_dir, prev.hooks)
        restore(:settings_path, prev.settings)
      end)

      :ok
    end

    @tag :tmp_dir
    test "proposes + scores a hook for the seeded hazard, writing nothing" do
      reply = ok_reply(ProposeHook.execute(%{hazard: "pipe_masks_exit"}, frame()))

      assert reply["hazard"] == "pipe_masks_exit"
      assert reply["occurrences"] == 1
      assert is_binary(reply["name"]) and reply["name"] != ""

      # The pointer the hook will be installed under — the part Claude Code actually reads.
      assert reply["event"] == "PreToolUse"
      assert reply["matcher"] == "Bash"

      assert is_number(reply["composite"])
      assert is_boolean(reply["passed"])
      assert is_map(reply["dimensions"]) and map_size(reply["dimensions"]) > 0

      # Scored by the HOOK set, not the skill set — the skill dimensions would fail every hook
      # written, and their names are how you can tell which gate ran.
      assert Map.has_key?(reply["dimensions"], "safety")
      refute Map.has_key?(reply["dimensions"], "specificity_ratio")

      # The artifact is a script, not a document.
      assert reply["script"] =~ "#!/usr/bin/env bash"

      # No install requested → nothing written.
      assert reply["installed"] == false
    end

    @tag :tmp_dir
    test "the hazard defaults, so the tool is callable with no arguments at all" do
      reply = ok_reply(ProposeHook.execute(%{}, frame()))
      assert reply["hazard"] == "pipe_masks_exit"
    end

    @tag :tmp_dir
    test "install: true writes the script AND the pointer", ctx do
      reply = ok_reply(ProposeHook.execute(%{hazard: "pipe_masks_exit", install: true}, frame()))

      if reply["passed"] do
        assert %{"script" => script, "settings" => settings} = reply["installed"]
        assert File.exists?(script)
        # Provenance, like every Faber-installed artifact.
        assert script |> Path.dirname() |> Path.join(".faber.json") |> File.exists?()

        assert [%{"hooks" => [%{"command" => ^script}]}] =
                 settings |> File.read!() |> Jason.decode!() |> get_in(["hooks", "PreToolUse"])
      else
        assert reply["installed"] =~ "skipped"
        refute File.exists?(Path.join(ctx.tmp_dir, "settings.json"))
      end
    end

    @tag :tmp_dir
    test "an unknown hazard class says what a clean scan does NOT mean" do
      msg = error_reply(ProposeHook.execute(%{hazard: "no_such_class"}, frame()))

      assert msg =~ "No session in this scan carries a `no_such_class` hazard"
      assert msg =~ "Known hazard classes: pipe_masks_exit"
      assert msg =~ "ONE class of frictionless hazard today"
    end

    @tag :tmp_dir
    test "PRIVACY: the reply carries no raw transcript text" do
      {:reply, resp, _} = ProposeHook.execute(%{hazard: "pipe_masks_exit"}, frame())
      blob = resp.content |> Enum.map_join(" ", & &1["text"])

      # Sanity: the phrase really is in the fixture being scanned.
      assert File.read!("test/fixtures/hazard_session.jsonl") =~ @raw_transcript_phrase
      refute blob =~ @raw_transcript_phrase
      refute blob =~ "test/fixtures/hazard_session.jsonl"

      # The one thing that DOES cross is the hazard's evidence — the command itself. That is the
      # point of asking for a hook, and it is bounded to that command.
      assert blob =~ "mix verify | tail -5"
    end
  end

  defp restore(key, nil), do: Application.delete_env(:faber, key)
  defp restore(key, val), do: Application.put_env(:faber, key, val)
end
