"""Deterministic skill-quality matchers — a faithful, engine-generic subset of the plugin's
``lab/eval/matchers.py``.

Every matcher has the signature ``(content: str, **params) -> tuple[bool, str]``: it returns a
pass/fail boolean plus a short human-readable evidence string. Matchers are pure (no I/O, no
network, no LLM) and stdlib-only — frontmatter is parsed by hand so the sidecar runs under a bare
``python3`` with nothing installed.

Stack-specific thresholds and keyword/pattern lists are *not* baked in: they arrive via the eval
definition's ``params`` (which an adapter supplies through ``eval/eval.yaml``). The defaults here
are deliberately generic so a proposal can be scored before any adapter is attached.
"""

from __future__ import annotations

import os
import re

# ── frontmatter ────────────────────────────────────────────────────────────


def split_frontmatter(content: str) -> tuple[dict, str]:
    """Split a ``---`` YAML frontmatter block from the body.

    A tiny hand-rolled parser: enough for ``key: value`` lines (optionally quoted). Returns
    ``(frontmatter_dict, body)``; if there is no frontmatter, ``({}, content)``.
    """
    if not content.startswith("---"):
        return {}, content

    lines = content.split("\n")
    if lines[0].strip() != "---":
        return {}, content

    fm: dict[str, str] = {}
    end = None
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            end = i
            break
        m = re.match(r"^([A-Za-z0-9_-]+):\s*(.*)$", lines[i])
        if m:
            key, val = m.group(1), m.group(2).strip()
            if len(val) >= 2 and val[0] in "\"'" and val[-1] == val[0]:
                val = val[1:-1]
            fm[key] = val

    if end is None:
        return {}, content
    body = "\n".join(lines[end + 1 :]).lstrip("\n")
    return fm, body


def _regions(body: str) -> list[tuple[str | None, list[str]]]:
    """Return ``[(heading_or_None, body_lines), ...]`` covering every line of the body.

    Unlike :func:`_sections`, this keeps the **pre-heading** region under a ``None`` heading.
    Anything that must not miss content has to walk this, not ``_sections``: the region between the
    H1 and the first ``##`` is where a skill's opening prose goes, and a body with no headings at
    all -- a hook script -- is *entirely* pre-heading, i.e. entirely invisible to ``_sections``.

    A pre-heading region of pure whitespace is not a region (a body that opens on a heading).
    """
    regions: list[tuple[str | None, list[str]]] = []
    current: str | None = None
    buf: list[str] = []

    def flush() -> None:
        if current is not None or any(ln.strip() for ln in buf):
            regions.append((current, buf))

    for line in body.split("\n"):
        m = re.match(r"^#{2,3}\s+(.*)$", line)
        if m:
            flush()
            current = m.group(1).strip()
            buf = []
        else:
            buf.append(line)
    flush()
    return regions


def _sections(body: str) -> list[tuple[str, list[str]]]:
    """Return ``[(heading_name, body_lines), ...]`` for ``##``/``###`` sections of the body."""
    return [(name, lines) for name, lines in _regions(body) if name is not None]


# ── structure ──────────────────────────────────────────────────────────────


def section_exists(content, section, **_):
    _, body = split_frontmatter(content)
    names = [name for name, _ in _sections(body)]
    found = any(section.lower() in name.lower() for name in names)
    if found:
        return True, f"Section '{section}' found"
    return False, f"Section '{section}' missing. Available: {names}"


def max_section_lines(content, max=40, **_):
    _, body = split_frontmatter(content)
    over = [
        (name, len([ln for ln in lines if ln.strip()]))
        for name, lines in _sections(body)
        if len([ln for ln in lines if ln.strip()]) > max
    ]
    if over:
        return False, f"Sections over {max} lines: {over}"
    return True, f"All sections <= {max} lines"


def line_count(content, target=100, tolerance=85, **_):
    _, body = split_frontmatter(content)
    n = len(body.split("\n"))
    if n <= target:
        return True, f"{n} lines (<= target {target})"
    if n <= target + tolerance:
        return True, f"{n} lines (within tolerance {target + tolerance})"
    return False, f"{n} lines (over {target + tolerance})"


