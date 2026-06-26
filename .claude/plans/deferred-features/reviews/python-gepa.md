# Code Review — Python GEPA optimizer (`optimize` command)

**Range:** `06248b5^..HEAD` (subject commit `1b97fe2 feat(optimize): GEPA sidecar seam`)
**Scope:** `python/faber_eval/optimize.py` (new), `cli.py`, `pyproject.toml`,
`tests/test_optimize.py`, `tests/test_roundtrip.py`; cross-checked `scorer.py` and
`lib/faber/optimize.ex`.
**Reviewer note:** dspy is intentionally NOT installed; the live path is the explicitly
unvalidated, opt-in-to-spend surface. Findings below treat `_run_gepa_live` as
risk-flagging only, per the WHY-CONTEXT.

**Verdict: APPROVE WITH FIXES.** The stdlib-only common path is correct, hermetic, and
well-tested; the capability gate is sound (no false "available"); the contract change is
safe for the Elixir seam. There is **one real BLOCKER**: `metric_feedback` reads the wrong
keys off the scorer's dimension shape, so the "failed checks" half of the reflective signal
is silently dropped — and no test catches it because no test asserts the suffix.

---

## BLOCKER

### B1 — `metric_feedback` reads the wrong dimension shape; failed-check feedback is always empty
`python/faber_eval/optimize.py:92,97`

```python
dims = result.get("dimensions", {})          # values are dicts with keys: dimension, score, passed, failed, total, ASSERTIONS
...
failed = [c.get("name", "?") for c in dim.get("checks", []) if not c.get("passed", True)]
```

`score_skill` returns each dimension as (`scorer.py:188-195`):

```python
{"dimension": name, "score": ..., "passed": int, "failed": int, "total": int, "assertions": [...]}
```

and each assertion item is (`scorer.py:177-185`):

```python
{"id": ..., "check_type": ..., "passed": bool, "evidence": ..., "weight": ...}
```

So `dim.get("checks", [])` is **always `[]`** (the key is `assertions`, not `checks`), and
even if it resolved, the item key is `check_type`, not `name`. The
` — failed: ...` suffix is therefore **never** emitted. Verified empirically against the
BAD_SKILL fixture:

```
Composite score: 0.292. Weakest dimensions first:
- completeness: 0.000      # <- no "— failed: ..." despite every check failing
- clarity: 0.000
...
Has any failed: suffix? False
```

Impact: the module docstring and `metric_feedback`'s own docstring both sell "names …
**failed checks** … so a reflective optimizer knows *what* to fix" as the core value of the
metric. That half of the signal is silently missing. The dimension *scores* still rank
correctly, so the composite and weakest-dim ordering work — which is exactly why every test
still passes. This degrades GEPA's reflective credit assignment to "which dimension is
weak" without "which specific check failed," materially weakening the paid path it's meant
to drive. (`# pragma: no cover` on `_run_gepa_live` doesn't save this — `metric_feedback`
is the *tested* surface, and the test asserts only `"- "` is present, not the suffix.)

**Fix:**

```python
ranked = sorted(dims.items(), key=lambda kv: kv[1].get("score", 0.0))
lines = [f"Composite score: {composite:.3f}. Weakest dimensions first:"]
for name, dim in ranked:
    failed = [
        a.get("check_type", "?")
        for a in dim.get("assertions", [])
        if not a.get("passed", True)
    ]
    suffix = f" — failed: {', '.join(failed)}" if failed else ""
    lines.append(f"- {name}: {dim.get('score', 0.0):.3f}{suffix}")
```

And add a regression test asserting the suffix is present for BAD_SKILL, e.g.
`self.assertIn("— failed:", feedback)` in `MetricFeedbackTests` (see W3).

---

## WARNINGS

### W1 — `_run_gepa_live`: several dspy.GEPA API calls are likely wrong for dspy>=2.5 (unvalidated path)
`python/faber_eval/optimize.py:189-200`

