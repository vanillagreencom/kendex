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

- `REVIEW_GATE_CONTEXT` names the required commit status.
- Select trusted reviewer logins and check names using [references/settings.md](references/settings.md).
- The same reference defines when approval may carry forward after a documentation or generated-file change.
- `REVIEW_GATE_MODE = "off"` disables review evaluation. Its passing status means the gate is disabled.

`REVIEW_GATE_CHECK_RUN_NAME` is a GitHub repository variable for the optional check-run trigger. Set it in GitHub Actions variables, not in the settings file.
