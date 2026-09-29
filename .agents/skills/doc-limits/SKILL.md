---
name: doc-limits
description: "Load to add, tune, or debug document byte ceilings and DOC_LIMITS_* settings."
summary: "Hard byte ceilings for tracked Markdown and documentation HTML, with path classes and reasoned exclusions."
license: MIT
user-invocable: true
dependencies:
  required: [commit-guards, docs-writing]
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
  version: "1.0.0"
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
.agents/skills/doc-limits/scripts/doc-limits --against "$(git merge-base HEAD origin/main)"
```

`--against` takes the tree the change is measured from; which tree a pull request run and a local run pass, and which CI events to run the check on, are in [references/policy.md § Growth margin](references/policy.md#growth-margin).

Split an over-limit document at a natural seam, move detail to a linked reference, or delete content the code or another document already states. A document that must stay whole gets a row in the configured excludes file with its reason. The docs-writing rule for the document's class, under [§ Per file type](../docs-writing/SKILL.md#per-file-type), decides which of these the document admits; each finding names that rule. Class selection and the exclusion format are [references/policy.md](references/policy.md). Flags, settings and exit codes are in `doc-limits --help`.
