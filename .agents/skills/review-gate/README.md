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

| Change class | Review evidence | Review threads | Objections and suppressed findings |
|---|---|---|---|
| `render` | Not required | Bot threads resolved at merge; a person's thread blocks | Not read |
| `trivial` | Not required | Bot threads resolved at merge; a person's thread blocks | Not read |
| `micro` | Not required | Bot threads resolved at merge; a person's thread blocks | Not read |
| `small` | One normal bot round | Enforced | Enforced |
| `standard` | Current review-gate behavior | Current review-gate behavior | Current review-gate behavior |

`trivial` holds every diff inside the classifier's documentation path set, whatever its size, so a plan under `docs/` of any length takes that row. A repository allowlist in `HARNESS_CI_TRIVIAL_PATHS` replaces that set and keeps a line ceiling (`change-class --help`).

A `none` row puts the pull request OUTSIDE the review gate: no review evidence, no thread wait, no standing objection and no suppressed finding is read for it, because a gate that cannot stop a bot from commenting must not run on a change it waives. What stays enforced is everything outside that gate — required CI checks, commit guards and merge conflicts — and the orch merge path still refuses a `CHANGES_REQUESTED` review at its readiness check, in every mode.

A base branch's own thread-resolution rule is outside the gate too, and it still holds the merge on every open thread. So the `pr-merge` route resolves each thread a bot opened on a `none`-row pull request, as its last step before it merges or arms: one reply naming the class and `REVIEW_GATE_CLASS_POLICY`, then a resolve. A thread a person opened still blocks it. `pr-merge --help` § Review-thread gate holds the contract.

The table is applied only where the shared classifier measured a class, which it says on its own answer. It needs both endpoints present in the checkout, an ancestor they share, a readable generated-file inventory at the base end, and the `orch` skill beside `harness-ci` for its `references/narrow-change.conf` list and its `scripts/lib/branch-growth.sh` measurer. Missing any of those, the classifier falls back to `standard` and marks the answer unmeasured, and `review-policy` exits 2 naming the reason rather than apply a row to a class nothing earned. Fix what the reason names, then ask again.

CI's writer workflow runs the review predicate for each open PR and posts the gate status. A control host running orch's `oversee-watch` runs the same predicate locally on each `pr-watch.sh --heal` pass to find a stale status, and posts nothing itself. On both hosts the predicate refreshes the PR's kendex sources only when every changed path is a generated file, because only the `render` check reads them. Every other diff is classified without refreshing kendex sources. A refresh that passes its time limit fails that PR's evaluation with `predicate-policy-refresh-deadline`, naming the PR and the limit, and the next pass tries again. CI shows that line in the writer's job log. The control host shows it in the `error` line `pr-watch.sh` prints for that PR.

The empty default disables this table and preserves the existing gate behavior. Every consumer of `scripts/review-policy` applies the same answer: the orch skill's reviewer wait and thread gates, orch's micro admission, and the `pr-merge` review-thread gate.

- `REVIEW_GATE_CONTEXT` names the required commit status.
- Select trusted reviewer logins and check names using [references/settings.md](references/settings.md).
- When the class policy is inactive, `REVIEW_GATE_DOCS_ONLY = "none"` lets a docs-only PR pass without bot review evidence. The shared CI classifier decides which paths qualify, then `REVIEW_GATE_CARRY_FORWARD_EXCLUDE` removes policy paths from the waiver. Review objections, suppressed findings, and unresolved threads still block.
- The same reference defines when approval may carry forward after a documentation or generated-file change.
- When the class policy is inactive, `REVIEW_GATE_RENDER_PATHS` names the harness render trees the repo commits as kendex output. A PR whose entire diff sits under them is approved without review evidence, and its CI checks still decide the merge. Any file outside the set, or a diff the gate cannot enumerate, takes the normal path.
- `REVIEW_GATE_MODE = "off"` disables review evaluation when the class policy is inactive or resolves to `current`. A `bot` class still requires its review round.

`REVIEW_GATE_CHECK_RUN_NAME` is a GitHub repository variable for the optional check-run trigger. Set it in GitHub Actions variables, not in the settings file.
