---
name: review-gate
description: "Load to adopt or operate consumer refresh."
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

# Review operations

This package refreshes kendex installs in consumer repositories. GitHub rulesets enforce approvals, stale-approval dismissal and review-thread resolution.

## Consumer refresh

- A fresh install runs `refresh/adopt-refresh.sh` from a kendex checkout at a release tag.
- An organization managed by fleet uses `fleet repos kendex-refresh` for immediate refresh dispatch.

## 4. Operations

A pull request with no automatic review needs a Copilot request.

- When orch is present, its runtime's `verify-review` settles that request under `approval`, as orch's `references/gates.md` § Copilot requests says.
- Without orch, request it directly: `gh pr edit <PR#> --add-reviewer @copilot`.
- When the github skill is installed, its `references/automatic-review.md` covers ruleset targeting and request failures.

An emergency merge past a failing required check exists only in a consumer whose required-checks or merge-queue ruleset lists the overseer app as a bypass actor.

- That merge bypasses only those rulesets. Approval and thread resolution still apply.
- A consumer whose rulesets do not list that app has no emergency merge.
- The landing app's bypass gives no emergency merge.

In a consumer with no emergency merge, a merge group can fail to pass because a CI input read from the default branch broke: the classifier checkout, the lane declaration, the aggregate's needs or the change-class action. The overseer then asks the repository owner, or the person the owner delegates, by mailbox. The message names the broken input and the repair's pull request. The repository owner, or the person the owner delegates, then:

1. Adds a bypass for their own credential to the required-checks and merge-queue rulesets through the API.
2. Reads both rulesets back.
3. Merges that one repair head with `gh pr merge <N> --admin --match-head-commit <SHA>`.
4. Removes both bypasses.
5. Reads both rulesets back.
6. Records the bypass and its removal on the repair's work item.

No lane runs a raw `--admin` merge. The repair gives no app token a merge path.

## Scripts

| Script | Purpose |
| --- | --- |
| `scripts/validate-standard.sh` | Deprecated path for [GitHub repository settings' report](../github-repository-settings/references/platform-checks.md). |
| `refresh/adopt-refresh.sh` in the release checkout | Adopt the refresh workflow. |
| `scripts/install-latest.sh` | Deprecated entry point for harness-ci's `scripts/install-latest.sh`. |
| `refresh/refresh-consumer.sh` in the release checkout | Rebuild the rolling refresh branch, and publish or land its new head. |
| `refresh/refresh-reviews.sh` in the release checkout | Handle automatic review findings. |

- `scripts/validate-standard.sh` warns and forwards until 2.0.
- `scripts/install-latest.sh` warns and forwards until the next major release.
- `refresh/refresh-consumer.sh` publishes, arms and lands under [references/adoption.md § Publication](references/adoption.md#publication).
- `refresh/refresh-reviews.sh` follows the thread-resolution rules in [references/adoption.md § Automatic review threads](references/adoption.md#automatic-review-threads).

## Read when

- Before adopting the refresh workflow in a consumer, or provisioning its environment and app credentials: [references/adoption.md § Caller adoption contract](references/adoption.md#caller-adoption-contract) and § Adoption and file ownership.
- Before enabling automatic refresh, and when a refresh run's schedule or cancel does not do what you expect: [references/adoption.md § Automatic consumer refresh](references/adoption.md#automatic-consumer-refresh).
- When a refresh run prints a `refresh-state=` or `refresh-verify=` line, `refresh-error=merge` or `refresh-error=verify`: [references/adoption.md § Publication](references/adoption.md#publication).
- When adoption stops with `refresh-error=caller-secrets`, `refresh-error=environment` or `refresh-error=workflow-edited`: [references/adoption.md § Caller adoption contract](references/adoption.md#caller-adoption-contract).
- When a refresh run prints `refresh-error=` with `workflow-symlink`, `workflow-changed`, `template-edited`, `template-changed`, `read`, `render-edited`, `bot-instructions-render` or `refresh`: [references/adoption.md § Adoption and file ownership](references/adoption.md#adoption-and-file-ownership).
- When a refresh run prints a `refresh-land=` line or `refresh-error=land-check`, before storing the landing pair, and before changing a ruleset for the landing app: [references/adoption.md § Landing a proved render](references/adoption.md#landing-a-proved-render).
- When an automatic review thread on a rolling refresh pull request is unanswered, or its run fails on one: [references/adoption.md § Automatic review threads](references/adoption.md#automatic-review-threads).
- When a fix cannot wait for the schedule: [references/adoption.md § Immediate refresh](references/adoption.md#immediate-refresh).
- When a pull request got no automatic Copilot request: [references/adoption.md § Central Copilot request workflow](references/adoption.md#central-copilot-request-workflow).
- Before changing an organization's rulesets or its central Copilot request workflow: [references/adoption.md § Repo-side wiring](references/adoption.md#repo-side-wiring) and § Central Copilot request workflow.
- Before wiring reviewer instructions for a vendored tree or a committed `kendex refresh` render: [references/vendored-paths.md](references/vendored-paths.md).
