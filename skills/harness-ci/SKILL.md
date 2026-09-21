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

# Harness CI

Run the classifier to decide whether CI can skip product checks. Commit `.kendex-generated.json` with the renders after `kendex refresh`. The engine writes that inventory from rendered artifacts. In-place content and carrier package source remain outside it.

```bash
.agents/skills/harness-ci/scripts/harness-only \
  --event pull_request --base "$BASE_SHA" --head "$HEAD_SHA"
```

Flags and exit codes: `harness-only --help`. Consumer setup: [README.md](README.md). Workflow shapes to copy: [references/wiring.md](references/wiring.md).

Use `--mode docs` for the docs-only path set that `harness-only --help` defines. It prints `docs_only=true|false`.

`scripts/change-class` answers the wider question every gate, workflow and lane asks: what kind of change is this diff. It prints one of `render`, `trivial`, `micro`, `small` and `standard`, takes the same event and endpoint flags, and hands every read of a diff range to `harness-only` or to orch's branch measurement rather than deriving one, the revision the base end of the range resolves to included. `render` is proved by re-rendering: `kendex verify` has to report files checked and none failed, and each changed path has to be one that run itself names, which today is the Claude instruction shim it listed and nothing else. Neither the inventory nor the install record is taken as proof of its own provenance, because the branch can rewrite both, so every other changed path answers `standard` with `cause=render-path-unowned`: a re-rendered skill, agent, hook or command, and kendex's own `.kendex-lock.json` and `.kendex-generated.json` with them, so every refresh diff answers `standard`. That stands until KEN-1673 has `kendex verify` print the rendered positions of each row it prints for the classifier to own paths from. A changed configuration or instruction source refuses every narrow class, not only `render`; the paths `trivial`, `micro` and `small` all refuse are orch's [narrow-change.conf](../orch/references/narrow-change.conf), whose ceilings are the last two classes' alone and which [micro.md](../orch/workflows/micro.md) § Escape condition 3 states in prose. Flags and settings: `change-class --help`.

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

Every unprovable case answers `false`, which runs every lane ([DEVELOPMENT.md](DEVELOPMENT.md) § Invariants). `--no-renames` is fixed. `change-class` answers `standard` on the same terms.

**A class is never read from an author-writable field.** Not a label, not a branch name, not a pull request title, and no flag carries one: the author of the diff being judged writes all of them, so trusting one fails open on exactly the diffs that most want to pass. A caller that acts on a verdict without review runs the DEFAULT BRANCH's copy of the script against the pull request's tree, because the branch can change the script too.

**Nothing out of the judged tree runs, and nothing in it is read as configuration.** `change-class` fixes its measurement settings from its own process environment rather than loading the tree's `kendex.settings.toml`, and it refuses the `render` class outright in a checkout whose git directory carries a kendex arming record, because `kendex verify` would run that package's declared checker out of the tree under judgement.

**The judged checkout is read, never written, and it must be a commit.** A checkout with anything uncommitted is refused the `render` class: the proof would otherwise attest to whatever a step before the classifier left on disk. What the check establishes is that the tree matches the checkout's own HEAD, which the wiring shape makes the pull request's merge ref rather than `--head`; the ways those two commits differ all cost a package its row, never grant one. Nothing in the wiring writes there.
