---
scriptorium: true
action: create
title: "Anubis MCP server in a Phoenix app (anubis_mcp 1.6)"
type: solution
domain: claude-elixir-phoenix
tags: [elixir, phoenix, mcp, anubis, hermes, dspy]
---

# Anubis MCP server in a Phoenix app (anubis_mcp 1.6)

Concrete, working integration pattern for adding a **read-only MCP server** to an existing
Phoenix app, distilled from wiring one into Faber. Anubis is the maintained rename of
`hermes_mcp` (which froze at 0.14.1, Aug 2025); use **`{:anubis_mcp, "~> 1.6"}`** (1.6.2 as of
2026-06). The old `hermes_mcp` is dead — don't pin it.

## Minimal wiring (4 pieces)

1. **Tool** = a Component module:

   ```elixir
   defmodule MyApp.Tools.Echo do
     @moduledoc "Echo text back."          # becomes the tool description shown to the LLM
     use Anubis.Server.Component, type: :tool
     alias Anubis.Server.Response

     schema do
       field :text, {:required, :string}, description: "text to echo"
       # optional field: `field :n, :integer, description: "..."` (no {:required, _})
       # NO-PARAM tool needs a valid schema anyway: `schema do %{} end`
     end

     @impl true
     def execute(%{text: text}, frame), do: {:reply, Response.text(Response.tool(), text), frame}
   end
   ```

   Returns: `{:reply, %Response{}, frame}` or `{:error, %Anubis.MCP.Error{}, frame}`.
   `Response.json/2` (JSON body), `Response.structured/2` (+ structured_content),
   `Response.error/2` (sets `isError: true` — the model-visible "tool failed" path).

2. **Server** registers components (give explicit names or it derives `echo` from the module):

   ```elixir
   defmodule MyApp.MCP.Server do
     @version Mix.Project.config()[:version]   # compile-time literal; works in releases
     use Anubis.Server, name: "myapp", version: @version, capabilities: [:tools]
     component MyApp.Tools.Echo, name: "myapp_echo"
     @impl true
     def init(_client_info, frame), do: {:ok, frame}
   end
   ```

   Introspect in tests: `Server.__components__(:tool)` → list of `%Tool{name, description,
   input_schema, ...}`.

3. **Router** mounts the streamable-HTTP plug (no browser pipeline — it speaks JSON-RPC):

   ```elixir
   forward "/mcp", Anubis.Server.Transport.StreamableHTTP.Plug, server: MyApp.MCP.Server
   ```

4. **Supervision** adds the server child; the HTTP listener is the Phoenix endpoint's, the child
   only manages MCP sessions (binds nothing):

   ```elixir
   {MyApp.MCP.Server, transport: :streamable_http}
   ```

## The gotcha that costs a debug cycle: start-gating

`{_, transport: :streamable_http}` does **not** always start. `Anubis.Server.Supervisor.init/1`
calls `should_start?/1`, which for HTTP transports returns `http_server_running?()`:

- true if env `PHX_SERVER` or `ANUBIS_MCP_SERVER` is set, **or**
- `Application.get_env(:phoenix, :serve_endpoints)` is truthy (nil ⇒ treated as true).

Under `mix test` / `mix run` / `iex -S mix`, Phoenix sets `serve_endpoints: **false**`, so the
supervisor returns **`:ignore`** — the child is listed but no process is registered. This is
correct (don't stand up HTTP machinery when nothing serves), but it means:

- A test asserting the supervisor is alive under `mix test` will FAIL. Instead, force-start it:
  `start_supervised!({Server, transport: {:streamable_http, start: true}})` — `start: true`
  overrides the gate and proves the full tree boots.
- It DOES auto-start under `mix phx.server` (sets serve_endpoints) and any boot with
  `PHX_SERVER=true` or endpoint `server: true` (prod releases). Verified: a `mix run` with
  `PHX_SERVER=true` auto-started it (a manual `start_link` then collided `:already_started`).

Find the running supervisor name via `Anubis.Server.Registry.supervisor_name(Server)`
(= `:"Anubis.Elixir.MyApp.MCP.Server.supervisor"`).

## End-to-end test without HTTP plumbing

Unit-test tools by calling `execute(params, Anubis.Server.Frame.new())` directly and decoding
`resp.content` (a list of `%{"type"=>"text","text"=>...}`). For a true HTTP smoke test, stand up a
`Plug.Router` forwarding `/mcp` to the StreamableHTTP plug under `Bandit.start_link`, then drive
`Anubis.Client` (`{:streamable_http, base_url: "http://localhost:PORT"}`, default `mcp_path:
"/mcp"`) — `Anubis.Client.list_tools/1` + `call_tool/3` round-trip cleanly.

## Adapting from enaia (multi-tenant) to local-first

enaia's MCP is multi-tenant (OAuth 2.1, Horde, per-module session-supervisor names to dodge
`:already_started`, ClusterListener). For a **local-first, single-user, localhost** server, drop
ALL of that: no auth, one server, loopback bind (inherit the endpoint's `ip: {127,0,0,1}`).
Privacy boundary for "search" tools: project domain structs onto an explicit aggregate-only
allowlist and unit-test it — never return raw user content.

Related: [[enaia-mcp-server]], [[hermes-mcp-404-session-invalidation]].
