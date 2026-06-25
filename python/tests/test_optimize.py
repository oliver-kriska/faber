"""Tests for the GEPA optimizer orchestration — stdlib unittest, no dspy, no token spend.

Run: ``python3 -m unittest discover -s python/tests`` (or ``pytest``).

These exercise everything Faber owns — capability gate, the eval-matcher metric adapter, the budget
guardrail, result shaping, and the ``run`` orchestration — with a *fake* runner injected, so they
never import dspy and never call a provider. ``_run_gepa_live`` (the paid dspy path) is deliberately
not covered here; it is validated by the Elixir ``:live_api`` test when you opt in to spend.
"""

import unittest

from faber_eval.optimize import (
    DEFAULT_ROLLOUTS,
    MAX_ROLLOUTS,
    clamp_rollouts,
    metric_feedback,
    run,
    shape_result,
    unavailable_reason,
)

GOOD_SKILL = """---
name: investigate-retry-loops
description: "Investigate failing shell commands systematically — read the error, hypothesize, change one thing. Use when the same command is retried after an error. NOT for first failures."
effort: low
---

# Investigate Retry Loops

Stop blind retries: read the actual error, form one hypothesis, change one variable, then re-run.

## Usage

Load when a command like `mix test` is re-run after an errored result.

## Iron Laws — Never Violate These

1. Read the actual error output before retrying — never re-run blind.
2. Change exactly one variable per attempt so the result is attributable.
3. After 3 failed attempts, stop and escalate with what was tried.
"""

BAD_SKILL = "# nothing\n"


class UnavailableReasonTests(unittest.TestCase):
    def test_reports_dspy_missing_first(self):
        reason = unavailable_reason(has_dspy=False, has_key=False)
        self.assertIn("dspy", reason)

    def test_reports_missing_key_when_dspy_present(self):
        reason = unavailable_reason(has_dspy=True, has_key=False)
        self.assertIsNotNone(reason)
        self.assertIn("API key", reason)

    def test_none_when_both_available(self):
        self.assertIsNone(unavailable_reason(has_dspy=True, has_key=True))

    def test_api_key_detected_from_env(self):
        # api_key_present reads the env; an empty env means "no key" → not available.
        self.assertIsNotNone(unavailable_reason({}, has_dspy=True))


class ClampRolloutsTests(unittest.TestCase):
    def test_default_when_no_budget(self):
        self.assertEqual(clamp_rollouts(None), DEFAULT_ROLLOUTS)
        self.assertEqual(clamp_rollouts({}), DEFAULT_ROLLOUTS)

    def test_caps_at_max(self):
        self.assertEqual(clamp_rollouts({"rollouts": 10_000}), MAX_ROLLOUTS)

    def test_floors_at_one(self):
        self.assertEqual(clamp_rollouts({"rollouts": 0}), 1)
        self.assertEqual(clamp_rollouts({"rollouts": -5}), 1)

    def test_ignores_garbage(self):
        self.assertEqual(clamp_rollouts({"rollouts": "lots"}), DEFAULT_ROLLOUTS)


class MetricFeedbackTests(unittest.TestCase):
    def test_good_skill_scores_higher_than_bad(self):
        good, _ = metric_feedback(GOOD_SKILL, None)
        bad, _ = metric_feedback(BAD_SKILL, None)
        self.assertGreater(good, bad)

    def test_feedback_names_weak_dimensions(self):
        _, feedback = metric_feedback(BAD_SKILL, None)
        self.assertIn("Composite score", feedback)
        # The bad skill fails dimensions; the feedback should enumerate them as bullet lines.
        self.assertIn("- ", feedback)
        # And the "what to fix" half: failed checks must be named (reads scorer's `assertions`/
        # `check_type`). This assertion is what catches the wrong-key regression that previously
        # made the suffix silently empty while scores still worked.
        self.assertIn("— failed:", feedback)


class ShapeResultTests(unittest.TestCase):
    def test_marks_improvement_and_rounds(self):
        result = shape_result("md", 0.40000, 0.700001, 8)
        self.assertEqual(result["best_skill_md"], "md")
        self.assertEqual(result["baseline_composite"], 0.4)
        self.assertEqual(result["best_composite"], 0.7)
        self.assertTrue(result["improved"])
        self.assertEqual(result["rollouts"], 8)

    def test_no_improvement(self):
        self.assertFalse(shape_result("md", 0.7, 0.7, 8)["improved"])


class RunOrchestrationTests(unittest.TestCase):
    def test_missing_skill_is_an_error(self):
        out = run({}, runner=lambda *a: None)
        self.assertEqual(out["status"], "error")
        self.assertIn("skill_md", out["error"])

    def test_not_implemented_without_capabilities(self):
        # No runner injected → the real gate runs. dspy isn't installed in the test env, so this
        # degrades cleanly with a precise reason (and never touches a provider).
        out = run({"skill_md": GOOD_SKILL}, env={})
        self.assertEqual(out["status"], "not_implemented")
        self.assertTrue(out["reason"])
        self.assertIsNone(out["result"])

    def test_runs_injected_runner_and_shapes_ok(self):
        captured = {}

        def fake_runner(skill_md, eval_def, rollouts):
            captured["args"] = (skill_md, eval_def, rollouts)
            baseline, _ = metric_feedback(skill_md, eval_def)
            return shape_result(skill_md + "\nimproved\n", baseline, baseline + 0.1, rollouts)

        out = run({"skill_md": GOOD_SKILL, "budget": {"rollouts": 5}}, runner=fake_runner)
        self.assertEqual(out["status"], "ok")
        self.assertEqual(out["command"], "optimize")
        self.assertEqual(captured["args"][2], 5)  # budget threaded + clamped
        self.assertTrue(out["result"]["improved"])

    def test_runner_exception_becomes_status_error(self):
        def boom(*_a):
            raise RuntimeError("kaboom")

        out = run({"skill_md": GOOD_SKILL}, runner=boom)
        self.assertEqual(out["status"], "error")
        self.assertIn("kaboom", out["error"])

    def test_eval_set_full_is_threaded_to_the_metric(self):
        seen = {}

        def fake_runner(skill_md, eval_def, rollouts):
            seen["eval_def"] = eval_def
            return shape_result(skill_md, 0.5, 0.5, rollouts)

        run({"skill_md": GOOD_SKILL, "eval_set": "full"}, runner=fake_runner)
        # FULL_EVAL is an 8-dimension dict; confirm the optimizer received a real eval definition.
        self.assertIsInstance(seen["eval_def"], dict)
        self.assertTrue(seen["eval_def"])


if __name__ == "__main__":
    unittest.main()
