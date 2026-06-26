---
scriptorium: true
action: create
title: "Domain-free engine via adapter-overridable vocab with defaults-as-fallback"
type: pattern
domain: general
tags: [architecture, plugin-engine, adapter, domain-free, parity-test, contract-versioning, extensibility]
---

# Domain-free engine via adapter-overridable vocab with defaults-as-fallback

A reusable pattern for any **engine + pluggable-pack** architecture (linters with rule packs, codegen
with stack adapters, scoring/detection engines with domain configs) where the engine must stay
generic but ship with sensible built-in behavior. Found making Faber's detection stage domain-free so
a second adapter (`faber-python`) could drive it with zero engine diffs; it generalizes.

## The problem it solves

"Generic engine + declarative packs" usually holds for *most* stages but leaks in the one stage
nobody parameterized — its domain vocabulary stays inlined as literal lists. You discover this when a
second pack can override everything *except* that stage.

## The pattern

1. **Extract inlined vocab into named default module attrs** — these *are* the generic fallback, not
   a separate code path. (`@default_fingerprint_rules`, etc.)
2. **Thread an optional pack/adapter** through the call chain, defaulting to `nil`.
3. **Select defaults vs pack by `nil`, NOT by emptiness.** An empty collection from a present pack
   means "this domain has none" — a real state distinct from "pack omitted this". Pattern-match the
   struct field rather than `Map.get/3 || []` (keeps the compiler's field checker; makes nil-vs-empty
   explicit):

   ```elixir
   defp rules(nil), do: @default_rules
   defp rules(%Pack{rules: rules}), do: rules   # [] = "none for this domain"
   ```
4. **Move the vocab into the pack as declarative data; version the contract additively** (new keys
   optional ⇒ old packs stay valid, no migration). The **reference pack restates its own former
   defaults**, so selecting it reproduces the engine's prior behavior exactly.
5. **Support pack-introduced novel types safely** — `Map.update/4` (create-on-first-hit) not
   `update!`; deterministic ordering across novel keys (`@fixed_order ++ Enum.sort(extra)`).

## Prove parity — and guard joint regression

Migrating defaults into the reference pack risks regressing it. Two complementary assertions:

- **Divergence guard:** `engine(input, ref_pack) == engine(input)` across probe inputs (one per rule).
- **Joint-regression guard:** at least one **absolute snapshot** (`assert %{type: "maintenance"} =
  engine(probe, ref_pack)`). A pure `a == b` equality passes if *both* sides regress identically —
  always anchor with a snapshot.

## Why it matters

The payoff is a falsifiable claim: a new pack required **zero engine diffs** (provable by
`git diff <baseline> -- <engine-dir>` being empty). That's the difference between "we have a plugin
system" and "the engine is genuinely domain-free."

## Anti-patterns

- Default-selection by empty collection (conflates "omitted" with "explicitly none"; masks typo'd keys).
- Equality-only parity tests (blind to joint regression).
- Breaking contract changes when additive optional keys would do.

Related: [[Eval proxies need structural renderer guarantees, not metric-gaming]] (sibling Faber
quality-gate pattern), [[cross-agent-format-normalization-boundary]] (another "keep the core generic,
push specifics to the edge" boundary).
