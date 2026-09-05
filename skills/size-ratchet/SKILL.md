---
name: size-ratchet
description: "Load to add, tune, or debug document byte ceilings and SIZE_RATCHET_* settings."
summary: "Hard byte ceilings for tracked Markdown documents, with path classes and reasoned exclusions."
license: MIT
user-invocable: true
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
  version: "1.0.0"
tags: [automation]
---

# Size Ratchet

Run the document byte-ceiling check before review and in CI. The growth-guards pre-commit chain uses the staged mode.

```bash
.agents/skills/size-ratchet/scripts/size-ratchet
.agents/skills/size-ratchet/scripts/size-ratchet --staged
```

Split an over-limit document at a natural seam, move detail to a linked reference, or delete content the code or another document already states. A document that must stay whole gets a row in the configured excludes file with its reason. Class selection and the exclusion format are [references/policy.md](references/policy.md). Flags, settings and exit codes are in `size-ratchet --help`.
