---
name: review-gate
description: "Load to watch pull requests, report the organization standard, or adopt consumer refresh."
summary: "GitHub review-state reducer, organization-standard report, environment provisioning and consumer refresh."
license: MIT
user-invocable: true
dependencies:
  required: [harness-ci]
  optional: [orch]
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
tags: [review]
---

<!-- kendex:project-instructions:start -->
## Project Instructions

<!-- kendex:shared-instructions:start -->
Problems with a kendex-owned skill go through `kendex report`; check ownership in the file first.
<!-- kendex:shared-instructions:end -->
<!-- kendex:project-instructions:end -->

# Review operations

GitHub rulesets enforce approvals, stale-approval dismissal and review-thread resolution. This package watches pull requests, reports repository configuration and refreshes consumer installs. It posts no review status.

## Watching pull requests

Run `scripts/pr-watch.sh` through the harness's wake-up mechanism. Read its attention lines rather than watching review-state transitions. Output and exit codes: `pr-watch.sh --help`.

## Organization standard

Run `scripts/validate-standard.sh` for a read-only report. Run `scripts/provision-environment.sh --org ORG` from the organization owner's machine to provision app-secret environments, adding `--repo ORG/NAME` to provision one repository. Settings and repository wiring: [references/adoption.md](references/adoption.md).

## Consumer refresh

An existing consumer first follows [references/adoption.md § Trusted removal for an existing consumer](references/adoption.md#trusted-removal-for-an-existing-consumer). Automatic refresh runs only after that normally reviewed removal merges. Fresh installs run `refresh/adopt-refresh.sh` from a kendex checkout at a release tag. Each consumer calls the shared workflow, which runs its scripts from that release checkout. Environment and token requirements: [references/adoption.md § Automatic consumer refresh](references/adoption.md#automatic-consumer-refresh).

Consumers refresh on a schedule or a manual run. An organization managed by fleet uses `fleet repos kendex-refresh` for immediate refresh dispatch. Dispatch requirements: [references/adoption.md § Immediate refresh](references/adoption.md#immediate-refresh).

## 4. Operations

A pull request with no automatic review needs a Copilot request. When orch is present, request through its mode owner, `approval-wait <PR#> --request-review --base-checkout PATH`, per orch's `references/gates.md` § Copilot requests, which routes its `off` and `fallback` answers. Without orch, request directly: `gh pr edit <PR#> --add-reviewer @copilot`. Ruleset targeting and request failures: [references/automatic-review.md](references/automatic-review.md).

The overseer's fallback approval and emergency merge follow the managing repository's merge workflow. This package grants no bypass and changes no ruleset.

## Scripts

| Script | Purpose |
| --- | --- |
| `scripts/pr-watch.sh` | Reduce open pull requests to attention lines from GitHub's review state. |
| `scripts/validate-standard.sh` | Report rulesets, required checks, app installation and secret placement. |
| `scripts/provision-environment.sh` | Provision the organization's declared app-secret environment. |
| `refresh/adopt-refresh.sh` in the release checkout | Adopt the refresh workflow. `--retire-writer` opts into trusted retirement. |
| `scripts/install-latest.sh` | Install the latest stable release for kendex CI and the retained writer template. |
| `refresh/refresh-consumer.sh` in the release checkout | Rebuild the rolling refresh branch from the default branch and open or update its pull request at any measured class or an unmeasured standard class. Run the classifier from the same release checkout. Refuse held render edits before workflow adoption or publication. Preserve workflow edits under the [adoption contract](references/adoption.md#automatic-consumer-refresh). Disarm an armed pull request before pushing a new head; a disarm GitHub refuses stops the run unless the pull request is queued, merged or closed. Wait for GitHub to show the published head before arming app-token auto-merge. A head that stays unseen produces an unarmed warning. If GitHub refuses the arm and calls the pull request clean, merge it directly on the pushed head. Confirm that the arm enabled auto-merge, queued or merged the pull request. The merge queue merges it once the required approval, thread resolution and checks pass. The body names the class, classifier cause and path. An unmeasured standard class uses full review and CI. A failed classifier or missing class line stops publication. Render publication requires measurement. |
| `refresh/refresh-reviews.sh` in the release checkout | Handle automatic review findings under the [thread-resolution rules](references/adoption.md#automatic-consumer-refresh). |

Reviewer routing for installed packages: [references/vendored-paths.md](references/vendored-paths.md).