Flagged as risks, not blocking (this is the opt-in-to-spend surface, correctly
`# pragma: no cover`). For when someone enables it:

1. **`dspy.GEPA(metric=..., max_metric_calls=rollouts)` (`:194`)** — current dspy `GEPA`
   commonly requires a **reflection LM** argument (e.g. `reflection_lm=...`) in addition to
   `metric`; the budget kwarg has appeared as `max_full_evals` / `auto` / `max_metric_calls`
   across versions. There is a real chance the constructor raises `TypeError` on the very
   first live run. The pinned floor `dspy>=2.5` (pyproject) is also broad — GEPA's public
   API stabilized later in the 2.5/2.6 line; an exact pin or a documented "tested against
   X.Y" note would de-risk.
2. **Metric signature (`:189`)** — `def metric(gold, pred, trace=None, pred_name=None,
   pred_trace=None)` returning `dspy.Prediction(score=..., feedback=...)` matches the GEPA
   feedback-metric convention reasonably, but the positional order and the
   `dspy.Prediction` (vs a `ScoreWithFeedback`/`dspy.Prediction(score=, feedback=)`) return
   contract should be confirmed against the installed version.
3. **`compile(program, trainset=[seed], valset=[seed])` (`:195`)** — passing the single seed
   as both train and val means GEPA optimizes and validates on the same one example; that is
   a degenerate setup (overfits trivially, no held-out signal). Plausible as a smoke wiring
   but not a meaningful optimization; worth a comment or a real valset when enabled.
4. **`compiled(request="improve this skill").skill_md` (`:197`)** — assumes the compiled
   program is directly callable and exposes `.skill_md`; fine if `dspy.Predict` semantics
   hold, but coupled to (1)-(3).

These are correctly framed in the docstring as "exact dspy.GEPA API may differ … confirm
against the installed version." No change required now; recommend tightening the
`dspy>=2.5` pin and adding a one-line "validate constructor kwargs first" reminder.

### W2 — `metric_feedback` will KeyError on a malformed scorer result (`composite` missing)
`python/faber_eval/optimize.py:91`

```python
composite = result["composite"]
```

Everywhere else in the function uses `.get(...)` defensively (`dimensions`, per-dim
`score`, `checks`). `score_skill` always returns `composite`, so this is safe in practice —
but the asymmetry is a latent footgun if the scorer contract ever changes, and a raised
`KeyError` here would only be caught at the `run` boundary if `metric_feedback` is called
*inside* the runner (it is, in `_run_gepa_live`). Low severity; consider
`result.get("composite", 0.0)` for consistency. Not blocking.

### W3 — Test gap: nothing asserts the failed-check suffix (masks B1)
`python/tests/test_optimize.py:81-84`

```python
def test_feedback_names_weak_dimensions(self):
    _, feedback = metric_feedback(BAD_SKILL, None)
    self.assertIn("Composite score", feedback)
    self.assertIn("- ", feedback)
```

This passes against the buggy code because it only checks for a bullet line, never the
` — failed:` suffix. That is precisely why B1 shipped green. After fixing B1, add:

```python
self.assertIn("— failed:", feedback)   # the reflective "what to fix" signal
```

Otherwise test coverage of `metric_feedback` is good (good > bad ordering is asserted).

---

## SUGGESTIONS

### S1 — `optimize.py` uses PEP 604 (`dict | None`) in a real signature without `from __future__ import annotations`
`python/faber_eval/optimize.py:83` (and the `tuple[float, str]` return)

`scorer.py:15` opens with `from __future__ import annotations`; `optimize.py` does not.
On `requires-python = ">=3.11"` this evaluates fine at runtime (PEP 604 is 3.10+), so it's
**not a bug** — purely a consistency nit. Adding the `__future__` import would match the
sibling module and make annotations cost-free strings.

