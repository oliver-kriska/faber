---
scriptorium: true
action: update
title: "ReqLLM"
type: tool
domain: general
tags: [elixir, llm, req, claude, anthropic, ownership-change, agentjido]
---

**Correction (2026-06-18): `req_llm` ownership and API have changed.** The existing KB
entry points at `neilberkman/req_llm` — that is now stale.

The hex package `req_llm` is now published by **`mikehostetler`** from
**`agentjido/req_llm`** (homepage: agentjido.xyz). Same hex name, but a substantially
evolved successor repo with a meaningfully different API surface. It has grown from a small
Req plugin into a ~21-provider / ~1,200-model platform.

- **Current version:** `1.16.0`, released **2026-06-11** (very active; ~16K downloads/30d).
- **Install:** `{:req_llm, "~> 1.6"}`.
- **Verdict:** still **use** — confirmed against Anthropic prompt caching + structured output.

### What changed that matters

- **Structured output:** `ReqLLM.generate_object/4` (NimbleOptions schema or JSON-schema
  map) returns a validated Elixir map directly — no manual parsing. Auto-selects JSON-schema
  mode (`anthropic_beta: ["structured-outputs-2025-11-13"]`) vs strict-tool mode. This means
  **`instructor_ex` is usually unnecessary** alongside it.
- **Prompt caching (Anthropic):** `provider_options: [anthropic_prompt_cache: true,
  anthropic_prompt_cache_ttl: "1h"]`. The lib auto-applies `cache_control` to the last
  system block and to tool definitions.
- **Model specs:** `"anthropic:claude-opus-4-8"`, `"anthropic:claude-sonnet-4-6"`,
  `"anthropic:claude-haiku-4-5"`.

### Migration gotcha

Treat it as a **new library that happens to share the hex name.** Existing Enaia/Virgil
call sites using `ReqLLM.generate_text/3` + `ReqLLM.Response.text/1` should be re-verified
against current hexdocs — the response struct shape may differ across the ownership
transition. The `oliver-kriska/req_llm` fork was tracking neilberkman's repo; reassess
whether that fork is still the right base or whether to move onto agentjido upstream.

_Surfaced while choosing the LLM client for Faber's skill proposer (2026-06-18)._
