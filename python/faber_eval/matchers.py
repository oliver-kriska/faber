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
import unicodedata

# ── frontmatter ────────────────────────────────────────────────────────────


def _split_raw(content: str) -> tuple[str, str]:
    """Return ``(frontmatter_text, body)``, or ``("", content)`` when there is no frontmatter.

    Split out from :func:`split_frontmatter` (whose contract is unchanged) because the safety scan
    needs the RAW frontmatter text: the field parser below keeps only the ``key: value`` lines it
    understands and silently drops everything else -- block scalars, list items, continuations.
    Handing a safety check a map built by a lossy parser rebuilds the empty-haystack vacuous pass
    one layer up: the payload simply isn't in the map to be found.
    """
    if not content.startswith("---"):
        return "", content

    lines = content.split("\n")
    if lines[0].strip() != "---":
        return "", content

    end = None
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            end = i
            break

    if end is None:
        return "", content

    body = "\n".join(lines[end + 1 :]).lstrip("\n")
    return "\n".join(lines[1:end]), body


def split_frontmatter(content: str) -> tuple[dict, str]:
    """Split a ``---`` YAML frontmatter block from the body.

    A tiny hand-rolled parser: enough for ``key: value`` lines (optionally quoted). Returns
    ``(frontmatter_dict, body)``; if there is no frontmatter, ``({}, content)``.
    """
    fm_text, body = _split_raw(content)

    fm: dict[str, str] = {}
    for line in fm_text.split("\n"):
        m = re.match(r"^([A-Za-z0-9_-]+):\s*(.*)$", line)
        if m:
            key, val = m.group(1), m.group(2).strip()
            if len(val) >= 2 and val[0] in "\"'" and val[-1] == val[0]:
                val = val[1:-1]
            fm[key] = val

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


_CONTINUATION = re.compile(r"\\\n[ \t]*")


def _splice_continuations(body: str) -> str:
    """Read an executable artifact the way the shell reads it.

    A backslash-newline is a **line continuation**, spliced away before the shell parses anything,
    so ``curl ...\\`` + ``\\n|sh`` IS the single command ``curl ... |sh``. The patterns are written
    against whole commands, so they must see whole commands.

    This -- not the table-row filter -- is what B2 actually turned on. ``_DANGEROUS_DEFAULT``'s
    pattern is ``curl\\s+[^|\\n]*\\|\\s*(?:ba)?sh``, whose ``[^|\\n]*`` cannot cross a newline, so
    with the table filter off and both lines in the haystack it STILL does not match. It can only
    ever join lines, never drop text, so it cannot hide a payload from a pattern.
    """
    return _CONTINUATION.sub(" ", body)


def _body_haystack(body: str, exempt_safe_sections: bool) -> str:
    if not exempt_safe_sections:
        # Executable: no markdown transform at all. Any markdown transform added below later
        # therefore cannot silently apply to a script.
        return _splice_continuations(body)

    lines_out = []
    for name, lines in _regions(body):
        if name is not None and any(h in name.lower() for h in _SAFE_SECTION_HINTS):
            continue
        # A leading ``|`` is a markdown table row -- prose, and prose may name a danger.
        lines_out.extend(ln for ln in lines if not ln.strip().startswith("|"))
    return "\n".join(lines_out)


def no_dangerous_patterns(content, patterns=None, exempt_safe_sections=True, **_):
    patterns = patterns or _DANGEROUS_DEFAULT

    # The frontmatter is scanned too, and this is not a detail: it used to be dropped outright
    # (``split_frontmatter`` returns only the body), so ``description: ... rm -rf / ...`` was
    # invisible here. Reproduced before fixing -- a well-formed skill scored **composite 1.0,
    # passed, vetoed: []**, byte-identical in score to the same skill with a benign description,
    # and installed. The payload cost the attacker exactly nothing, in the one field an agent
    # reliably loads into context to decide whether to run the skill at all.
    fm, body = _split_raw(content)

    # Two haystacks because the exemptions differ; both are searched. The frontmatter is taken raw
    # and whole -- no safe-section exemption (it has no headings, so it can announce nothing) and no
    # table filter (a leading ``|`` there is a YAML block scalar, not a table row).
    #
    # ``_regions``, not ``_sections``: this is the gate deciding what gets written into the user's
    # ``~/.claude/skills``, so it must search the *whole* body. Searching ``_sections`` let a valid
    # SKILL.md carrying ``rm -rf /`` between its H1 and first ``##`` score a clean pass, and made
    # any heading-less body (a hook script) a vacuous pass against an empty haystack.
    #
    # ``_SAFE_SECTION_HINTS`` exempts a section that *announces* it documents dangerous patterns --
    # a skill listing ``rm -rf /`` under "Anti-patterns" is doing its job. Unheaded prose announces
    # nothing, so the pre-heading region (``None``) is never exempt. Table rows are still excluded.
    #
    # ``exempt_safe_sections=False`` means "this artifact is EXECUTABLE" (only the hook eval set
    # passes it), and an executable artifact therefore gets **no markdown-shaped transform at all**,
    # because it is not markdown. Mirrors ``Faber.Eval.Matchers.body_haystack/2`` -- see that
    # function for the full reasoning; the short version is that gating each markdown transform on
    # the flag one at a time was tried and is the wrong shape. Three instances of the one mistake
    # were found here (``##`` = heading vs comment; ``|`` = table row vs pipeline continuation;
    # ``_regions`` consuming the heading LINE), and the third would have been *created* by the fix
    # for the second.
    haystack = fm + "\n" + _body_haystack(body, exempt_safe_sections)
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