### S2 — `clamp_rollouts` is correct and robust — no action
`python/faber_eval/optimize.py:72-80`. Bounds `[1, MAX_ROLLOUTS]` are right; `None`/`{}` →
`DEFAULT_ROLLOUTS`; non-dict budget → default; `int("lots")` → `ValueError` → default;
`0`/`-5` → floored to 1; `10_000` → capped at 40. Tests cover all of these. Note: `int()`
of a float like `3.9` truncates to `3` silently — acceptable for a budget knob.

### S3 — `run` swallows the eval_def into the runner but `_run_gepa_live` re-derives baseline via `metric_feedback`
Minor: `run` computes nothing with `eval_def` itself; it threads it to the runner, and
`_run_gepa_live` calls `metric_feedback(skill_md, eval_def)` twice more for baseline/best.
Fine and intentional (keeps `run` engine-agnostic). No change.

---

## Evaluation checklist (per the brief)

1. **Stdlib-only common path — VERIFIED.** `optimize.py` top-level imports are
   `importlib.util`, `os`, `faber_eval.__version__`, and `scorer` symbols — all stdlib /
   in-package. `import dspy` is the **first line inside `_run_gepa_live`** (`:179`), reached
   only after the capability gate passes. `cli.py` imports `optimize` as a module — no dspy
   pulled. Confirmed by the hermetic test suite (41 tests, no dspy installed) passing.
2. **Capability gate — SOUND, no false "available".** `dspy_available()` uses
   `find_spec` (no import side effects); `api_key_present` truthy-checks
   `ANTHROPIC/OPENAI/GEMINI` keys; `unavailable_reason` returns non-None unless **both**
   hold, and `run` only sets `runner = _run_gepa_live` after `reason is None`. An empty-key
   env (`""`) is falsy → correctly "no key." No path triggers a paid call without both dspy
   and a key. The roundtrip test even strips keys to keep the gate deterministic on dev
   boxes.
3. **Metric adapter — BROKEN (B1).** Uses `score_skill` correctly for the composite and
   weakest-dim ranking, but the failed-check enumeration reads `checks`/`name` instead of
   `assertions`/`check_type`, so that signal is always empty.
4. **Budget guardrail — CORRECT (S2).** Handles garbage, None, non-dict, out-of-range.
5. **`run` orchestration — CORRECT.** Missing `skill_md` → `status:error` with `"skill_md"`
   in message; runner exception → caught (`BLE001`-justified broad except) →
   `status:error`; eval resolution (`eval` > `eval_set:"full"`→FULL_EVAL >
   None→DEFAULT_EVAL) + `inject_refs` mirrors the `score` command exactly; `inject_refs`
   correctly handles both the bare-dict FULL_EVAL and a `{"dimensions": ...}` wrapper
   (verified). Result shaping rounds to 4dp and sets `improved` on strict `>`.
6. **`_run_gepa_live` — UNVALIDATED, risks noted (W1).** Constructor kwargs, budget kwarg
   name, and same-example train==val are the most likely failure points; correctly
   `# pragma: no cover` and documented as confirm-on-enable.
7. **Test quality — GOOD with one gap (W3).** Orchestration, gate, clamp, shaping, and
   eval-set threading are all exercised with an injected fake runner; dspy is never
   imported; the `not_implemented` and `error` contracts are asserted (including
   empty-stdin → error in roundtrip). Gap: the failed-check suffix is unasserted, which is
   what let B1 ship.
8. **Contract change — SAFE for the Elixir seam.** `lib/faber/optimize.ex:64-81` matches on
   `status` `ok` / `not_implemented` / `error` and reads `result` / `reason` / `error` — it
   **never** referenced `echo`, so removing it breaks nothing. Adding `skill_md` validation
   is upstream of the seam (the seam always sends `"skill_md"`). Empty stdin now yields
   `status:error` instead of an `echo`-bearing `not_implemented`; the seam maps that to
   `{:error, ...}`, which is acceptable (it only sends well-formed requests). `version` is
   still present on every branch.
