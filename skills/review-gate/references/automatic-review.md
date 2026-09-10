# Automatic review and the base branch

Which pull requests draw GitHub's automatic Copilot review, and what to do when one does not. The gate reads evidence and never requests a review; this file names where the evidence comes from.

## What arms the reviewer

| Fact | Value |
|---|---|
| Arming mechanism | an active branch ruleset carrying a rule of type `copilot_code_review` |
| Set of bases that draw a review | that ruleset's `conditions.ref_name` — the `include` patterns, minus the `exclude` patterns |
| Pattern forms | `~ALL` (every branch), `~DEFAULT_BRANCH` (the repo default), any other pattern as an fnmatch over `refs/heads/<base>` |
| Re-review on a new head | the rule's `review_on_push` parameter |
| Draft pull requests | the rule's `review_draft_pull_requests` parameter |

Read a repo's own set with `gh api repos/<owner>/<repo>/rulesets`, then the detail of each `target: "branch"`, `enforcement: "active"` entry.

The target set is per-repo configuration, not GitHub behaviour. In `vanillagreencom/kendex` it is ruleset `16519713`, "Copilot review for default branch", whose `conditions.ref_name.include` is `["~DEFAULT_BRANCH"]`. A pull request based on any branch other than `main` therefore draws no automatic review in this repo. A repo whose ruleset targets more branches reviews stacked pull requests.

## When no review arrives

| Situation | Action |
|---|---|
| The base is outside the target set | request the reviewer by hand: `gh pr edit <PR#> --add-reviewer @copilot`. It works on a base the ruleset does not target |
| The manual request draws nothing | close the pull request and open a fresh one against the default branch |
| The reviewer already reviewed this pull request once and a new review is needed | reopen it, which re-arms the reviewer |
| The reviewer never reviewed this pull request | reopening does nothing. Only the manual request, or a new pull request against a targeted base, draws one |

Evidence for the manual route: probe pull request `vanillagreencom/kendex#2527`, based on `ken-1329-probe-base`, which the ruleset does not target. `gh pr edit 2527 --add-reviewer @copilot` was accepted, and `copilot_work_started` followed 36 seconds later.

## What the waiter reports

Orch's `approval-wait` resolves the same target set once per wait and matches the pull request's `baseRefName` against it. Reviewer silence on a base outside the set is reported as status `unreviewable` (exit 1), never the fail-open `proceeded`. Its JSON carries `base_ref`, `auto_review_targeted`, `auto_review_target_source` and `auto_review_targets`. Full contract: `approval-wait --help`. The stacked-chain sequence is orch's `references/gates.md` § Stacked pull requests.
