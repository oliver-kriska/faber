# `templates/` — skill / agent / hook scaffolds in the stack's idiom

What goes here: the scaffolds the proposer fills when emitting a new artifact, so output
matches the stack's conventions (section order, frontmatter, idiomatic examples) rather
than a generic shape.

For `faber-elixir`, these mirror the plugin's own skill/agent/hook structure: `SKILL.md`
layout (Iron Laws section, quick patterns, frontmatter), agent definition shape
(`disallowedTools`, `omitClaudeMd` conventions), and hook scaffolds.

Format: template files with placeholders (e.g. `{{skill_name}}`) + a short manifest
naming each template and the artifact type it produces. Filled in M1.
