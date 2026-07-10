"""Command dispatch for the Faber eval sidecar.

The boundary contract (v1):

* Invoked as ``python -m faber_eval <command>`` (or the ``faber-eval`` console script).
* The request is a single JSON object read from **stdin**.
* The response is a single JSON object written to **stdout**, terminated by a newline.
* Exit code ``0`` on success, ``1`` on a bad request (e.g. invalid JSON), ``2`` on an
  unknown command. Diagnostics go to **stderr** so stdout stays pure JSON.

Two commands are defined:

* ``score``    — structural eval of a proposed skill. Ports the plugin's ``lab/eval`` matchers
  (M4). Implemented: stdlib-only, no API key needed.
* ``optimize`` — ``dspy.GEPA`` optimization of a SKILL.md against the eval matchers
  (``faber_eval.optimize``). The orchestration (capability gate, eval-matcher metric, budget) is
  real and tested; the live dspy path needs the ``gepa`` extra + a provider API key, so without
  them it degrades to ``status: "not_implemented"`` with a precise reason. This common path stays
  stdlib-only (dspy is imported only when actually optimizing live).

The request may be supplied on stdin (canonical) or via ``--input PATH`` (used by the Elixir
spine to avoid feeding stdin from a Port).
"""

import json
import sys

from faber_eval import __version__, optimize as optimizer
from faber_eval.scorer import FULL_EVAL, inject_refs, score_skill


def score(request):
    """Structural eval of a proposed skill. Ports the plugin's lab/eval matchers.

    Eval selection: an explicit ``eval`` dict wins; else ``eval_set: "full"`` picks the 8-dimension
    ``FULL_EVAL``; else the 6-dimension ``DEFAULT_EVAL``. Resolved ref known-sets in ``refs`` are
    threaded into the accuracy checks so they validate against the caller's tree.
    """
    content = request.get("skill_md") or request.get("content")
    if not content:
        return {
            "command": "score",
            "status": "error",
            "version": __version__,
            "error": "missing 'skill_md' (or 'content') in request",
        }
    eval_def = request.get("eval")
    if eval_def is None and request.get("eval_set") == "full":
        eval_def = FULL_EVAL
    eval_def = inject_refs(eval_def, request.get("refs"))
    result = score_skill(content, eval_def)
    return {
        "command": "score",
        "status": "ok",
        "version": __version__,
        "result": result,
    }


def optimize(request):
    """``dspy.GEPA`` optimization of a SKILL.md against the eval matchers.

    Delegates to ``faber_eval.optimize.run``. Without the ``gepa`` extra (``dspy``) + a provider API
    key it degrades to ``status: "not_implemented"`` with a precise reason; the Elixir keyless
    reflective loop covers v1 self-improvement either way.
    """
    return optimizer.run(request)


HANDLERS = {"score": score, "optimize": optimize}

_USAGE = (
    "usage: python -m faber_eval <command>\n"
    "       reads a JSON request on stdin, writes a JSON response on stdout\n"
    "\n"
    f"commands: {', '.join(sorted(HANDLERS))}\n"
)


def _read_request(argv, stream):
    """Read the JSON request from ``--input PATH`` if present, else from ``stream`` (stdin)."""
    if "--input" in argv:
        idx = argv.index("--input")
        path = argv[idx + 1]
        with open(path, encoding="utf-8") as fh:
            raw = fh.read()
    else:
        raw = stream.read()
    if not raw.strip():
        return {}
    return json.loads(raw)


def _emit(obj):
    json.dump(obj, sys.stdout)
    sys.stdout.write("\n")


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)

    if not argv or argv[0] in ("-h", "--help"):
        sys.stderr.write(_USAGE)
        return 0 if argv else 2

    command = argv[0]

    if command in ("--version", "-V"):
        sys.stderr.write(f"{__version__}\n")
        return 0

    if command not in HANDLERS:
        _emit({"status": "error", "error": f"unknown command: {command}"})
        sys.stderr.write(_USAGE)
        return 2

    try:
        request = _read_request(argv[1:], sys.stdin)
    except json.JSONDecodeError as exc:
        _emit({"status": "error", "command": command, "error": f"invalid JSON: {exc}"})
        return 1
    except OSError as exc:
        _emit({"status": "error", "command": command, "error": f"cannot read --input: {exc}"})
        return 1

    try:
        result = HANDLERS[command](request)
    except Exception as exc:  # noqa: BLE001 — the sidecar must always answer in JSON, never a traceback
        # An untrusted adapter pack can supply e.g. an invalid regex that makes a matcher raise.
        # Honor the JSON-over-stdin/stdout contract: emit a structured error, not a bare traceback.
        _emit({"status": "error", "command": command, "error": f"{type(exc).__name__}: {exc}"})
        return 1

    _emit(result)
    return 0
