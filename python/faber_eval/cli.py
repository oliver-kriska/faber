"""Command dispatch for the Faber eval sidecar.

The boundary contract (v1):

* Invoked as ``python -m faber_eval <command>`` (or the ``faber-eval`` console script).
* The request is a single JSON object read from **stdin**.
* The response is a single JSON object written to **stdout**, terminated by a newline.
* Exit code ``0`` on success, ``1`` on a bad request (e.g. invalid JSON), ``2`` on an
  unknown command. Diagnostics go to **stderr** so stdout stays pure JSON.

Two commands are defined; both are stubs in M0 and report ``status: "not_implemented"``:

* ``score``    — structural / trigger eval. Ports the plugin's ``lab/eval`` matchers (M4).
* ``optimize`` — wraps GEPA / ``dspy.GEPA`` for the evolve→eval→keep loop (M4/M5).
"""

import json
import sys

from faber_eval import __version__


def score(request):
    """Structural / trigger eval of a proposed skill. Stub until M4."""
    return {
        "command": "score",
        "status": "not_implemented",
        "version": __version__,
        "echo": request,
        "result": None,
    }


def optimize(request):
    """Evolve→eval→keep optimization (GEPA / DSPy). Stub until M4/M5."""
    return {
        "command": "optimize",
        "status": "not_implemented",
        "version": __version__,
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


def _read_request(stream):
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
        request = _read_request(sys.stdin)
    except json.JSONDecodeError as exc:
        _emit({"status": "error", "command": command, "error": f"invalid JSON on stdin: {exc}"})
        return 1

    _emit(HANDLERS[command](request))
    return 0
