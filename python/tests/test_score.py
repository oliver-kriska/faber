"""Tests for the eval scorer and matchers — stdlib unittest, no third-party deps.

Run: ``python3 -m unittest discover -s python/tests`` (or ``pytest`` if installed).
"""

import unittest

from faber_eval.matchers import (
    description_structure,
    has_iron_laws,
    no_dangerous_patterns,
    split_frontmatter,
    valid_agent_refs,
    valid_file_refs,
    valid_skill_refs,
)
from faber_eval.scorer import FULL_EVAL, inject_refs, score_skill

GOOD_SKILL = """---
name: investigate-retry-loops
description: "Investigate failing shell commands systematically — read the error, hypothesize, change one thing. Use when the same command is retried after an error. NOT for first failures."
effort: low
---

# Investigate Retry Loops

Stop blind retries: read the actual error (`mix test` output), form one hypothesis, change one
variable, then re-run.

## Usage

Load when a command like `mix test` or `git push` is re-run after an errored result.

## Iron Laws — Never Violate These

1. Read the actual error output before retrying — never re-run blind.
2. Change exactly one variable per attempt so the result is attributable.
3. After 3 failed attempts, stop and escalate with what was tried.

## Detection

| Signal | Meaning |
| --- | --- |
| same `cmd` 3+ times | retry loop with `is_error` results |
| no edit between runs | nothing changed; the re-run is blind |

## Examples

```bash
# re-run only what broke, after reading the error
mix test --failed
```

## References

- `${CLAUDE_SKILL_DIR}/references/investigate-retry-loops.md` — supporting detail
"""

BAD_SKILL = """---
name: stuff
---

# Stuff

This skill does various general things and might possibly help sometimes etc.

## Notes

Some prose with no structure and no examples and no laws.
"""


class TestFrontmatter(unittest.TestCase):
    def test_split(self):
        fm, body = split_frontmatter(GOOD_SKILL)
        self.assertEqual(fm["name"], "investigate-retry-loops")
        self.assertIn("Investigate", body)
        self.assertNotIn("---", body.split("\n")[0])

    def test_no_frontmatter(self):
        fm, body = split_frontmatter("# Plain\n\nbody")
        self.assertEqual(fm, {})
        self.assertEqual(body, "# Plain\n\nbody")


class TestMatchers(unittest.TestCase):
    def test_has_iron_laws_counts_items(self):
        ok, evidence = has_iron_laws(GOOD_SKILL, min_count=3)
        self.assertTrue(ok, evidence)

    def test_has_iron_laws_fails_when_missing(self):
        ok, _ = has_iron_laws(BAD_SKILL, min_count=1)
        self.assertFalse(ok)

    def test_description_structure(self):
        self.assertTrue(description_structure(GOOD_SKILL)[0])
        self.assertFalse(description_structure(BAD_SKILL)[0])

    def test_description_structure_accepts_stack_vocabulary_leads(self):
        def with_desc(desc):
            return f'---\nname: x\ndescription: "{desc}"\n---\n# X\n'

        # Real stack terms are a valid "what" -- CamelCase, acronyms, digit/+/- compounds.
        for lead in ["GenServer", "LiveView", "OTP", "N+1", "JSON-RPC"]:
            skill = with_desc(f"{lead} pitfalls explained. Use when debugging them.")
            self.assertTrue(description_structure(skill)[0], lead)

        # A single capital letter ("A ", "I ") is still no "what".
        bare = with_desc("A thing that helps. Use when unsure.")
        self.assertFalse(description_structure(bare)[0])

    def test_no_dangerous_patterns_ignores_documented_warnings(self):
        documented = (
            "---\nname: x\ndescription: y\n---\n\n"
            "## Iron Laws\n\n1. Never run rm -rf / in a script.\n"
        )
        # The dangerous string lives inside an Iron Laws section → not flagged.
        self.assertTrue(no_dangerous_patterns(documented)[0])
        # But a bare dangerous command in normal body IS flagged.
        live = "---\nname: x\ndescription: y\n---\n\n## Steps\n\nrun rm -rf / now\n"
        self.assertFalse(no_dangerous_patterns(live)[0])