def token_estimate(content, max_tokens=2000, **_):
    _, body = split_frontmatter(content)
    tokens = len(body.split()) / 0.75
    if tokens <= max_tokens:
        return True, f"~{int(tokens)} tokens (<= {max_tokens})"
    return False, f"~{int(tokens)} tokens (over {max_tokens})"


# ── frontmatter fields ───────────────────────────────────────────────────────


def frontmatter_field(content, field, expected=None, **_):
    fm, _ = split_frontmatter(content)
    if field not in fm:
        return False, f"frontmatter missing '{field}'"
    if expected is not None and str(fm[field]) != str(expected):
        return False, f"{field}={fm[field]!r}, expected {expected!r}"
    return True, f"{field} present"


def description_length(content, min=50, max=250, **_):
    fm, _ = split_frontmatter(content)
    desc = fm.get("description", "")
    n = len(desc)
    if min <= n <= max:
        return True, f"description {n} chars (in [{min}, {max}])"
    return False, f"description {n} chars (want [{min}, {max}])"


def description_keywords(content, min=3, keywords=None, **_):
    # Generic by default: if no keyword list is supplied, this is a no-op pass (an adapter
    # supplies the stack's domain keywords through eval params).
    if not keywords:
        return True, "no keyword list configured (skipped)"
    fm, _ = split_frontmatter(content)
    desc = fm.get("description", "").lower()
    hits = [k for k in keywords if k.lower() in desc]
    if len(hits) >= min:
        return True, f"{len(hits)} domain keywords: {hits}"
    return False, f"only {len(hits)} domain keywords (want >= {min})"


_VAGUE_DEFAULT = ["general", "various", "etc", "sometimes", "might", "possibly"]


def description_no_vague(content, forbidden=None, **_):
    forbidden = forbidden or _VAGUE_DEFAULT
    fm, _ = split_frontmatter(content)
    desc = fm.get("description", "").lower()
    found = [w for w in forbidden if re.search(rf"\b{re.escape(w)}\b", desc)]
    if found:
        return False, f"vague words in description: {found}"
    return True, "no vague words"


def description_structure(content, **_):
    fm, _ = split_frontmatter(content)
    desc = fm.get("description", "")
    # "What" = starts with a capitalized word of >=2 chars. [\w+-] (not [a-z]) so real stack
    # vocabulary passes -- "GenServer...", "OTP...", "N+1..." -- while a bare "A " still fails.
    # Keep in lockstep with lib/faber/eval/matchers.ex (parity test pins both).
    has_what = bool(re.search(r"^[A-Z][\w+-]+\s", desc))
    has_when = bool(re.search(r"\b[Uu]se\s+(?:when|after|for|to)\b", desc))
    if has_what and has_when:
        return True, "description has both what and when"
    return False, f"description structure (what={has_what}, when={has_when})"


# ── content search ───────────────────────────────────────────────────────────


def content_present(content, pattern, **_):
    if re.search(pattern, content):
        return True, f"pattern present: {pattern}"
    return False, f"pattern absent: {pattern}"


def content_absent(content, pattern, **_):
    m = re.search(pattern, content)
    if m:
        return False, f"forbidden pattern present: {m.group(0)!r}"
    return True, f"pattern absent: {pattern}"


# ── safety ───────────────────────────────────────────────────────────────────


def has_iron_laws(content, min_count=1, **_):
    _, body = split_frontmatter(content)
    candidates = [(name, lines) for name, lines in _sections(body) if "iron law" in name.lower()]
    if not candidates:
        return False, "no Iron Laws section"
    best = max(
        candidates,
        key=lambda s: len([ln for ln in s[1] if re.match(r"^\s*(?:\d+[\.\)]\s+|[-*]\s+)", ln)]),
    )
    items = [ln for ln in best[1] if re.match(r"^\s*(?:\d+[\.\)]\s+|[-*]\s+)", ln)]
    if len(items) >= min_count:
        return True, f"{len(items)} Iron Laws (>= {min_count})"
    return False, f"only {len(items)} Iron Laws (want >= {min_count})"


