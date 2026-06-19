defmodule Faber.Ingest.FormatTest do
  use ExUnit.Case, async: true

  alias Faber.Ingest
  alias Faber.Ingest.{Event, Format}

  # A second format behind the seam — proves Ingest is agent-agnostic without needing a real
  # Codex/OpenCode spec. Treats each line as a bare "role: text" record.
  defmodule FakeFormat do
    @behaviour Faber.Ingest.Format

    @impl true
    def default_base, do: "/tmp/fake-agent"

    @impl true
    def discover(base), do: [Path.join(base, "session.log")]

    @impl true
    def stream_file!(_path), do: [{:ok, normalize(%{"role" => "user", "text" => "hi from fake"})}]

    @impl true
    def normalize(%{"role" => role, "text" => text}) do
      %Event{type: String.to_existing_atom(role), role: role, text: text, raw: %{}}
    end
  end

  describe "resolve/1" do
    test "defaults to the Claude format" do
      assert Format.resolve() == Faber.Ingest.Format.Claude
      assert Format.resolve(format: :claude) == Faber.Ingest.Format.Claude
    end

    test "accepts a module implementing the behaviour" do
      assert Format.resolve(format: FakeFormat) == FakeFormat
    end

    test "raises on an unknown / not-yet-shipped alias" do
      assert_raise ArgumentError, ~r/unknown ingest format/, fn ->
        Format.resolve(format: :codex)
      end
    end
  end

  describe "Ingest delegates to the resolved format" do
    test "discover uses the format's default_base and glob" do
      assert Ingest.discover(format: FakeFormat) == ["/tmp/fake-agent/session.log"]
      assert Ingest.discover(format: FakeFormat, base: "/custom") == ["/custom/session.log"]
    end

    test "default_base reflects the active format" do
      assert Ingest.default_base(format: FakeFormat) == "/tmp/fake-agent"
    end

    test "parse_file streams the format's normalized events" do
      {events, errors} = Ingest.parse_file("ignored", format: FakeFormat)
      assert errors == []
      assert [%Event{text: "hi from fake", type: :user}] = events
    end
  end
end
