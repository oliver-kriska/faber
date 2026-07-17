defmodule Faber.MCP.Server do
  @moduledoc """
  Faber's MCP server — exposes mined friction findings and installed skills to a coding agent as
  **read-only** MCP tools over streamable HTTP (mounted at `/mcp` in `FaberWeb.Router`).

  Local-first by construction: it inherits the dashboard endpoint's loopback bind (`127.0.0.1`),
  serves a single user, and carries no auth — so unlike the enaia prior art (multi-tenant, OAuth
  2.1, Horde) this drops all of that. It is started only when the web endpoint is (dev / `faber
  serve`), never for one-shot CLI commands — see `Faber.Application.web_children/1`.

  Tools:

    * `faber_search_friction` — ranked friction findings (**aggregates only**, never raw transcripts)
    * `faber_list_skills`     — installed skills (name + description)
    * `faber_get_skill`       — a skill's full `SKILL.md` body, by name
    * `faber_propose_skill`   — propose + gate (+ optionally install) a skill for a ranked finding
    * `faber_propose_hook`    — propose + gate (+ optionally install) a **hook** for a mined
      frictionless hazard. Its own tool rather than a `kind` param, because it shares no input with
      the one above: that selects by rank in a friction ranking, this by hazard class, and a hazard
      has no friction to rank (see `Faber.MCP.Tools.ProposeHook`).

  The two `propose_*` tools are the **side-effecting** ones (they call an LLM, spending tokens), so
  both are **opt-in**: disabled unless `config :faber, :mcp_allow_propose` is true. The read-only
  three need no opt-in.

  Connect a coding agent with:

      claude mcp add --transport http faber http://localhost:4710/mcp
  """

  # Single source of truth for the version, baked in at compile time (matches mix.exs).
  @version Mix.Project.config()[:version]

  use Anubis.Server,
    name: "faber",
    version: @version,
    capabilities: [:tools]

  alias Faber.MCP.Tools

  # Explicit `faber_`-prefixed names (the macro would otherwise derive bare `search_friction` etc.):
  # the prefix namespaces these among whatever other MCP tools an agent has connected.
  component(Tools.SearchFriction, name: "faber_search_friction")
  component(Tools.ListSkills, name: "faber_list_skills")
  component(Tools.GetSkill, name: "faber_get_skill")
  component(Tools.ProposeSkill, name: "faber_propose_skill")
  component(Tools.ProposeHook, name: "faber_propose_hook")

  @impl true
  def init(_client_info, frame), do: {:ok, frame}
end