# ── hook matchers ────────────────────────────────────────────────────────────
#
# Mirrors ``Faber.Eval.Matchers``' hook set. Hooks are scored by their own eval set, not the skill
# set: a shell script has no frontmatter, Iron Laws or prose, so ``specificity_ratio`` and friends
# don't measure a hook badly -- they don't measure it at all.


def hook_shebang(content, **_):
    """A hook must open with a ``#!`` shebang -- Claude Code executes the file.

    Line 1 only: a ``#!`` anywhere else is just a comment.
    """
    first = content.split("\n", 1)[0]
    if first.startswith("#!"):
        return True, f"shebang: {first.strip()}"
    return False, f"no shebang on line 1: {first[:40]!r}"


# How a hook can read the tool call Claude Code pipes to it on stdin as JSON.
_STDIN_READS = [
    r"\$\(\s*cat\s*\)",
    r"\bjq\b",
    r"\bread\b\s+(?:-r\s+)?\w",
    r"</dev/stdin",
    r"\bcat\s*(?:-|<&0)\b",
    r"\bpython3?\b[^\n]*\bjson\.load\b",
]

# Only these events hand the hook a tool call; SessionStart/Stop fire on the session.
_TOOL_CALL_EVENTS = ("PreToolUse", "PostToolUse")


def _code_only(content: str) -> str:
    """The script with its comments removed, read the way the shell reads it.

    Note the deliberate asymmetry with ``no_dangerous_patterns``, which strips NOTHING and searches
    comments too. Both directions are the conservative one for their own question, and that is the
    rule to keep when adding a matcher here:

    * a **veto** asks "is anything dangerous present?" -> search MORE; a payload hiding in a comment
      must still be caught (a ``#`` is only a comment until someone edits the line above it).
    * a **necessary condition** asks "does the script definitely do X?" -> search LESS; text in a
      comment is not evidence that the code does anything.

    Each errs toward rejecting the artifact. Comments are dropped before continuations are spliced,
    matching bash: a trailing backslash does NOT continue a comment, so the line after ``# ... \\``
    is code and must survive.
    """
    lines = [ln for ln in content.split("\n") if not ln.strip().startswith("#")]
    return _splice_continuations("\n".join(lines))


def hook_reads_stdin(content, event=None, **_):
    """A tool-call hook must read the tool call from stdin (Claude Code pipes it in as JSON).

    Scoped by ``event``: an event that receives no tool call neutral-passes. An absent event is
    treated as a tool-call hook -- the conservative reading, and what Faber proposes.

    Searches ``_code_only`` and not ``content``: a comment MENTIONING jq is not a script that RUNS
    jq. Every non-``script`` token of a hook renders into a ``#`` comment, so this scanned them.
    Measured before the fix: a script whose whole body is ``echo 'always fine'; exit 0``, with the
    *innocent* description "Use jq to check the command before it runs", scored composite 1.0,
    passed -- a hook that cannot see its input, at a perfect score, from the dimension whose entire
    job is to reject exactly that.
    """
    if isinstance(event, str) and event not in _TOOL_CALL_EVENTS:
        return True, f"{event} receives no tool call — stdin not required"
    code = _code_only(content)
    for pat in _STDIN_READS:
        if re.search(pat, code):
            return True, f"reads stdin: {pat!r}"
    return False, "never reads stdin — the hook can't see the tool call it is deciding about"


def hook_pointer(content, event=None, matcher=None, known_events=None, **_):
    """The settings.json pointer shape: ``event`` in ``known_events``, ``matcher`` non-empty.

    Fails rather than neutral-passing when unresolved -- unlike the ref checks. A missing ref
    known-set means "we couldn't resolve context"; a missing pointer means the hook has nowhere to
    be installed, which is unanswerable rather than unanswered.
    """
    known = known_events or []
    if not isinstance(event, str) or not event:
        return False, "no hook event declared"
    if known and event not in known:
        return False, (
            f"unknown event {event!r} — a hook on an event Claude Code never fires "
            f"is a hook that silently never runs (known: {', '.join(known)})"
        )
    if not isinstance(matcher, str) or not matcher.strip():
        return False, "empty matcher — it would have to match every tool call or none"
    if any(unicodedata.category(ch) in ("Cc", "Cf") for ch in matcher):
        # ``\p{Cc}\p{Cf}`` in the Elixir twin; Python's ``re`` has no ``\p{}``, so the categories
        # are checked directly. A matcher reaches the rendered script inside a ``#`` comment, and a
        # ``#`` comment ends at a newline. The renderer defangs it (that is the fix); this layer
        # makes the tampering *visible* rather than laundering it into a valid-looking matcher.
        return False, (
            "matcher contains a control or format character — a hook matcher is a regex over tool "
            "names, so a newline or ANSI escape in it is tampering, not a pattern"
        )
    # NO "is the matcher a valid regex?" check, deliberately -- see the twin's long-form note in
    # ``Faber.Eval.Matchers.check_matcher/1``. Short version: ``*`` is a real, in-use matcher meaning
    # "every tool" and it does NOT compile as a regex; and "valid regex" is engine-dependent, with
    # the deciding engine (Claude Code's JavaScript ``RegExp``) being neither PCRE nor Python ``re``.
    # The check failed real hooks to catch a hypothetical typo, and the parity suite would have
    # called both engines being wrong together "agreement".
    return True, f"pointer: {event} / {matcher}"


MATCHERS = {
    "hook_shebang": hook_shebang,
    "hook_reads_stdin": hook_reads_stdin,
    "hook_pointer": hook_pointer,
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
