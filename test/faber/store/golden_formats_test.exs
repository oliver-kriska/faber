defmodule Faber.Store.GoldenFormatsTest do
  @moduledoc """
  The frozen on-disk artifacts in `test/support/fixtures/formats/` must still read.

  These tests are the teeth on those files. A hand-written assertion that "v1 parses" tests the
  parser; a frozen v1 *file* tests the contract. See the fixtures' README for how each was captured
  and why regenerating them to make a test pass defeats the entire point.
  """
  # `async: false`, like `Faber.ProposalStoreTest` and for the same reason: pointing the store at a
  # fixture dir means `Application.put_env(:faber, :proposals_dir, …)`, which is global. Run async
  # and a concurrent test (the dashboard's, which renders whatever the store lists) sees this
  # fixture's proposal and fails on it.
  use ExUnit.Case, async: false

  alias Faber.{Install, Proposal}

  @fixtures Path.expand("../../support/fixtures/formats", __DIR__)

  defp fixture(name), do: @fixtures |> Path.join(name) |> File.read!()

  describe "proposal-v1.json — a real format-1 record from the format-1 encoder" do
    setup %{tmp_dir: dir} do
      # Drop the frozen v1 file into a store dir under the name the store globs for, then read it
      # back through the CURRENT reader. This is the exact motion that broke: v2 ships, v1 records
      # are still on disk, and `list/1` must still find them.
      raw = fixture("proposal-v1.json")
      id = raw |> Jason.decode!() |> Map.fetch!("id")
      File.write!(Path.join(dir, "#{id}.json"), raw)

      Application.put_env(:faber, :proposals_dir, dir)
      Application.put_env(:faber, :proposal_store, true)
      on_exit(fn -> Application.delete_env(:faber, :proposals_dir) end)

      %{id: id}
    end

    @tag :tmp_dir
    test "the current reader still lists it", %{id: id} do
      assert [record] = Proposal.Store.list()
      assert record.id == id
      assert record.name == "investigate-retry-loops"
      assert record.adapter == "faber-elixir"
      assert record.md =~ "# Investigate Retry Loops"
    end

    @tag :tmp_dir
    test "its eval survives the read (this is the paid part), normalized to atom keys" do
      # JSON has no atoms, so the store maps allowlisted eval keys back so that `put/2` and
      # `latest/1` speak the same shape. A v1 record on disk must get that same treatment — the
      # normalization is a property of the reader, not of the format it happens to be reading.
      assert [%{eval: eval}] = Proposal.Store.list()
      assert eval.composite == 0.83
      assert eval.passed == true

      # Unallowlisted keys keep their strings rather than being dropped: an unknown score is still
      # information the user paid for.
      assert eval.dimensions == %{"safety" => %{"score" => 1.0}}
    end

    @tag :tmp_dir
    test "v2-only fields are carried forward, not left nil" do
      # A v1 record has NO `outcome` and NO `source_sessions` keys — both arrived with format 2.
      # The reader must age it forward into a usable v2-shaped record rather than hand back holes.
      refute Map.has_key?(Jason.decode!(fixture("proposal-v1.json")), "outcome")
      refute Map.has_key?(Jason.decode!(fixture("proposal-v1.json")), "source_sessions")

      assert [record] = Proposal.Store.list()
      assert record.outcome == :single
      assert record.source_sessions == ["sess-v1-golden"]
    end

    @tag :tmp_dir
    test "it is found by its session, not only by a full listing" do
      assert %{name: "investigate-retry-loops"} = Proposal.Store.latest("sess-v1-golden")
    end
  end

  describe "marker-v0.json — a provenance marker from before the format key existed" do
    @tag :tmp_dir
    test "the skill stays Faber's, with its provenance intact", %{tmp_dir: dir} do
      # Markers in this shape are on real disks. If this test fails, every skill Faber ever
      # installed has just been disowned: dropped from the cross-agent pointer, the MCP listing,
      # and the dashboard's already-installed badge. `unstamped: 1` is what holds it.
      skill_dir = Path.join(dir, "investigate-retry-loops")
      File.mkdir_p!(skill_dir)

      File.write!(
        Path.join(skill_dir, "SKILL.md"),
        "---\nname: investigate-retry-loops\ndescription: Investigate repeated failing commands.\n---\n"
      )

      File.write!(Path.join(skill_dir, ".faber.json"), fixture("marker-v0.json"))
      path = Path.join(skill_dir, "SKILL.md")

      refute Map.has_key?(Jason.decode!(fixture("marker-v0.json")), "format")

      assert [%{name: "investigate-retry-loops"}] = Install.list_faber_installed(dir)
      assert Install.provenance(path)["source_session"] == "sess-abc123"
      assert Install.provenance(path)["adapter"] == "faber-elixir"
      assert Install.installed_at(path) == ~U[2026-06-25 09:14:03.221374Z]
    end
  end
end
