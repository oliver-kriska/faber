---
name: anubis-mcp-readonly-phoenix
description: "Expose read-only MCP tools from an existing Phoenix app using anubis_mcp (~> 1.6, the maintained rename of the dead hermes_mcp). Use when adding an MCP server to a Phoenix app for a local-first / single-user / localhost agent integration — tool components, server registration, streamable-HTTP router mount, supervision, and the serve-gating gotcha. Privacy: project domain structs onto an aggregate-only allowlist; never return raw user content."
effort: medium
argument-hint: ""
allowed-tools:
---

# Anubis MCP (read-only) in Phoenix

Concrete wiring for adding a **read-only MCP server** to an existing Phoenix app. Anubis is
the maintained rename of `hermes_mcp` (which froze at 0.14.1, Aug 2025). Use
**`{:anubis_mcp, "~> 1.6"}`** — the old `hermes_mcp` is dead, don't pin it.

## Iron Laws - Never Violate These

1. **Read-only means read-only.** Tools expose query/projection, never mutation. For a
   local-first server: no auth, one server, **loopback bind** (inherit the endpoint's
   `ip: {127,0,0,1}`) — drop all the multi-tenant machinery (OAuth, Horde, cluster listeners).

2. **Project onto an aggregate-only allowlist for any "search" tool — never return raw user
   content.** Map domain structs through an explicit allowlist of safe fields (counts, scores,
   short names) and **unit-test the projection**. This is the privacy boundary.

3. **The HTTP transport is start-gated — don't assume it boots under `mix test`.**
   `should_start?/1` returns `http_server_running?()`, which is false under
   `mix test`/`mix run`/`iex -S mix` (Phoenix sets `serve_endpoints: false`), so the
   supervisor returns `:ignore` and no process registers. Force it in tests with
   `start_supervised!({Server, transport: {:streamable_http, start: true}})`.

4. **Use a compile-time literal for the version** (`@version Mix.Project.config()[:version]`),
   so the server still builds in a release where `Mix` isn't available at runtime.

## Usage

```
# Auto-starts under `mix phx.server` (serve_endpoints) or PHX_SERVER=true / server: true (prod).
# In tests, force-start with transport: {:streamable_http, start: true}.
mix phx.server
```

## Workflow — the 4 pieces

```elixir
# 1. Tool = a Component module. @moduledoc becomes the LLM-visible description.
defmodule MyApp.Tools.Echo do
  @moduledoc "Echo text back."
  use Anubis.Server.Component, type: :tool
  alias Anubis.Server.Response

  schema do
    field :text, {:required, :string}, description: "text to echo"
    # no-param tool still needs a valid schema: `schema do %{} end`
  end

  @impl true
  def execute(%{text: text}, frame), do: {:reply, Response.text(Response.tool(), text), frame}
  # or {:error, %Anubis.MCP.Error{}, frame}. Response.json/2, .structured/2, .error/2 (isError: true)
end

# 2. Server registers components (explicit names, else derived from the module).
defmodule MyApp.MCP.Server do
  @version Mix.Project.config()[:version]   # Law 4 — compile-time literal
  use Anubis.Server, name: "myapp", version: @version, capabilities: [:tools]
  component MyApp.Tools.Echo, name: "myapp_echo"
  @impl true
  def init(_client_info, frame), do: {:ok, frame}
end

# 3. Router mounts the streamable-HTTP plug (JSON-RPC, no browser pipeline).
forward "/mcp", Anubis.Server.Transport.StreamableHTTP.Plug, server: MyApp.MCP.Server

# 4. Supervision — the child only manages MCP sessions; the listener is the Phoenix endpoint's.
{MyApp.MCP.Server, transport: :streamable_http}
```

## Patterns

- **Unit-test tools without HTTP:** call `execute(params, Anubis.Server.Frame.new())` directly
  and decode `resp.content` (a list of `%{"type" => "text", "text" => ...}`). Introspect the
  registry with `Server.__components__(:tool)` → `%Tool{name, description, input_schema}`.
- **True HTTP smoke test:** stand up a `Plug.Router` forwarding `/mcp` to the StreamableHTTP
  plug under `Bandit.start_link`, then drive `Anubis.Client`
  (`{:streamable_http, base_url: "http://localhost:PORT"}`, default `mcp_path: "/mcp"`) —
  `Anubis.Client.list_tools/1` + `call_tool/3` round-trip cleanly.
- **Find the running supervisor name:** `Anubis.Server.Registry.supervisor_name(Server)`
  (= `:"Anubis.Elixir.MyApp.MCP.Server.supervisor"`).

## References

- Faber: `lib/faber/mcp/` (read-only `faber_list_skills` / `faber_get_skill`, aggregate-only).
- Solution note: `.claude/scriptorium/2026-06-25-anubis-mcp-phoenix-integration.md`.
