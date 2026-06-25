defmodule Faber.MCP.ServerTest do
  use ExUnit.Case, async: true

  alias Anubis.Server.Registry
  alias Faber.MCP.Server

  describe "component registration" do
    test "registers exactly the three read-only tools with faber_ names" do
      names = Server.__components__(:tool) |> Enum.map(& &1.name) |> Enum.sort()

      assert names == ["faber_get_skill", "faber_list_skills", "faber_search_friction"]
    end

    test "every registered component carries a non-empty description and input schema" do
      for tool <- Server.__components__(:tool) do
        assert is_binary(tool.description) and tool.description != ""
        assert is_map(tool.input_schema)
      end
    end
  end

  describe "supervision" do
    test "is :ignore'd in test (server: false) — only runs when an HTTP server is up" do
      # Anubis gates start on a running HTTP server (PHX_SERVER / endpoint server: true /
      # :serve_endpoints). In `mix test` none holds, so web_children/1 lists the child but its
      # supervisor returns :ignore — the app boots without standing up the MCP HTTP machinery.
      refute Process.whereis(Registry.supervisor_name(Server)),
             "MCP server should NOT auto-start under `mix test` (server: false)"
    end

    test "boots cleanly (registry, sessions, tools) when forced to start" do
      # `start: true` overrides the HTTP-running gate, so we can prove the full tree — registry,
      # session/task supervisors, base server, transport — starts without crashing. Mirrors what
      # happens under `faber serve` (endpoint server: true).
      pid = start_supervised!({Server, transport: {:streamable_http, start: true}})
      assert is_pid(pid)
      assert Process.alive?(pid)
      assert is_pid(Process.whereis(Registry.supervisor_name(Server)))
    end
  end
end
