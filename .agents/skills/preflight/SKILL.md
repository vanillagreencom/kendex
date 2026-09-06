---
name: preflight
description: "Load to run, tune, or debug preflight."
summary: "Diff-scoped fail-only checks over one change: shell safety, unwired suites, scratch directories, temp paths, dead path citations, applied migrations and data syntax."
license: MIT
user-invocable: true
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
  version: "1.0.0"
tags: [review, testing]
---

<!-- kendex:project-instructions:start -->
## Project Instructions

<!-- kendex:shared-instructions:start -->
Problems with a kendex-owned skill go through `kendex report`; check ownership in the file first.
<!-- kendex:shared-instructions:end -->
<!-- kendex:project-instructions:end -->

# Preflight

Run preflight in the validate step, before the project's own validation command.

```bash
.agents/skills/preflight/scripts/preflight              # vs the default branch's merge base
.agents/skills/preflight/scripts/preflight --staged     # staged changes (pre-commit)
.agents/skills/preflight/scripts/preflight --all        # every tracked file, every line
```

A finding names the line the change added. Correct that line; never widen a lane's exclusions to clear it.

Lanes, scopes, settings, output and exit codes are in `preflight --help`. Diff construction and the `unwired-suite`, `data-syntax` and `applied-migration-edited` glob grammars are [references/lanes.md](references/lanes.md). Hook and CI wiring is [README.md](README.md) § Wiring.
