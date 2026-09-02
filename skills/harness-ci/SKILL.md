---
name: harness-ci
description: "Load to wire, tune, or debug a repo's harness-only skip."
summary: "Classifies a CI diff as harness-only, every changed path under a kendex render tree, so heavy lanes can stand down; ships the classifier script and its tests."
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

# Harness CI

**One question, one answer: is this diff nothing but kendex render
output?** The classifier reads a diff's changed-file set and prints
`harness_only=true` when every path sits under `.agents/`, `.claude/`,
`.codex/`, `.opencode/`, `.cursor/`, `.pi/`, or is the root
`opencode.json`, or `opencode.jsonc` where a project carries that spelling.
Anything else prints `false`, and so does every diff the classifier cannot
read. A path the selected head tree's manifests (`kendex.toml`, and
`kendex-local.toml` where a source catalog keeps its installs) declare in
place, `.agents/skills/<name>` under `[skills.<name>] source = "in-place"`,
and any `.agents/hooks/` script are project source, never render output.

```bash
.agents/skills/harness-ci/scripts/harness-only \
  --event pull_request --base "$BASE_SHA" --head "$HEAD_SHA"
```

Flags and exit codes: `harness-only --help`. Contract and semantics:
[README.md](README.md). Workflow shapes to copy:
[references/wiring.md](references/wiring.md).

## This package never edits a workflow

Nothing here writes `.github/`. Wire the one step yourself, once, from
[references/wiring.md](references/wiring.md).

## The rules to hold when wiring it

**Classify inside a job, never in `on.<event>.paths`.** A path filter stops
the workflow from starting, the required context is never created, and a
merge queue waits forever on a check nothing will report.

**Keep the required-context job unconditional.** Gate the expensive lanes with
a job-level `if:` off a `changes` job's output, or a step-level `if:` inside
an aggregate, and let the aggregate that carries the required name run on
every event.

**A job-level `if:` needs a status function.** Without one it keeps the
implicit `success()` and skips the lane whenever the classifying job failed,
which stands the expensive lanes down on exactly the diffs nothing classified.
An aggregate accepts a `skipped` lane only after checking that the classifier
ran and cleared the diff.

**A lane reading a path family beside the verdict needs more than the status
function.** A dead classifying job publishes no outputs, so the family term
reads empty and skips the lane on its own. Lift it behind
`needs.changes.result != 'success'`, the two-gate shape in
[references/wiring.md](references/wiring.md).

## Reading a verdict

`stdout` is the verdict line alone; changed paths and reasons go to `stderr`;
exit `2` is a wiring error that prints no verdict.
[README.md](README.md) § Semantics.

## Fail-closed

Every unprovable case answers `false`, which runs every lane
([README.md](README.md) § Fail-closed). `--no-renames` is fixed.
