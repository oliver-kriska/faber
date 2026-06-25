"""GEPA optimizer for SKILL.md documents — the heavy, optional, post-v1 engine.

Optimizes a SKILL.md to maximize Faber's existing eval matchers (``scorer.score_skill``) via
reflective prompt evolution (``dspy.GEPA``). Heavy and OPTIONAL: it needs the ``gepa`` extra
(``dspy``) installed **and** a provider API key. When either is absent the ``optimize`` command
degrades to ``status: "not_implemented"`` with a precise reason — the v1 boundary stays
stdlib-only, and the Elixir keyless reflective loop (``Faber.Optimize.reflect`` / ``Faber.Loop``)
covers v1 self-improvement.

Design — what's tested vs. what isn't:

* Everything Faber owns is pure and unit-tested with a *fake* runner, so no dspy install and no
  token spend are needed to exercise it: capability detection (``unavailable_reason``), the
  eval-matcher metric adapter (``metric_feedback`` — a composite score plus textual feedback drawn
  from the weakest dimensions, which is the signal GEPA mutates on), the cost guardrail
  (``clamp_rollouts``), and the orchestration/result-shaping in ``run``.
* ``_run_gepa_live`` is the ONLY surface that isn't unit-tested: it drives a paid provider through
  dspy, so it is import-guarded, marked ``# pragma: no cover``, and **unvalidated until you opt in
  to spend**. Validate it via the Elixir ``:live_api`` integration test once you decide GEPA is
  worth the cost over the keyless reflective loop (see
  ``.claude/research/2026-06-23-gepa-reflective-loop-decision.md``).
"""

from __future__ import annotations

import importlib.util
import os

from faber_eval import __version__
from faber_eval.scorer import FULL_EVAL, inject_refs, score_skill

# Cost guardrails. GEPA spends real provider tokens per rollout (metric call), so cap aggressively
# by default — this is an exploratory, post-v1 engine, not a hot path.
DEFAULT_ROLLOUTS = 8
MAX_ROLLOUTS = 40

# Provider keys dspy can pick up. Presence is necessary (not sufficient) to run GEPA live.
_KEY_ENV_VARS = ("ANTHROPIC_API_KEY", "OPENAI_API_KEY", "GEMINI_API_KEY")


def dspy_available() -> bool:
    """True if the optional ``dspy`` dependency (the ``gepa`` extra) is importable."""
    return importlib.util.find_spec("dspy") is not None


def api_key_present(env=None) -> bool:
    """True if a provider API key dspy could use is set in the environment."""
    env = os.environ if env is None else env
    return any(env.get(var) for var in _KEY_ENV_VARS)


def unavailable_reason(env=None, *, has_dspy=None, has_key=None):
    """Why GEPA can't run live, as a human-readable string — or ``None`` if it can.

    ``has_dspy`` / ``has_key`` default to real detection but are injectable so the gate is testable
    without installing dspy or setting a key.
    """
    has_dspy = dspy_available() if has_dspy is None else has_dspy
    has_key = api_key_present(env) if has_key is None else has_key

    if not has_dspy:
        return (
            "dspy not installed — install the 'gepa' extra "
            "(e.g. `uv pip install -e 'python/[gepa]'`) to enable the GEPA optimizer"
        )
    if not has_key:
        return (
            "no provider API key in the environment "
            f"(set one of {', '.join(_KEY_ENV_VARS)}) — GEPA needs a paid LM"
        )
    return None


def clamp_rollouts(budget) -> int:
    """Resolve and clamp the rollout (metric-call) budget into ``[1, MAX_ROLLOUTS]``."""
    requested = DEFAULT_ROLLOUTS
    if isinstance(budget, dict) and budget.get("rollouts") is not None:
        try:
            requested = int(budget["rollouts"])
        except (TypeError, ValueError):
            requested = DEFAULT_ROLLOUTS
    return max(1, min(MAX_ROLLOUTS, requested))


def metric_feedback(skill_md: str, eval_def: dict | None) -> tuple[float, str]:
    """Score a candidate skill via the eval matchers; return ``(composite, feedback)``.

    The feedback is the reflective signal: it names the weakest dimensions (lowest score first) and
    any failed checks, so a reflective optimizer knows *what* to fix — the same credit-assignment
    idea the Elixir reflective loop uses, expressed as text for GEPA.
    """
    result = score_skill(skill_md, eval_def)
    composite = result["composite"]
    dims = result.get("dimensions", {})

    ranked = sorted(dims.items(), key=lambda kv: kv[1].get("score", 0.0))
    lines = [f"Composite score: {composite:.3f}. Weakest dimensions first:"]
    for name, dim in ranked:
        # `_score_dimension` emits `assertions` (each with `check_type`/`passed`), NOT `checks`/`name`.
        failed = [
            a.get("check_type", "?")
            for a in dim.get("assertions", [])
            if not a.get("passed", True)
        ]
        suffix = f" — failed: {', '.join(failed)}" if failed else ""
        lines.append(f"- {name}: {dim.get('score', 0.0):.3f}{suffix}")
    return composite, "\n".join(lines)