# Generic dangerous-shell defaults; an adapter overrides with stack-specific patterns.
_DANGEROUS_DEFAULT = [
    r"rm\s+-rf\s+/",
    r"sudo\s+rm\b",
    r"curl\s+[^|\n]*\|\s*(?:sudo\s+)?(?:ba)?sh",
    r":\(\)\s*\{",  # fork bomb
]

_SAFE_SECTION_HINTS = (
    "iron law",
    "anti-pattern",
    "red flag",
    "detection",
    "checklist",
    "gotcha",
)


def no_dangerous_patterns(content, patterns=None, **_):
    patterns = patterns or _DANGEROUS_DEFAULT
    _, body = split_frontmatter(content)
    # ``_regions``, not ``_sections``: this is the gate deciding what gets written into the user's
    # ``~/.claude/skills``, so it must search the *whole* body. Searching ``_sections`` let a valid
    # SKILL.md carrying ``rm -rf /`` between its H1 and first ``##`` score a clean pass, and made
    # any heading-less body (a hook script) a vacuous pass against an empty haystack.
    #
    # ``_SAFE_SECTION_HINTS`` exempts a section that *announces* it documents dangerous patterns --
    # a skill listing ``rm -rf /`` under "Anti-patterns" is doing its job. Unheaded prose announces
    # nothing, so the pre-heading region (``None``) is never exempt. Table rows are still excluded.
    safe_body_lines = []
    for name, lines in _regions(body):
        if name is not None and any(h in name.lower() for h in _SAFE_SECTION_HINTS):
            continue
        safe_body_lines.extend(ln for ln in lines if not ln.strip().startswith("|"))
    haystack = "\n".join(safe_body_lines)
    for pat in patterns:
        m = re.search(pat, haystack)
        if m:
            return False, f"dangerous pattern {pat!r}: {m.group(0)!r}"
    return True, "no dangerous patterns"


# ── clarity / specificity ────────────────────────────────────────────────────


def has_examples(content, min_blocks=1, min_lines=2, **_):
    _, body = split_frontmatter(content)
    blocks = re.findall(r"```[\w]*\n(.*?)```", body, re.DOTALL)
    good = [b for b in blocks if len([ln for ln in b.split("\n") if ln.strip()]) >= min_lines]
    if len(good) >= min_blocks:
        return True, f"{len(good)} example blocks (>= {min_blocks})"
    return False, f"only {len(good)} example blocks (want >= {min_blocks})"


_IMPERATIVE = re.compile(
    r"^\s*(?:Run|Add|Create|Check|Read|Use|Set|Write|Install|Configure|Verify|Ensure|Avoid|"
    r"Prefer|Call|Make|Define|Update|Remove|Replace|Apply|Pass|Return|Build|Test|Fix|Trace|"
    r"Inspect|Confirm|Mark|Stage|Commit|Render|Parse|Score|Propose|Gate|Keep|Revert|Stop|Load|"
    r"Skip|Move|Spawn|Group|Rank|Detect|Compute|Scan|Mine|Wire|Open|Close|Start|Find|List)\b"
)


def action_density(content, min_ratio=0.25, **_):
    _, body = split_frontmatter(content)
    lines = body.split("\n")
    content_lines = [
        ln for ln in lines if ln.strip() and not ln.lstrip().startswith(("#", "```"))
    ]
    if not content_lines:
        return False, "no content lines"
    actionable = 0
    for ln in content_lines:
        if (
            _IMPERATIVE.match(ln)
            or re.match(r"^\s*\d+[\.\)]\s+", ln)
            or re.match(r"^\s*[-*]\s+\*\*", ln)
            or (ln.strip().startswith("|") and ln.count("|") >= 2)
        ):
            actionable += 1
    ratio = actionable / len(content_lines)
    if ratio >= min_ratio:
        return True, f"action density {ratio:.2f} (>= {min_ratio})"
    return False, f"action density {ratio:.2f} (want >= {min_ratio})"