class TestAccuracyMatchers(unittest.TestCase):
    def test_valid_file_refs_membership(self):
        # GOOD_SKILL references investigate-retry-loops.md.
        self.assertTrue(valid_file_refs(GOOD_SKILL, known_files=["investigate-retry-loops.md"])[0])
        ok, evidence = valid_file_refs(GOOD_SKILL, known_files=["other.md"])
        self.assertFalse(ok)
        self.assertIn("investigate-retry-loops.md", evidence)

    def test_valid_file_refs_neutral_without_known_set(self):
        self.assertTrue(valid_file_refs(GOOD_SKILL)[0])
        self.assertEqual(
            valid_file_refs("no refs here", known_files=["x.md"])[1],
            "no reference file references found",
        )

    def test_valid_file_refs_ignores_cross_skill(self):
        content = "see `compound-docs/references/schema.md` for details"
        self.assertTrue(valid_file_refs(content, known_files=[])[0])

    def test_valid_skill_refs(self):
        content = "run /phx:plan then [[investigate]] and the `verify` skill"
        self.assertTrue(valid_skill_refs(content, known_skills=["plan", "investigate", "verify"])[0])
        ok, evidence = valid_skill_refs(content, known_skills=["plan"])
        self.assertFalse(ok)
        self.assertIn("investigate", evidence)

    def test_valid_agent_refs_builtins(self):
        content = 'subagent_type: "elixir-reviewer" and `security-analyzer`'
        self.assertTrue(
            valid_agent_refs(content, known_agents=["elixir-reviewer", "security-analyzer"])[0]
        )
        # Built-ins are valid even when not in the known set.
        self.assertTrue(valid_agent_refs('subagent_type: "Explore"', known_agents=[])[0])


class TestFullEval(unittest.TestCase):
    def test_full_eval_adds_accuracy_neutral_without_refs(self):
        result = score_skill(GOOD_SKILL, FULL_EVAL)
        self.assertIn("accuracy", result["dimensions"])
        self.assertEqual(result["dimensions"]["accuracy"]["score"], 1.0)
        self.assertGreaterEqual(result["composite"], 0.9, result)

    def test_inject_refs_makes_accuracy_bite(self):
        broken = inject_refs(FULL_EVAL, {"known_files": ["unrelated.md"]})
        result = score_skill(GOOD_SKILL, broken)
        self.assertLess(result["dimensions"]["accuracy"]["score"], 1.0)
        self.assertLess(result["composite"], score_skill(GOOD_SKILL, FULL_EVAL)["composite"])

    def test_weight_total_reported(self):
        # full_eval's 7 structural weights sum to 0.95 (behavioral's 0.10 is folded by Faber.Eval).
        self.assertEqual(score_skill(GOOD_SKILL, FULL_EVAL)["weight_total"], 0.95)


class TestScorer(unittest.TestCase):
    def test_good_skill_scores_high(self):
        result = score_skill(GOOD_SKILL)
        self.assertGreaterEqual(result["composite"], 0.9, result)
        self.assertEqual(result["dimensions"]["completeness"]["score"], 1.0)

    def test_bad_skill_scores_low(self):
        result = score_skill(BAD_SKILL)
        self.assertLess(result["composite"], 0.5, result)

    def test_custom_eval_def(self):
        eval_def = {"dimensions": {"safety": {"weight": 1.0, "checks": [{"type": "has_iron_laws"}]}}}
        self.assertEqual(score_skill(GOOD_SKILL, eval_def)["composite"], 1.0)
        self.assertEqual(score_skill(BAD_SKILL, eval_def)["composite"], 0.0)


if __name__ == "__main__":
    unittest.main()
