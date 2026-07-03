defmodule Faber.IngestTest do
  use ExUnit.Case, async: true

  alias Faber.Ingest
  alias Faber.Ingest.Event

  @fixtures Path.expand("../fixtures", __DIR__)

  defp fixture(name), do: Path.join(@fixtures, name)

  describe "discover/1" do
    test "expands ~ and globs *.jsonl (returns a list)" do
      assert is_list(Ingest.discover())
      # The fixtures dir, globbed directly, finds our sample files.
      found = Path.wildcard(Path.join(@fixtures, "**/*.jsonl"))
      assert fixture("sample_session.jsonl") in found
    end
  end

  describe "parse_file/1" do
    test "normalizes every line of a real-shaped transcript" do
      {events, errors} = Ingest.parse_file(fixture("sample_session.jsonl"))

      assert errors == []
      assert length(events) == 12
      assert Enum.all?(events, &match?(%Event{}, &1))
    end

    test "extracts text, tool_uses, tool_results, and types" do
      {events, _} = Ingest.parse_file(fixture("sample_session.jsonl"))
      [first | _] = events

      assert first.type == :user
      assert first.role == "user"
      assert first.text == "please add a feature to the parser"
      assert Event.human_turn?(first)
      assert %DateTime{} = first.timestamp

      assistant = Enum.find(events, &(&1.uuid == "a1"))
      assert assistant.type == :assistant
      # thinking blocks are ignored; text is concatenated
      assert assistant.text == "ok, running tests"
      assert [%{name: "Bash", input: %{"command" => "mix test foo"}}] = assistant.tool_uses

      err_result = Enum.find(events, &(&1.uuid == "u2"))
      assert [%{tool_use_id: "t1", is_error: true}] = err_result.tool_results
      assert err_result.text == nil
      refute Event.human_turn?(err_result)
    end

    test "tolerates malformed lines, surfacing them as errors" do
      {events, errors} = Ingest.parse_file(fixture("malformed_session.jsonl"))

      assert length(events) == 2
      assert length(errors) == 1
      assert [%{line: _, reason: _}] = errors
    end

    @tag :tmp_dir
    test "a valid-JSON wrong-shape line degrades to an inert event, not a crash", %{tmp_dir: dir} do
      path = Path.join(dir, "shapes.jsonl")

      File.write!(
        path,
        ~s({"type":"user","message":42}\n) <>
          ~s({"type":"user","message":"just a string"}\n) <>
          ~s({"type":"user","message":{"role":"user","content":"ok"}}\n)
      )

      {events, errors} = Ingest.parse_file(path)

      assert errors == []
      assert [wrong_num, wrong_str, good] = events
      assert wrong_num.role == nil and wrong_num.tool_uses == []
      assert wrong_str.role == nil
      assert good.text == "ok"
    end
  end

  describe "normalize/1" do
    test "decodes with string keys (no atom creation from transcript data)" do
      event = Ingest.normalize(%{"type" => "user", "message" => %{"content" => "hi"}})
      assert event.type == :user
      assert event.text == "hi"
      assert event.raw["type"] == "user"
    end

    test "a non-map message degrades to an inert event (untrusted JSON shape)" do
      event = Ingest.normalize(%{"type" => "user", "message" => 42})

      assert event.type == :user
      assert event.role == nil
      assert event.text == nil
      assert event.tool_uses == []
      assert event.tool_results == []
    end

    test "maps unknown internal types to :other" do
      assert Ingest.normalize(%{"type" => "file-history-snapshot"}).type == :other
    end
  end
end
