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
tags: [review, testing]
---

# Preflight

Run preflight in the validate step, before the project's own validation command.

```bash
.agents/skills/preflight/scripts/preflight              # vs the default branch's merge base
.agents/skills/preflight/scripts/preflight --staged     # staged changes (pre-commit)
.agents/skills/preflight/scripts/preflight --all        # every tracked file, every line
```

Fix what a finding reports. Never widen a lane's exclusions to clear it.

`preflight --help` gives the lanes, scopes, settings, output and exit codes.

- When setting a `PREFLIGHT_*_GLOBS` value, or when a finding turns on how the diff is taken or how `unwired-suite` reads a runner, read [references/lanes.md](references/lanes.md).
- When wiring preflight into a Git hook or CI, read [references/wiring.md](references/wiring.md).
