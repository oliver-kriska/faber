# enaia MCP server — prior art for Faber's MCP (extraction + adaptation)

**Date:** 2026-06-25
**Source:** scriptorium KB (the enaia app isn't on disk here). Articles:
`wiki/enaia-mcp-server.md`, `wiki/enaia-mcp-userserver.md`, `wiki/architecture/mcp-server.md`,
`decisions/hermes-mcp-404-session-invalidation.md`, `projects/enaia/architecture/mcp-tools.md`.

## What enaia does
- Library: **`hermes_mcp`** v0.14.1 (neilberkman fork) — the project was later **renamed Hermes →
  Anubis** (`anubis_mcp`). `Hermes.Server` over **streamable HTTP** at `/mcp/*`
  (e.g. `https://enaia.co/mcp/brokers`), secured with **OAuth 2.1 + dynamic client registration**
  (upgraded from a static Bearer token).
- Structure: `Enaia.MCP.Server` (internal) + `Enaia.MCP.UserServer` (end-user) + an admin MCP;
  `Enaia.MCP.UserTool` behaviour with `call/3` + `to_reply/2`; `Enaia.MCP.Registry`
  (session-supervisor adapter); `Enaia.MCP.ClusterListener` (Horde membership sync). Prod runs
  **both** servers; MCP children are **not** env-gated.

## Hard-won lessons (bake into Faber)
1. **Per-module session-supervisor names.** A flat `:session_supervisor` atom made every server
   register the Horde session supervisor under the *same* name → intermittent `:already_started`
   boot crash that masked even the Repo. Fix: `Module.concat(__MODULE__.SessionSupervisor, module)`.
   → Only bites with **multiple** servers. Faber has one, so N/A unless a 2nd is added.
2. **Stale `Mcp-Session-Id` → uninitialized session** (the 404 decision): `maybe_attach_session/3`
   unconditionally created a session for any unknown id, so a resumed/stale id silently became a
   fresh *uninitialized* session (500ms defer, JSON-RPC error). → Test session re-init.
3. **Authz by construction:** conflate `mcp_user` extraction failure at the framing layer (a missing
   auth context never reaches `call/3`), and conflate `unauthorized → not_found` to prevent
   existence leaks. → Faber is single-user localhost, so no authz; but the "fail closed at the
   framing layer" instinct still applies to malformed tool calls.

## Adaptation for Faber (local-first, single-node, single-user)
**Drop:** OAuth 2.1, Horde/clustering, multi-tenant auth, ClusterListener, multiple servers.
**Keep:** `Hermes.Server` + tool-module + thin-adapter pattern; streamable HTTP mounted in
`FaberWeb.Router` at `/mcp`; **localhost bind only**; start under `faber serve` only (mirror
`web_children/1`).
**Tools (read-only, the moat surface):** `faber_search_friction` (aggregates only — never raw
transcripts), `faber_list_skills`, `faber_get_skill`; later `faber_propose_skill` (side-effecting +
costs tokens, opt-in). Lore §4a: engineered descriptions, per-tool char budget, structured errors,
stateless, **isolation/privacy test**.
**Verify before building:** current package name/version (`anubis_mcp` vs `hermes_mcp`); whether
upstream (non-fork) suffices — enaia's fork was for OAuth/cluster features Faber won't use.

Full build steps in `.claude/plans/deferred-features/plan.md` (item 3).
