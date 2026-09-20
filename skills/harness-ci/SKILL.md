---
name: harness-ci
description: "Load to wire, tune, or debug a repo's changed-file CI skip."
summary: "Classifies a CI diff as harness-only or docs-only, and validates classifier-authorized skipped jobs in required-context aggregators."
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

Run the classifier to decide whether CI can skip product checks. Commit `.kendex-generated.json` with the renders after `kendex refresh`. The engine writes that inventory from rendered artifacts. In-place content and carrier package source remain outside it.

```bash
.agents/skills/harness-ci/scripts/harness-only \
  --event pull_request --base "$BASE_SHA" --head "$HEAD_SHA"
```

Flags and exit codes: `harness-only --help`. Consumer setup: [README.md](README.md). Workflow shapes to copy: [references/wiring.md](references/wiring.md).

Use `--mode docs` for the docs-only path set that `harness-only --help` defines. It prints `docs_only=true|false`.

Required-context aggregators call `scripts/aggregate-needs`. Pass the full `toJSON(needs)` object, the classifier job name, its verdict, and each job that the verdict may skip. The helper rejects a failed classifier, a failed or cancelled job, and a skipped job outside that explicit set.

## This package never edits a workflow

Nothing here writes `.github/`. Wire the one step yourself, once, from [references/wiring.md](references/wiring.md).

## The rules to hold when wiring it

**Classify inside a job, never in `on.<event>.paths`.** A path filter stops the workflow from starting, the required context is never created, and a merge queue waits forever on a check nothing will report.

**Keep the required-context job unconditional.** Gate the expensive lanes with a job-level `if:` off a `changes` job's output, or a step-level `if:` inside an aggregate, and let the aggregate that carries the required name run on every event.

**A job-level `if:` needs a status function.** Without one it keeps the implicit `success()` and skips the lane whenever the classifying job failed, which stands the expensive lanes down on exactly the diffs nothing classified. An aggregate accepts a `skipped` lane only after checking that the classifier ran and cleared the diff.

**A lane reading a path family beside the verdict needs more than the status function.** A dead classifying job publishes no outputs, so the family term reads empty and skips the lane on its own. Lift it behind `needs.changes.result != 'success'`, the two-gate shape in [references/wiring.md](references/wiring.md).

**A step that installs a tool for an unconditional lane stays unconditional.** A harness-only `if:` on the install, while the lane that runs the tool runs on every event, fails that lane on a harness-only diff. The tool commit-guards needs is [commit-guards CHECKS.md § py-names](../commit-guards/CHECKS.md#py-names).

## Reading a verdict

`stdout` is the selected verdict line alone; changed paths and reasons go to `stderr`; exit `2` is a wiring error that prints no verdict.

## Fail-closed

Every unprovable case answers `false`, which runs every lane ([DEVELOPMENT.md](DEVELOPMENT.md) § Invariants). `--no-renames` is fixed.
