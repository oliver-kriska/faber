"""Smoke test: the CLI round-trips JSON over stdin/stdout (and ``--input``) for each command.

Runs the package as a subprocess (``python -m faber_eval``) — exactly how the Elixir
spine will invoke it — so it also exercises the entrypoint wiring. Written with stdlib
``unittest`` so it runs with no third-party deps:

    cd python && python -m unittest discover
    # or, once deps are installed: pytest
"""

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

PKG_DIR = Path(__file__).resolve().parent.parent

MINIMAL_SKILL = """---
name: demo
description: "Demo skill — a tiny example. Use when testing the scorer round-trip."
---

# Demo

## Usage

Loaded in tests.

## Iron Laws — Never Violate These

1. Stay deterministic.
2. No network.
3. No surprises.

## References

- `${CLAUDE_SKILL_DIR}/references/demo.md`
"""


def run(command, payload, extra=()):
    proc = subprocess.run(
        [sys.executable, "-m", "faber_eval", command, *extra],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
        cwd=PKG_DIR,
    )
    return proc


class RoundTripTest(unittest.TestCase):
    def test_score_returns_a_composite(self):
        proc = run("score", {"skill_md": MINIMAL_SKILL})
        self.assertEqual(proc.returncode, 0, proc.stderr)
        response = json.loads(proc.stdout)
        self.assertEqual(response["command"], "score")
        self.assertEqual(response["status"], "ok")
        self.assertIsInstance(response["result"]["composite"], (int, float))

    def test_score_missing_skill_md_is_an_error(self):
        proc = run("score", {"criteria": {"min_score": 0.7}})
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(json.loads(proc.stdout)["status"], "error")

    def test_score_via_input_file(self):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
            json.dump({"skill_md": MINIMAL_SKILL}, fh)
            path = fh.name
        try:
            proc = subprocess.run(
                [sys.executable, "-m", "faber_eval", "score", "--input", path],
                capture_output=True,
                text=True,
                cwd=PKG_DIR,
            )
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(json.loads(proc.stdout)["status"], "ok")
        finally:
            Path(path).unlink(missing_ok=True)

    def test_optimize_is_a_documented_stub(self):
        payload = {"program": "x", "rollouts": 3}
        proc = run("optimize", payload)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        response = json.loads(proc.stdout)
        self.assertEqual(response["command"], "optimize")
        self.assertEqual(response["status"], "not_implemented")
        self.assertEqual(response["echo"], payload)

    def test_empty_stdin_is_treated_as_empty_object(self):
        proc = subprocess.run(
            [sys.executable, "-m", "faber_eval", "optimize"],
            input="",
            capture_output=True,
            text=True,
            cwd=PKG_DIR,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(json.loads(proc.stdout)["echo"], {})

    def test_unknown_command_exits_2(self):
        proc = run("nope", {})
        self.assertEqual(proc.returncode, 2)
        self.assertEqual(json.loads(proc.stdout)["status"], "error")

    def test_invalid_json_exits_1(self):
        proc = subprocess.run(
            [sys.executable, "-m", "faber_eval", "score"],
            input="{not json",
            capture_output=True,
            text=True,
            cwd=PKG_DIR,
        )
        self.assertEqual(proc.returncode, 1)
        self.assertEqual(json.loads(proc.stdout)["status"], "error")


if __name__ == "__main__":
    unittest.main()
