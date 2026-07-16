defmodule Faber.Loop.JournalTest do
  use ExUnit.Case, async: true

  alias Faber.Loop.Journal

  defp entry(fields \\ []) do
    Journal.entry(Keyword.merge([iteration: 1, kept: true, skill: "demo"], fields))
  end

  describe "the format declaration" do
    test "history data, readable at format 1, unstamped entries read as v1" do
      assert Journal.format() == 1
      assert Journal.readable_formats() == [1]
      assert Journal.data_class() == :history
      assert Journal.unstamped() == 1
    end

    test "entry/1 stamps the format it writes" do
      assert entry().format == 1
    end
  end

  describe "read/1" do
    @tag :tmp_dir
    test "round-trips an appended entry", %{tmp_dir: dir} do
      path = Path.join(dir, "results.jsonl")
      :ok = Journal.append(path, entry(description: "d"))

      assert [read] = Journal.read(path)
      assert read["format"] == 1
      assert read["skill"] == "demo"
      assert read["kept"] == true
    end

    test "a missing file reads as no entries" do
      assert Journal.read("/nonexistent/results.jsonl") == []
    end

    @tag :tmp_dir
    test "reads lines written before the format key existed", %{tmp_dir: dir} do
      # THE POINT: journals like this are already on disk — they predate the key, so they are
      # format 1. A reader that demanded `format` would silently empty every existing journal.
      # `unstamped: 1` is what makes this pass. Do not "tighten" it.
      path = Path.join(dir, "results.jsonl")
      File.write!(path, ~s({"iteration":1,"skill":"legacy","kept":true}\n))

      assert [read] = Journal.read(path)
      assert read["skill"] == "legacy"
      refute Map.has_key?(read, "format")
    end

    @tag :tmp_dir
    test "skips a corrupt line rather than failing the whole read", %{tmp_dir: dir} do
      # A truncated append from a crash. This is history: one lost line is a gap in an audit
      # trail, never a reason to take the whole read down.
      path = Path.join(dir, "results.jsonl")
      :ok = Journal.append(path, entry(skill: "before"))
      File.write!(path, "{truncated\n", [:append])
      :ok = Journal.append(path, entry(skill: "after"))

      assert ["before", "after"] = Journal.read(path) |> Enum.map(& &1["skill"])
    end

    @tag :tmp_dir
    test "skips a line stamped with a format this build cannot read", %{tmp_dir: dir} do
      path = Path.join(dir, "results.jsonl")
      :ok = Journal.append(path, entry(skill: "mine"))
      File.write!(path, ~s({"format":99,"skill":"from-future","kept":true}\n), [:append])

      assert ["mine"] = Journal.read(path) |> Enum.map(& &1["skill"])
    end
  end
end
