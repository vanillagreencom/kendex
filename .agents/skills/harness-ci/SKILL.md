---
name: harness-ci
description: "Load to wire, tune, or debug a repo's changed-file CI skip."
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

# Harness CI

Run the classifier to decide whether CI can skip product checks:

```bash
.agents/skills/harness-ci/scripts/harness-only \
  --event pull_request --base "$BASE" --head "$HEAD"
```

Commit `.kendex-generated.json` with the renders after `kendex refresh`.

Consumer setup and the workflow shapes to copy are in [references/wiring.md](references/wiring.md).

## Scripts

- `scripts/harness-only` answers `harness_only=true|false`. Flags and exit codes: `harness-only --help`. The endpoints: [references/wiring.md § The endpoint expressions](references/wiring.md#the-endpoint-expressions).
- `harness-only --mode docs` answers `docs_only=true|false` for the docs-only path set that `harness-only --help` defines.
- Declare exact product-text Markdown files through the trusted base's `HARNESS_CI_DOCS_PATHS`, by [references/wiring.md § Declared product text](references/wiring.md#declared-product-text).
- Use `harness-only --mode render-candidate` only to gate the engine installation and the mirror refresh. It grants no CI skip. `change-class` must prove render before CI skips product checks.
- `scripts/change-class` prints the change class: `render`, `trivial`, `micro`, `small` or `standard`. change-scope's `change-scope`, installed beside this package, decides the class. This package adds the queue-only class and the lane verdicts. Flags, the queue-only line and local lane selection: `change-class --help`. The classes, their settings, causes and refusals: `change-scope --help`.
- Required-context aggregators call `scripts/aggregate-needs`. Its arguments: `aggregate-needs --help`. The lane rules: [references/wiring.md § Per-lane verdicts](references/wiring.md#per-lane-verdicts).
- Install the release engine with `scripts/install-latest.sh`.

## Shared refresh caller ownership

The adopted caller path, `HARNESS_CI_REFRESH_CALLER`, and the render proof's fallback for it are change-scope's: its SKILL.md § Shared refresh caller ownership owns the contract. `scripts/lib/change-class.sh` here loads that library, so a sourcer of this file still reads the name.

## Wiring

Nothing here writes `.github/`. Wire the one step yourself, once, from [references/wiring.md](references/wiring.md).

A repository under the organization standard reports the aggregate `CI` context. It copies [templates/ci.yml](templates/ci.yml) to `.github/workflows/ci.yml`, or names its own workflow's aggregate job `CI`, per [references/wiring.md § The CI context](references/wiring.md#the-ci-context).

Hold these rules when wiring it:

- Classify inside a job, never in `on.<event>.paths`.
- Keep the required-context job unconditional.
  - Gate the expensive lanes with a job-level `if:` off a `changes` job's output, or a step-level `if:` inside an aggregate.
  - Let the aggregate that carries the required name run on every event.
- A step that installs a tool for an unconditional lane stays unconditional. A harness-only `if:` on the install, while the lane that runs the tool runs on every event, fails that lane on a harness-only diff. The tools commit-guards needs are in [commit-guards CHECKS.md § py-names](../commit-guards/CHECKS.md#py-names) and [§ secrets](../commit-guards/CHECKS.md#secrets).

## Fail-closed

- Every unprovable case answers `false`, which runs every lane. `change-class` answers `standard` on the same terms.
- A class is never read from an author-writable field: not a label, a branch name or a pull request title. No flag carries one.
- A caller that acts on a verdict without review runs the default branch's copy of the script against the pull request's tree, because the branch can change the script too.