_CONCRETE = [
    r"`[^`]+`",
    r"^\s*\|",
    r"\w+\.\w+\.\w+",
    r"/\w+[/\w]*\.\w+",
    r"--\w+",
    r"^\s*-\s*\[\s*\]",
]
def specificity_ratio(content, min_ratio=0.15, **_):
    _, body = split_frontmatter(content)
    lines = [ln for ln in body.split("\n") if ln.strip()]
    if not lines:
        return False, "no content"
    concrete = sum(1 for ln in lines if any(re.search(p, ln) for p in _CONCRETE))
    ratio = concrete / len(lines)
    if ratio >= min_ratio:
        return True, f"specificity {ratio:.2f} (>= {min_ratio})"
    return False, f"specificity {ratio:.2f} (want >= {min_ratio})"


# ── accuracy (cross-reference resolution) ─────────────────────────────────────
#
# The plugin's accuracy matchers list the filesystem to resolve refs. To keep these matchers PURE
# (this module's contract) and the native↔sidecar parity exact, Faber validates refs against
# caller-supplied *known-sets* threaded in via params; the filesystem walk happens once at the
# boundary. A missing known-set neutral-passes (cannot validate → never block the gate), mirroring
# the reference's "cannot locate plugin root — skipping" behavior.

_BUILTIN_AGENTS = ("general-purpose", "Explore", "Plan", "code-simplifier")
_AGENT_ROLES = (
    "reviewer|analyzer|architect|validator|runner|specialist|advisor|judge|"
    "supervisor|orchestrator|researcher|tracer"
)


def _validate_refs(refs, known, label, norm=lambda x: x):
    if known is None:
        return True, f"no {label} index supplied — skipping"
    if not refs:
        return True, f"no {label} references found"
    known_set = {norm(k) for k in known}
    missing = sorted({r for r in refs if r not in known_set})
    if not missing:
        return True, f"all {len(set(refs))} {label} references valid"
    return False, f"missing {label}s: {missing}"


def valid_file_refs(content, known_files=None, **_):
    cross = {
        m.group(2)
        for m in re.finditer(r"([\w-]+)/references/([\w.-]+\.md)", content)
        if m.group(1) not in ("CLAUDE_SKILL_DIR}", "CLAUDE_SKILL_DIR")
    }
    refs = [
        f
        for f in dict.fromkeys(
            re.findall(r"(?:CLAUDE_SKILL_DIR\}?/)?references/([\w.-]+\.md)", content)
        )
        if f not in cross
    ]
    return _validate_refs(refs, known_files, "reference file", norm=os.path.basename)


def valid_skill_refs(content, known_skills=None, **_):
    refs = re.findall(r"(?<!/)/\w[\w-]*:(\w[\w-]*)", content)
    refs += re.findall(r"\[\[([\w-]+)\]\]", content)
    refs += re.findall(r"`([\w-]+)`\s+skill", content)
    return _validate_refs(list(dict.fromkeys(refs)), known_skills, "skill")


def valid_agent_refs(content, known_agents=None, builtin_agents=None, **_):
    builtin = set(builtin_agents or _BUILTIN_AGENTS)
    refs = re.findall(r"subagent_type[=:]\s*[\"']?([\w-]+)", content)
    refs += re.findall(rf"`([\w-]+-(?:{_AGENT_ROLES}))`", content)
    refs = [r for r in dict.fromkeys(refs) if r not in builtin]
    return _validate_refs(refs, known_agents, "agent")


MATCHERS = {
    "section_exists": section_exists,
    "max_section_lines": max_section_lines,
    "line_count": line_count,
    "token_estimate": token_estimate,
    "frontmatter_field": frontmatter_field,
    "description_length": description_length,
    "description_keywords": description_keywords,
    "description_no_vague": description_no_vague,
    "description_structure": description_structure,
    "content_present": content_present,
    "content_absent": content_absent,
    "has_iron_laws": has_iron_laws,
    "no_dangerous_patterns": no_dangerous_patterns,
    "has_examples": has_examples,
    "action_density": action_density,
    "specificity_ratio": specificity_ratio,
    "valid_file_refs": valid_file_refs,
    "valid_skill_refs": valid_skill_refs,
    "valid_agent_refs": valid_agent_refs,
}


def run_check(check_type: str, content: str, params: dict) -> tuple[bool, str]:
    """Dispatch one check by type. Unknown types fail loudly (caught by the scorer)."""
    fn = MATCHERS.get(check_type)
    if fn is None:
        return False, f"unknown check_type: {check_type}"
    return fn(content, **params)