def shape_result(best_skill_md, baseline_composite, best_composite, rollouts, history=None) -> dict:
    """Normalize an optimizer outcome into the JSON result the Elixir seam expects."""
    return {
        "best_skill_md": best_skill_md,
        "baseline_composite": round(baseline_composite, 4),
        "best_composite": round(best_composite, 4),
        "improved": best_composite > baseline_composite,
        "rollouts": rollouts,
        "history": history or [],
    }


def run(request, *, runner=None, env=None) -> dict:
    """Handle the ``optimize`` command.

    ``runner(skill_md, eval_def, rollouts) -> result_dict`` is injectable: tests pass a fake so the
    orchestration is exercised deterministically. In production ``runner`` is ``None``, so the
    capability gate runs first and ``_run_gepa_live`` is used only when dspy + a key are present.
    """
    env = os.environ if env is None else env
    skill_md = request.get("skill_md") or request.get("content")
    if not skill_md:
        return _error("missing 'skill_md' (or 'content') in request")

    # Resolve the eval definition exactly like the `score` command (explicit > full set > default),
    # threading any resolved ref known-sets into the accuracy checks.
    eval_def = request.get("eval")
    if eval_def is None and request.get("eval_set") == "full":
        eval_def = FULL_EVAL
    eval_def = inject_refs(eval_def, request.get("refs"))

    # Capability gate (skipped when a runner is injected, i.e. in tests).
    if runner is None:
        reason = unavailable_reason(env)
        if reason:
            return {
                "command": "optimize",
                "status": "not_implemented",
                "version": __version__,
                "reason": reason,
                "result": None,
            }
        runner = _run_gepa_live

    rollouts = clamp_rollouts(request.get("budget"))

    try:
        result = runner(skill_md, eval_def, rollouts)
    except Exception as exc:  # noqa: BLE001 — surface ANY optimizer failure as a clean JSON error.
        return _error(f"optimizer failed: {type(exc).__name__}: {exc}")

    return {
        "command": "optimize",
        "status": "ok",
        "version": __version__,
        "result": result,
    }


def _error(message: str) -> dict:
    return {
        "command": "optimize",
        "status": "error",
        "version": __version__,
        "error": message,
    }


def _run_gepa_live(skill_md, eval_def, rollouts):  # pragma: no cover - needs dspy + a paid LM
    """Real ``dspy.GEPA`` optimization. UNVALIDATED until run live (requires dspy + an API key).

    Framing: wrap the SKILL.md as the output of a trivial single-predictor program; GEPA reflectively
    evolves that predictor's instruction to maximize ``metric_feedback``.

    WARNING — the exact ``dspy.GEPA`` API has drifted across dspy versions: the budget kwarg
    (``max_metric_calls`` vs ``auto``/``max_full_evals``) and a likely-required ``reflection_lm=``
    argument must be confirmed against the installed dspy before this runs clean (the ``>=2.5`` pin
    is broad). The single-example trainset==valset is intentionally degenerate (we optimize one
    document, not a dataset). Any failure here is caught by ``run`` → ``status: "error"``.
    """
    import dspy

    class WriteSkill(dspy.Signature):
        """Write an improved SKILL.md document."""

        request: str = dspy.InputField(desc="what to improve")
        skill_md: str = dspy.OutputField(desc="the full improved SKILL.md")

    program = dspy.Predict(WriteSkill)

    def metric(gold, pred, trace=None, pred_name=None, pred_trace=None):
        score, feedback = metric_feedback(getattr(pred, "skill_md", "") or "", eval_def)
        return dspy.Prediction(score=score, feedback=feedback)

    seed = dspy.Example(request="improve this skill", skill_md=skill_md).with_inputs("request")
    optimizer = dspy.GEPA(metric=metric, max_metric_calls=rollouts)
    compiled = optimizer.compile(program, trainset=[seed], valset=[seed])

    best = compiled(request="improve this skill").skill_md
    baseline, _ = metric_feedback(skill_md, eval_def)
    best_score, _ = metric_feedback(best, eval_def)
    return shape_result(best, baseline, best_score, rollouts)
