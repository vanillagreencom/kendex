---
name: doc-limits
description: "Load to add, tune, or debug document byte ceilings and DOC_LIMITS_* settings."
license: MIT
user-invocable: true
metadata:
  author: "vanillagreen"
  source: "kendex"
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
---

<!-- kendex:project-instructions:start -->
## Project Instructions

<!-- kendex:shared-instructions:start -->
Problems with a kendex-owned skill go through `kendex report`; check ownership in the file first.
<!-- kendex:shared-instructions:end -->
<!-- kendex:project-instructions:end -->

# Doc Limits

Run the document byte-ceiling check before review and in CI. The commit-guards pre-commit chain uses the staged mode.

```bash
.agents/skills/doc-limits/scripts/doc-limits
.agents/skills/doc-limits/scripts/doc-limits --staged
```

The check measures `AGENTS.md`, `CLAUDE.md`, `GEMINI.md` and `SKILL.md`, at the root and at any depth, and no other file.

Bring a document over its limit under that limit in this order:

1. Cut restated content first.
2. Split only at a real subject boundary.

Never delete a rule to fit.

Read [references/policy.md](references/policy.md) to choose a class or write an exclusion. Flags, settings and exit codes are in `doc-limits --help`.
