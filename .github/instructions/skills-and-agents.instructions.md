---
applyTo: "skills/**,agents/**"
---

- Skill and agent markdown follows mechanism-over-prose: do not propose
  defensive caveat paragraphs, history notes, or editorializing in
  always-loaded content (`SKILL.md`, agent definitions) — propose a concrete
  mechanism (validation, script, schema) or nothing.
- Issue-number citations are banned in instruction-flow skill/agent markdown,
  but `skills/*/schemas/*.md` reference docs carry issue provenance by
  established convention — do not flag citations there.
- Shell scripts and tests must stay Bash 3.2-compatible: flag `mapfile`,
  `declare -A`, `${var,,}` and other Bash 4+ constructs as real defects. New
  scripts and tests must carry the executable bit (CI lints this) — flag
  files added without it.
