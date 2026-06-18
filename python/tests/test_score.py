"""Tests for the eval scorer and matchers — stdlib unittest, no third-party deps.

Run: ``python3 -m unittest discover -s python/tests`` (or ``pytest`` if installed).
"""

import unittest

from faber_eval.matchers import (
    description_structure,
    has_iron_laws,
    no_dangerous_patterns,
    split_frontmatter,
)
from faber_eval.scorer import score_skill

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
