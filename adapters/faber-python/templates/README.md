# `templates/` — skill scaffolds in the Python idiom

The scaffold the proposer fills when emitting a new skill, so output matches conventions
rather than a generic shape.

For `faber-python` the `skill.md.tmpl` follows Claude Code SKILL.md structure (frontmatter,
"Iron Laws" section, presence-gated Workflow + Patterns, References) with one Python-idiom
touch: the worked example sits in a ` ```python ` fence. The Usage block always carries a
>=2-line example (usage comment + concrete snippet) so it satisfies the eval's `has_examples`
check the same way the built-in renderer's `## Examples` fence does.

Format: template file(s) with `{{placeholders}}` + a `manifest.yaml` naming each template and
the artifact type it `produces`.
