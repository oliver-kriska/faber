"""Smoke test: the CLI round-trips JSON over stdin/stdout for each command.

Runs the package as a subprocess (``python -m faber_eval``) — exactly how the Elixir
spine will invoke it — so it also exercises the entrypoint wiring. Written with stdlib
``unittest`` so it runs with no third-party deps:

    cd python && python -m unittest discover
    # or, once deps are installed: pytest
"""

import json
import subprocess
import sys
import unittest
from pathlib import Path

PKG_DIR = Path(__file__).resolve().parent.parent


def run(command, payload):
    proc = subprocess.run(
        [sys.executable, "-m", "faber_eval", command],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
        cwd=PKG_DIR,
    )
    return proc


class RoundTripTest(unittest.TestCase):
    def test_score_round_trips_json(self):
        payload = {"skill": {"name": "demo"}, "criteria": {"min_score": 0.7}}
        proc = run("score", payload)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        response = json.loads(proc.stdout)
        self.assertEqual(response["command"], "score")
        self.assertEqual(response["status"], "not_implemented")
        self.assertEqual(response["echo"], payload)

    def test_optimize_round_trips_json(self):
        payload = {"program": "x", "rollouts": 3}
        proc = run("optimize", payload)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        response = json.loads(proc.stdout)
        self.assertEqual(response["command"], "optimize")
        self.assertEqual(response["echo"], payload)

    def test_empty_stdin_is_treated_as_empty_object(self):
        proc = subprocess.run(
            [sys.executable, "-m", "faber_eval", "score"],
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
