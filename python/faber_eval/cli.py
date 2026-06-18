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
* ``optimize`` — wraps GEPA / ``dspy.GEPA`` for the evolve→eval→keep loop. Still a stub: GEPA
  needs ``dspy`` installed and a provider API key, so it reports ``status: "not_implemented"``.

The request may be supplied on stdin (canonical) or via ``--input PATH`` (used by the Elixir
spine to avoid feeding stdin from a Port).
"""

import json
import sys

from faber_eval import __version__
from faber_eval.scorer import score_skill


def score(request):
    """Structural eval of a proposed skill. Ports the plugin's lab/eval matchers."""
    content = request.get("skill_md") or request.get("content")
    if not content:
        return {
            "command": "score",
            "status": "error",
            "version": __version__,
            "error": "missing 'skill_md' (or 'content') in request",
        }
    result = score_skill(content, request.get("eval"))
    return {
        "command": "score",
        "status": "ok",
        "version": __version__,
        "result": result,
    }


def optimize(request):
    """Evolve→eval→keep optimization (GEPA / DSPy).

    Still a stub: GEPA requires ``dspy`` + a provider API key, which the v1 boundary does not
    assume. Faber's M5 loop drives the proven deterministic keep/revert/plateau cycle in Elixir
    (`Faber.Loop`) instead; this command is reserved for a future GEPA-backed optimizer.
    """
    return {
        "command": "optimize",
        "status": "not_implemented",
        "version": __version__,
        "reason": "GEPA optimizer not wired (needs dspy + API key); use Faber.Loop for v1",
        "echo": request,
        "result": None,
    }


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

    _emit(HANDLERS[command](request))
    return 0
