---
module: "Faber.Detect / Faber.Adapter / Faber.Scan"
date: "2026-06-26"
problem_type: design_pattern
component: domain_free_engine
symptoms:
  - "stack-specific vocabulary (mix deps/hex, gh pr, plugin skill names, phx|ecto|lv regex) was hardcoded in the supposedly domain-free engine"
  - "a second adapter (faber-python) could supply laws/playbooks/templates + eval, but detection (fingerprint/opportunity/skill-usage) was still Elixir-only"
  - "Scan loaded detect/signatures.yaml into the adapter struct but the scan path never used it"
root_cause: "the engine's detection heuristics were written as literal lists inline; there was no seam for an adapter to override the command/skill vocabulary, so 'domain-free' held for generation/eval but not for detection"
severity: medium
tags: [adapter, domain-free, engine, parity, fallback, contract-versioning, detection, faber-python]
---

# Make a domain-free engine truly domain-free: adapter-overridable vocab with defaults-as-fallback

## Symptoms

Faber's pitch is a *domain-free engine* + *declarative adapters*. That held for generation (laws,
playbooks, templates) and eval (matchers), but **detection** still hardcoded Elixir/plugin vocab in
`lib/faber`: `fingerprint/1` gave maintenance/review bonuses for `mix deps`/`gh pr`; `opportunity/1`
mapped friction to plugin skill names (`verify`/`pr-review`/…) keyed on `mix test`/`gh pr`;
`used_skills/1` scanned text with `~r/(?:phx|ecto|lv):/`. A second adapter (`faber-python`) could not
change any of that, and `Scan.run/1` wasn't even adapter-aware (it loaded `detect/signatures.yaml`
into the struct but ignored it on the scan path).

## Investigation

1. **"Just parameterize the few lists"** — right direction, but the trap is regressing the existing
   adapter. The fix must keep the *adapter-free* path **byte-for-byte identical**.
2. **"empty list ⇒ fall back to defaults"** — rejected. That conflates "adapter omitted this" with
   "this stack legitimately has none" (e.g. a stack with no skill namespaces). It also masks a
   typo'd YAML key behind the default. Chosen rule instead: **`nil` adapter ⇒ engine defaults;
   any adapter present ⇒ its vocab verbatim, empty meaning "none".**

## Root cause

The heuristics were literal inline lists with no override seam. "Domain-free" was true for the stages
that already read adapter files and false for the one stage (detect) whose vocab was still inlined.

## Solution

The reusable pattern (engine stays domain-free; an optional adapter overrides vocab):

1. **Extract the inlined vocab into named default module attrs** — `@default_fingerprint_rules`,
   `@default_opportunity_rules`, `@default_skill_namespaces`. These *are* the generic fallback.
2. **Thread an optional adapter** through the call chain (`Scan.run/1` opts → `score_session/2` →
   `Detect.fingerprint/2` + `opportunity/2`), defaulting to `nil`.
3. **Accessor picks defaults vs adapter by nil, not by emptiness** — pattern-match the struct:

   ```elixir
   defp fingerprint_rules(nil), do: @default_fingerprint_rules
   defp fingerprint_rules(%Adapter{fingerprint_rules: rules}), do: rules   # empty = "none"
   ```

   (Pattern-matching the struct field — not `Map.get/3 || []` — keeps the compiler's struct-field
   checker and makes nil-vs-empty explicit.)
4. **Move the vocab into the adapter pack as declarative data** and bump the contract additively
   (v0.1 → v0.2: new keys all optional, so old packs stay valid). The reference adapter **restates
   its own former defaults**, so selecting it reproduces the engine's old behavior.
5. **Support novel adapter-introduced types safely** — use `Map.update/4` (not `update!`) so a new
   fingerprint type is created on first hit; make tie-break deterministic across novel types
   (`@fixed_order ++ Enum.sort(extra_keys)`).

### Prove parity — and guard against *joint* regression

The migration's danger is regressing the reference adapter. Two complementary assertions:

```elixir
# 1. Divergence guard: reference adapter == adapter-free, across probe sessions (one per rule).
for events <- probes do
  assert Detect.fingerprint(events, ref_adapter) == Detect.fingerprint(events)
  assert Detect.opportunity(events, ref_adapter) == Detect.opportunity(events)
end

# 2. Joint-regression guard: at least one ABSOLUTE snapshot, so both paths breaking
#    identically can't stay green.
assert %{type: "maintenance"} = Detect.fingerprint(mix_deps_probe, ref_adapter)
assert %{missed: ["verify"]}  = Detect.opportunity(verify_loop_probe, ref_adapter)
```

A pure `a == b` equality test is necessary but **not sufficient** — it passes if both sides regress
the same way. Always anchor with at least one absolute snapshot.

## Prevention

- When a component claims to be "domain-free / generic", audit **every** stage for inlined
  domain vocab — the leak hides in the stage nobody parameterized yet.
- Default-selection by `nil`, never by empty collection, when "explicitly empty" is a meaningful
  state.
- Additive contract versioning (all new keys optional) keeps existing packs valid with no migration.
- Equality parity tests need an absolute-snapshot companion to catch joint regressions.

## Result

`faber-python` (a hand-curated second adapter) drives Python-flavored detection/generation with
**zero `lib/faber` diffs** beyond these generic seams — proven by `git diff <phase-0> -- lib/faber/`
being empty. Two adapters, one domain-free engine.
