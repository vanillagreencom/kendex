---
name: doc-limits
description: "Load to add, tune, or debug document byte ceilings and DOC_LIMITS_* settings."
summary: "Hard byte ceilings for tracked Markdown documents, with path classes and reasoned exclusions."
license: MIT
user-invocable: true
dependencies:
  required: [commit-guards]
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
  version: "1.0.0"
tags: [automation]
---

# Doc Limits

Run the document byte-ceiling check before review and in CI. The commit-guards pre-commit chain uses the staged mode.

```bash
.agents/skills/doc-limits/scripts/doc-limits
.agents/skills/doc-limits/scripts/doc-limits --staged
```

Split an over-limit document at a natural seam, move detail to a linked reference, or delete content the code or another document already states. A document that must stay whole gets a row in the configured excludes file with its reason. Class selection and the exclusion format are [references/policy.md](references/policy.md). Flags, settings and exit codes are in `doc-limits --help`.
