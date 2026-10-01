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
  version: "2.1.0"
tags: [review]
---

# Review operations

GitHub rulesets enforce approvals, stale-approval dismissal and review-thread resolution. This package watches pull requests, reports repository configuration and refreshes consumer installs. It posts no review status.

## Watching pull requests

Run `scripts/pr-watch.sh` through the harness's wake-up mechanism. Read its attention lines rather than watching review-state transitions. Output and exit codes: `pr-watch.sh --help`.

## Organization standard

Run `scripts/validate-standard.sh` for a read-only report. Run `scripts/provision-environment.sh --org ORG` from the organization owner's machine to provision app-secret environments. Settings and repository wiring: [references/adoption.md](references/adoption.md).

## Consumer refresh

An existing consumer first follows [references/adoption.md § Trusted removal for an existing consumer](references/adoption.md#trusted-removal-for-an-existing-consumer). Automatic refresh runs only after that normally reviewed removal merges. Fresh installs use `scripts/adopt-refresh.sh` to adopt the refresh workflow. Environment and token requirements: [references/adoption.md § Automatic consumer refresh](references/adoption.md#automatic-consumer-refresh).

## 4. Operations

A pull request with no automatic review needs a manual request: `gh pr edit <PR> --add-reviewer @copilot`. Ruleset targeting and request failures: [references/automatic-review.md](references/automatic-review.md).

The overseer's fallback approval and emergency merge follow the managing repository's merge workflow. This package grants no bypass and changes no ruleset.

## Scripts

| Script | Purpose |
| --- | --- |
| `scripts/pr-watch.sh` | Reduce open pull requests to attention lines from GitHub's review state. |
| `scripts/validate-standard.sh` | Report rulesets, required checks, app installation and secret placement. |
| `scripts/provision-environment.sh` | Provision the organization's declared app-secret environment. |
| `scripts/adopt-refresh.sh` | Adopt the refresh workflow. `--retire-writer` opts into trusted retirement. |
| `scripts/install-latest.sh` | Install the latest stable release selected at run time before refresh. |
| `scripts/refresh-consumer.sh` | Rebuild the rolling refresh branch from the default branch and open or update its pull request at any measured class. Refuse held render edits before workflow adoption or publication. Preserve workflow edits under the [adoption contract](references/adoption.md#automatic-consumer-refresh). Only `render` arms app-token auto-merge. A `standard` refresh pull request stays unarmed; its body names the class, classifier cause and path. A repository maintainer reviews and merges it through the normal review and CI gates. An unmeasured class stops publication. |
| `scripts/refresh-reviews.sh` | Handle automatic review findings under the [thread-resolution rules](references/adoption.md#automatic-consumer-refresh). |
| `scripts/dispatch-refresh.sh` | Signal consumers visible to the catalog app installation. |

Reviewer routing for installed packages: [references/vendored-paths.md](references/vendored-paths.md).
