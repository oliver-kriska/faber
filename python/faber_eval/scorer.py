"""Skill scorer — composes the matchers into weighted dimensions and a composite score.

A faithful, engine-generic port of the plugin's ``lab/eval/scorer.py`` contract:

* ``dimension.score = sum(weight for passed assertions) / sum(weight for all assertions)``
* ``composite      = sum(dim.weight * dim.score) / sum(dim.weight)``

The default eval (``DEFAULT_EVAL``) scores a standalone proposal — it omits the plugin's
``accuracy`` (cross-reference resolution needs a real plugin tree) and ``behavioral`` (needs a
cached trigger run) dimensions, since neither is meaningful for a freshly proposed skill with no
filesystem context. An adapter can pass a richer ``eval_def`` through the ``score`` request to add
stack-specific checks.
"""

from __future__ import annotations

from faber_eval.matchers import run_check

# dimension -> (weight, [ {type, weight?, **params}, ... ])
DEFAULT_EVAL = {
    "completeness": {
        "weight": 0.25,
        "checks": [
            {"type": "frontmatter_field", "field": "name"},
            {"type": "frontmatter_field", "field": "description"},
            {"type": "has_iron_laws", "min_count": 3},
            {"type": "section_exists", "section": "Usage"},
            {"type": "section_exists", "section": "References"},
        ],
    },
    "conciseness": {
        "weight": 0.15,
        "checks": [
            {"type": "line_count", "target": 100, "tolerance": 85},
            {"type": "max_section_lines", "max": 40},
            {"type": "token_estimate", "max_tokens": 2000},
        ],
    },
    "triggering": {
        "weight": 0.20,
        "checks": [
            {"type": "description_length", "min": 50, "max": 250},
            {"type": "description_no_vague"},
            {"type": "description_structure"},
        ],
    },
    "safety": {
        "weight": 0.15,
        "checks": [
            {"type": "has_iron_laws", "min_count": 1},
            {"type": "no_dangerous_patterns"},
        ],
    },
    "clarity": {
        "weight": 0.10,
        "checks": [
            {"type": "action_density", "min_ratio": 0.25},
            {"type": "has_examples", "min_blocks": 1},
        ],
    },
    "specificity": {
        "weight": 0.15,
        "checks": [
            {"type": "specificity_ratio", "min_ratio": 0.15},
        ],
    },
}


def _score_dimension(name: str, spec: dict, content: str) -> dict:
    assertions = []
    passed_weight = 0.0
    total_weight = 0.0
    passed = failed = 0

    for i, check in enumerate(spec.get("checks", [])):
        check = dict(check)
        check_type = check.pop("type")
        weight = float(check.pop("weight", 1.0))
        ok, evidence = run_check(check_type, content, check)
        total_weight += weight
        if ok:
            passed_weight += weight
            passed += 1
        else:
            failed += 1
        assertions.append(
            {
                "id": f"{name}-{i}",
                "check_type": check_type,
                "passed": ok,
                "evidence": evidence,
                "weight": weight,
            }
        )

    score = passed_weight / total_weight if total_weight else 1.0
    return {
        "dimension": name,
        "score": round(score, 4),
        "passed": passed,
        "failed": failed,
        "total": passed + failed,
        "assertions": assertions,
    }


def score_skill(content: str, eval_def: dict | None = None) -> dict:
    """Score a SKILL.md string. Returns a ``ScoreResult``-shaped dict.

    ``eval_def`` (optional) overrides ``DEFAULT_EVAL``; it must be
    ``{"dimensions": {name: {"weight": float, "checks": [...]}}}`` or the bare
    ``{name: {...}}`` mapping.
    """
    dims_spec = eval_def.get("dimensions", eval_def) if eval_def else DEFAULT_EVAL

    dimensions = {}
    composite_num = 0.0
    composite_den = 0.0
    for name, spec in dims_spec.items():
        weight = float(spec.get("weight", 1.0))
        dim = _score_dimension(name, spec, content)
        dimensions[name] = dim
        composite_num += weight * dim["score"]
        composite_den += weight

    composite = composite_num / composite_den if composite_den else 0.0
    return {"composite": round(composite, 4), "dimensions": dimensions}
