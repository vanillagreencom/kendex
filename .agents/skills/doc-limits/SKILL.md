---
name: doc-limits
description: "Load to add, tune, or debug document byte ceilings and DOC_LIMITS_* settings."
summary: "Byte limits for the Markdown a harness loads at every turn: an AGENTS.md, CLAUDE.md, GEMINI.md or SKILL.md over its limit fails. Path classes set the limits, with reasoned exclusions."
license: MIT
user-invocable: true
dependencies:
  required: [commit-guards]
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
tags: [automation]
---

<!-- kendex:project-instructions:start -->
## Project Instructions

<!-- kendex:shared-instructions:start -->
Problems with a kendex-owned skill go through `kendex report`; check ownership in the file first.
<!-- kendex:shared-instructions:end -->
<!-- kendex:project-instructions:end -->

# Doc Limits

Run the document byte-ceiling check before review and in CI. The commit-guards pre-commit and pre-push chains use the staged mode; at push the index is held equal to HEAD first, so that mode measures the tree being pushed.

```bash
.agents/skills/doc-limits/scripts/doc-limits
.agents/skills/doc-limits/scripts/doc-limits --staged
```

The check measures `AGENTS.md`, `CLAUDE.md`, `GEMINI.md` and `SKILL.md`, at the root and at any depth, and no other file. A document over its limit fails the check. [references/policy.md § Path classes](references/policy.md#path-classes) says how a class sets a ceiling among those files.

A document that must stay whole gets a row in the configured excludes file with its reason. Class selection and the exclusion format are [references/policy.md](references/policy.md). Flags, settings and exit codes are in `doc-limits --help`.
