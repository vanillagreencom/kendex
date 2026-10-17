---
name: review-gate
description: "Load to report the organization standard or adopt consumer refresh."
summary: "Organization-standard report, environment provisioning and consumer refresh."
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

GitHub rulesets enforce approvals, stale-approval dismissal and review-thread resolution. This package reports repository configuration and refreshes consumer installs. It posts no review status. When the github skill is installed, its `scripts/pr-watch.sh` is the pull-request watcher.

## Organization standard

Run `scripts/validate-standard.sh` for a read-only report. Run `scripts/provision-environment.sh --org ORG` from the organization owner's machine to provision app-secret environments, adding `--repo ORG/NAME` to provision one repository. Settings and repository wiring: [references/adoption.md](references/adoption.md).

## Consumer refresh

An existing consumer first follows [references/adoption.md § Trusted removal for an existing consumer](references/adoption.md#trusted-removal-for-an-existing-consumer). Automatic refresh runs only after that normally reviewed removal merges. Fresh installs run `refresh/adopt-refresh.sh` from a kendex checkout at a release tag. Each consumer calls the shared workflow, which runs its scripts from that release checkout. Environment and token requirements: [references/adoption.md § Automatic consumer refresh](references/adoption.md#automatic-consumer-refresh).

Consumers refresh on a schedule or a manual run. An organization managed by fleet uses `fleet repos kendex-refresh` for immediate refresh dispatch. Dispatch requirements: [references/adoption.md § Immediate refresh](references/adoption.md#immediate-refresh).

## 4. Operations

A pull request with no automatic review needs a Copilot request. When orch is present, request through its mode owner, `approval-wait <PR#> --request-review --base-checkout PATH`, per orch's `references/gates.md` § Copilot requests, which routes its `off` and `fallback` answers. Without orch, request directly: `gh pr edit <PR#> --add-reviewer @copilot`. Ruleset targeting and request failures, when the github skill is installed: its `references/automatic-review.md`. The central request workflow: [references/adoption.md § Central Copilot request workflow](references/adoption.md#central-copilot-request-workflow).

The overseer's fallback approval follows the managing repository's merge workflow. An emergency merge past a failing required check exists only in a consumer whose required-checks or merge-queue ruleset lists a bypass actor. A consumer whose rulesets list no bypass has no emergency merge.

In that consumer, a merge group can fail to pass because a CI input read from the default branch broke: the classifier checkout, the lane declaration, the aggregate's needs or the change-class action. The overseer then asks the repository owner, or the person the owner delegates, by mailbox, naming the repair's pull request. The repository owner, or the person the owner delegates, restores the lanes app's merge-queue bypass through the API for that one repair, reads it back, and removes it after the repair. This package grants no bypass and changes no ruleset.

## Scripts

| Script | Purpose |
| --- | --- |
| `scripts/validate-standard.sh` | Report rulesets, required checks, app installation and secret placement. |
| `scripts/provision-environment.sh` | Provision the organization's declared app-secret environment. |
| `refresh/adopt-refresh.sh` in the release checkout | Adopt the refresh workflow. `--retire-writer` opts into trusted retirement. |
| `scripts/install-latest.sh` | Install the stable release on the trusted checkout's refresh caller major-tag commit. Use the latest stable release when the checkout has no refresh caller. |
| `refresh/refresh-consumer.sh` in the release checkout | Rebuild the rolling refresh branch from the default branch and open or update its pull request at any measured class or an unmeasured standard class. Run the classifier from the same release checkout. Refuse held render edits before workflow adoption or publication. Preserve workflow edits under the [adoption contract](references/adoption.md#automatic-consumer-refresh). Disarm an armed pull request before pushing a new head; a disarm GitHub refuses stops the run unless the pull request is queued, merged or closed. Wait for GitHub to show the published head. If successful branch reads show no rules and no protection, merge that head directly and report `refresh-state=merged`. A failed direct merge reports `refresh-error=merge` and exits with the merge status. A branch with rules or protection, or a failed branch read, keeps app-token auto-merge. A head that stays unseen produces an unarmed warning. If GitHub refuses the arm and calls the pull request clean, merge it directly on the pushed head. Confirm that the arm enabled auto-merge, queued or merged the pull request. The merge queue merges it once the required approval, thread resolution and checks pass. The body names the class, classifier cause and path. An unmeasured standard class uses full review and CI. A failed classifier or missing class line stops publication. Render publication requires measurement. |
| `refresh/refresh-reviews.sh` in the release checkout | Handle automatic review findings under the [thread-resolution rules](references/adoption.md#automatic-consumer-refresh). |

Reviewer routing for installed packages: [references/vendored-paths.md](references/vendored-paths.md).
