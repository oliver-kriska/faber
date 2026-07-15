#!/usr/bin/env python3
"""A stand-in for an adapter's referenced scorer, for Faber's exec-in-place dispatch tests.

Mirrors the real contract (lab.eval.scorer): read a POSITIONAL skill path, print one JSON object
to stdout, exit 0. `--mode` selects a failure to simulate:

    ok       emit a valid score payload (the happy path)
    garbage  exit 0 but print something that isn't JSON
    badshape exit 0 and print valid JSON that isn't a score payload
    boom     print a traceback-ish message to stderr and exit 1

It is deliberately stdlib-only and dependency-free so `mix test` needs nothing but python3.
"""

import json
import sys


def main() -> int:
    args = sys.argv[1:]
    mode = "ok"
    if "--mode" in args:
        i = args.index("--mode")
        mode = args[i + 1]
        del args[i : i + 2]

    if not args:
        print("no skill path given", file=sys.stderr)
        return 1

    skill_path = args[0]

    # Read it here: the dispatcher deletes the temp tree as soon as we exit, so echoing the content
    # back is the only way a test can prove the skill actually arrived as a readable file.
    try:
        with open(skill_path) as fh:
            content = fh.read()
    except OSError as exc:
        print(f"could not read skill: {exc}", file=sys.stderr)
        return 1

    if mode == "boom":
        print("Traceback (most recent call last): ModuleNotFoundError: no lab", file=sys.stderr)
        return 1

    if mode == "garbage":
        print("not json at all <<<")
        return 0

    if mode == "badshape":
        print(json.dumps({"hello": "world"}))
        return 0

    # Echo the path back so the test can assert what the dispatcher actually handed us — that's
    # how we prove the skill reached the scorer as a file rather than on stdin.
    print(
        json.dumps(
            {
                "skill": "fake",
                "skill_path": skill_path,
                "composite": 0.42,
                "dimensions": {
                    "elixir_idioms": {
                        "score": 0.42,
                        "passed": 1,
                        "failed": 1,
                        "total": 2,
                        "assertions": [
                            {
                                "id": "elixir_idioms-0",
                                "type": "uses_with",
                                "desc": "Uses a with chain",
                                "passed": True,
                                "evidence": "found `with {:ok, _}`",
                            },
                            {
                                # Echo the path back so the test can prove the skill arrived as a
                                # FILE (the real scorer never reads stdin) and that its parent
                                # directory is named for the skill (that's how the real scorer
                                # resolves which eval definition to apply).
                                "id": "path-echo",
                                "type": "path_echo",
                                "desc": "skill path as received",
                                "passed": True,
                                "evidence": skill_path,
                            },
                            {
                                "id": "content-echo",
                                "type": "content_echo",
                                "desc": "skill content as received",
                                "passed": True,
                                "evidence": content,
                            },
                        ],
                    }
                },
            }
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
