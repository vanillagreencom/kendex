# Automatic review and the base branch

Which pull requests draw GitHub's automatic Copilot review, and what to do when one does not. The watcher reports review state and never requests a review.

## What arms the reviewer

A repository's automatic reviewer is configuration in its branch rulesets, not GitHub behaviour. Read a repo's own set with `gh api --paginate 'repos/<owner>/<repo>/rulesets?includes_parents=true'`, then the detail of each `target: "branch"`, `enforcement: "active"` entry through `gh api repos/<owner>/<repo>/rulesets/<id>`. An organization ruleset reaches that list only through `includes_parents=true`, and its entry reads `source_type: "Organization"`.

Two rule types arm a reviewer:

- A `copilot_code_review` rule is GitHub's native automatic review, described in the table below.
- A `workflows` rule requires a workflow that requests the reviewer itself. Its parameters name the workflow's repository, path, ref and commit. Read that workflow to learn which pull requests it requests a review on. When the review-gate skill is installed, its `references/adoption.md` § Central Copilot request workflow describes one such workflow.

| Fact | Value |
|---|---|
| Arming mechanism | an active branch ruleset carrying a rule of type `copilot_code_review` |
| Set of bases that draw a review | the union over every such ruleset: a base draws one when a ruleset's `conditions.ref_name.include` covers it and the same ruleset's `exclude` does not |
| Pattern forms | `~ALL` (every branch), `~DEFAULT_BRANCH` (the repo default), any other pattern matched against `refs/heads/<base>` by `File.fnmatch` with `File::FNM_PATHNAME`, so `*` does not match `/` |
| Re-review on a new head | the rule's `review_on_push` parameter |
| Draft pull requests | the rule's `review_draft_pull_requests` parameter |

The target set is per-repo configuration. A ruleset whose `conditions.ref_name.include` is `["~DEFAULT_BRANCH"]` reviews only pull requests based on the default branch, so a stacked pull request draws no automatic review. A repo whose ruleset targets more branches reviews stacked pull requests.

## When no review arrives

| Situation | Action |
|---|---|
| The base is outside the target set | when orch manages the pull request, under `approval` its runtime's `verify-review` settles the pull request's Copilot request as orch's `references/gates.md` § Copilot requests says; request nothing by hand. Without orch, request directly: `gh pr edit <PR#> --add-reviewer @copilot`. The request works on a base the ruleset does not target |
| A direct request draws nothing | close the pull request and open a fresh one against the default branch. Under orch, follow orch's `references/gates.md` § Copilot requests instead |
| The reviewer already reviewed this pull request once and a new review is needed | reopen it, which re-arms the reviewer |
| The reviewer never reviewed this pull request | reopening does nothing. Only the manual request, or a new pull request against a targeted base, draws one |

Evidence for the manual route: probe pull request `vanillagreencom/kendex#2527`, based on `ken-1329-probe-base`, which the ruleset does not target. `gh pr edit 2527 --add-reviewer @copilot` was accepted, and `copilot_work_started` followed 36 seconds later.

## What orch reads

Orch's `verify-review` reads no automatic-review target set: under `approval` it settles a pull request's Copilot request as orch's `references/gates.md` § Copilot requests says, whatever base the rulesets target, and reviewer silence there is the ordinary review period's `timeout` or `proceeded`. The stacked-chain sequence is orch's `references/gates.md` § Stacked pull requests.
