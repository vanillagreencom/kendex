---
name: harness-ci
description: "Load to wire, tune, or debug a repo's changed-file CI skip."
summary: "Classifies a CI diff as harness-only or docs-only, names its change class, and validates classifier-authorized skipped jobs in required-context aggregators."
license: MIT
dependencies:
  required: [orch]
user-invocable: true
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

# Harness CI

Run the classifier to decide whether CI can skip product checks. Commit `.kendex-generated.json` with the renders after `kendex refresh`. The engine writes that inventory from rendered artifacts. In-place content and carrier package source remain outside it.

```bash
.agents/skills/harness-ci/scripts/harness-only \
  --event pull_request --base "$BASE_SHA" --head "$HEAD_SHA"
```

Flags and exit codes: `harness-only --help`. Consumer setup: [README.md](README.md). Workflow shapes to copy: [references/wiring.md](references/wiring.md).

Use `--mode docs` for the docs-only path set that `harness-only --help` defines. It prints `docs_only=true|false`.

`scripts/change-class` answers the wider question every gate, workflow and lane asks: what kind of change is this diff. It prints one of `render`, `trivial`, `micro`, `small` and `standard`, takes the same event and endpoint flags, and hands every read of a diff range to `harness-only` or to orch's branch measurement rather than deriving one, the revision the base end of the range resolves to included. `render` is proved by re-rendering: `kendex verify --json` has to report files checked and none failed. Where the installed kendex takes `--at-record`, the proof passes it beside `--base`, so each package that follows its source renders at the commit the install record names, held to its source's history and to no older than the base's record, and a render the catalog has moved past since its push is still weighed and prints one `render-stale:` line per source commit it trails; an older kendex renders at each source's revision now and the log says `render-reading: current`; and each changed path has to be owned by a position a passing record of that run prints — a file, a tree, or keys in a shared file whose rest kendex reports unchanged since the range's base. Neither the inventory nor the install record is taken as proof of its own provenance, because the branch can rewrite both; each is owned from the record `kendex verify` prints for it, which passes only where the file is as kendex writes it. Every other changed path answers `standard` with `cause=render-path-unowned`, and a shared file kendex cannot vouch for answers `cause=render-path-partial`. A changed configuration or instruction source refuses every narrow class, not only `render`; the paths `trivial`, `micro` and `small` all refuse are orch's [narrow-change.conf](../orch/references/narrow-change.conf), whose ceilings are the last two classes' alone and which [micro.md](../orch/workflows/micro.md) § Escape condition 3 states in prose. Flags and settings: `change-class --help`.

Required-context aggregators call `scripts/aggregate-needs`. Pass the full `toJSON(needs)` object, the classifier job name, its verdict, and each job that the verdict may skip. The helper rejects a failed classifier, a failed or cancelled job, and a skipped job outside that explicit set.

## This package never edits a workflow

Nothing here writes `.github/`. Wire the one step yourself, once, from [references/wiring.md](references/wiring.md). A repository whose ruleset requires the one `CI` context copies [templates/ci.yml](templates/ci.yml) to `.github/workflows/ci.yml` and moves its lanes into it, per [references/wiring.md § The CI template](references/wiring.md#the-ci-template).

## The rules to hold when wiring it

**Classify inside a job, never in `on.<event>.paths`.** A path filter stops the workflow from starting, the required context is never created, and a merge queue waits forever on a check nothing will report.

**Keep the required-context job unconditional.** Gate the expensive lanes with a job-level `if:` off a `changes` job's output, or a step-level `if:` inside an aggregate, and let the aggregate that carries the required name run on every event.

**A job-level `if:` needs a status function.** Without one it keeps the implicit `success()` and skips the lane whenever the classifying job failed, which stands the expensive lanes down on exactly the diffs nothing classified. An aggregate accepts a `skipped` lane only after checking that the classifier ran and cleared the diff.

**A lane reading a path family beside the verdict needs more than the status function.** A dead classifying job publishes no outputs, so the family term reads empty and skips the lane on its own. Lift it behind `needs.changes.result != 'success'`, the two-gate shape in [references/wiring.md](references/wiring.md).

**A step that installs a tool for an unconditional lane stays unconditional.** A harness-only `if:` on the install, while the lane that runs the tool runs on every event, fails that lane on a harness-only diff. The tool commit-guards needs is [commit-guards CHECKS.md § py-names](../commit-guards/CHECKS.md#py-names).

## Reading a verdict

`stdout` is the selected verdict line alone; changed paths and reasons go to `stderr`; exit `2` is a wiring error that prints no verdict.

## Fail-closed

Every unprovable case answers `false`, which runs every lane ([DEVELOPMENT.md](DEVELOPMENT.md) § Invariants). `--no-renames` is fixed. `change-class` answers `standard` on the same terms.

**A class is never read from an author-writable field.** Not a label, not a branch name, not a pull request title, and no flag carries one: the author of the diff being judged writes all of them, so trusting one fails open on exactly the diffs that most want to pass. A caller that acts on a verdict without review runs the DEFAULT BRANCH's copy of the script against the pull request's tree, because the branch can change the script too.

**Nothing out of the judged tree runs, and nothing in it is read as configuration.** `change-class` fixes its measurement settings from its own process environment rather than loading the tree's `kendex.settings.toml`, and it runs `kendex verify` in a private checkout with a git directory of its own, which carries no kendex arming record, so no package's declared checker runs out of the tree under judgement.

**The judged checkout is read, never written, and never weighed.** The `render` proof weighs the commit `--head` resolves to, checked out privately, whatever the judged checkout's own HEAD is and whatever uncommitted content it holds.
