# review-gate

A GitHub merge check for code review. Repository owners configure which reviewers and review results can approve the current PR commit.

## Install

Your test checks must run on every push, or run in a merge queue that requires them. A skipped test job can otherwise count as satisfied.

- Install and commit the skill with `kendex add vanillagreencom/kendex --skill review-gate`.
- Copy the installed `templates/review-gate-writer.yml` into `.github/workflows/` without changes.
- Add a CI step that runs the installed `scripts/validate.sh`.
- Require `REVIEW_GATE_CONTEXT` in the branch rules alongside the test checks.

Follow [references/adoption.md](references/adoption.md) for workflow and branch-rule setup.

## Features

- Accept configured review approvals, analysis results and operator overrides.
- Block approval while review objections or unresolved threads remain.
- Check that the installed workflow and settings are valid.
- Report PRs that need attention.

## How it works

Your GitHub workflow reads each open PR's current commit and review results. The gate evaluates those results against your trusted-reviewer settings. The workflow posts the result as a commit status. Your branch rules require that status before merging. Test results remain separate required checks.

## Settings

Set `REVIEW_GATE_*` values in `kendex.settings.toml` under `[env]`. Environment values override the file.

## Class policy

Set `REVIEW_GATE_CLASS_POLICY = "render:none;trivial:none;micro:none;small:bot;standard:current"` to apply this policy to the class from the shared `harness-ci` classifier.

| Change class | Review evidence | Review threads |
|---|---|---|
| `render` | Not required | Not read |
| `trivial` | Not required | Not read |
| `micro` | Not required | Not read |
| `small` | One normal bot round | Enforced |
| `standard` | Current review-gate behavior | Current review-gate behavior |

The empty default disables this table and preserves the existing gate behavior. The `render`, `trivial`, and `micro` rows exempt the review-gate status, and every consumer of `scripts/review-policy` applies the same answer: the orch skill's reviewer wait and thread gates, and the `pr-merge` review-thread gate. Required CI checks, commit guards, and merge conflicts keep their existing enforcement.

- `REVIEW_GATE_CONTEXT` names the required commit status.
- Select trusted reviewer logins and check names using [references/settings.md](references/settings.md).
- When the class policy is inactive, `REVIEW_GATE_DOCS_ONLY = "none"` lets a docs-only PR pass without bot review evidence. The shared CI classifier decides which paths qualify, then `REVIEW_GATE_CARRY_FORWARD_EXCLUDE` removes policy paths from the waiver. Review objections, suppressed findings, and unresolved threads still block.
- The same reference defines when approval may carry forward after a documentation or generated-file change.
- When the class policy is inactive, `REVIEW_GATE_RENDER_PATHS` names the harness render trees the repo commits as kendex output. A PR whose entire diff sits under them is approved without review evidence, and its CI checks still decide the merge. Any file outside the set, or a diff the gate cannot enumerate, takes the normal path.
- `REVIEW_GATE_MODE = "off"` disables review evaluation when the class policy is inactive or resolves to `current`. A `bot` class still requires its review round.

`REVIEW_GATE_CHECK_RUN_NAME` is a GitHub repository variable for the optional check-run trigger. Set it in GitHub Actions variables, not in the settings file.
