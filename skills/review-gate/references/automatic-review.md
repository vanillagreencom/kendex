# Automatic review and the base branch

Which pull requests draw GitHub's automatic Copilot review, and what to do when one does not. The watcher reports review state and never requests a review.

## What arms the reviewer

For the organization refresh exception, require `.github/workflows/request-copilot-review.yml` from `vanillagreencom/kendex` through a `workflows` rule. Pin `sha` to the merged commit that holds the reviewed workflow, with `ref: refs/heads/main` and kendex's repository ID. Replace the `copilot_code_review` rule only after that commit exists. Preserve every other rule, condition and the empty bypass list. The organization owner reads and updates the ruleset with their own credential. This package changes no ruleset.

Review-gate owns that central workflow in kendex's own `.github/workflows/`, beside `refresh-consumer.yml`. Consumers copy and render none of it. It requests `copilot-pull-request-reviewer[bot]` through GitHub's REST review-request endpoint for every non-draft pull request except the exact `kendex/refresh` head authored by `vanillagreen-fleet-lanes[bot]`. A failed request emits a warning and passes. GitHub's approval, stale-approval dismissal and thread-resolution rules still enforce review. The workflow still triggers on merge groups, but its job skips there without allocating a runner.

A draft pull request gets no automatic review request. A ready cloud head with no review gets its request through the overseer's existing `awaiting-stale` route, per orch's references/copilot-head-notices.md § Fallback approval. Ruleset workflows ignore activity filters, so adding `ready_for_review` does not trigger this workflow. A pull request outside a lane gets its automatic request on its next non-draft push.

GitHub supports a public ruleset workflow in any repository in the organization, including private consumers. Ruleset workflows support `pull_request_target` and `merge_group`. The central workflow uses the base repository's token and executes no pull-request content. See [ruleset workflow visibility](https://docs.github.com/en/enterprise-cloud@latest/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets#using-a-workflow-file), [supported events](https://docs.github.com/en/enterprise-cloud@latest/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/troubleshooting-rules#supported-ruleset-workflow-events), [Copilot REST requests](https://docs.github.com/en/copilot/how-tos/copilot-on-github/use-copilot-agents/copilot-code-review) and [workflows rule fields](https://docs.github.com/en/rest/orgs/rules#update-an-organization-repository-ruleset).

The organization standard requires that `workflows` rule: `validate-standard.sh`'s `standard-ruleset-source` row judges its repository and path only, since the owner re-pins `sha` on each workflow change, and no longer requires `copilot_code_review`. Its `standard-copilot-review` row also judges the ref and a full commit SHA. In `vanillagreencom/kendex`, organization ruleset `24148602` carries the `workflows` rule and no `copilot_code_review` rule. Where an organization ruleset still carries the automatic rule, the native mechanism below still applies. Orch's waiter reads that native mechanism only; after replacement, its manual request route handles a base without a native automatic rule. Refresh approval follows orch's references/copilot-head-notices.md § Consumer refresh approval instead.

| Fact | Value |
|---|---|
| Arming mechanism | an active branch ruleset carrying a rule of type `copilot_code_review` |
| Set of bases that draw a review | the union over every such ruleset: a base draws one when a ruleset's `conditions.ref_name.include` covers it and the same ruleset's `exclude` does not |
| Pattern forms | `~ALL` (every branch), `~DEFAULT_BRANCH` (the repo default), any other pattern matched against `refs/heads/<base>` by `File.fnmatch` with `File::FNM_PATHNAME`, so `*` does not match `/` |
| Re-review on a new head | the rule's `review_on_push` parameter |
| Draft pull requests | the rule's `review_draft_pull_requests` parameter |

Read a repo's own set with `gh api --paginate 'repos/<owner>/<repo>/rulesets?includes_parents=true'`, then the detail of each `target: "branch"`, `enforcement: "active"` entry through `gh api repos/<owner>/<repo>/rulesets/<id>`. An organization ruleset reaches that list only through `includes_parents=true`, and its entry reads `source_type: "Organization"`.

The target set is per-repo configuration, not GitHub behaviour. In `vanillagreencom/kendex` it is organization ruleset `24148602`, "main protections (zero-bypass)", whose `conditions.ref_name.include` is `["~DEFAULT_BRANCH"]`. A pull request based on any branch other than `main` therefore draws no automatic review in this repo. A repo whose ruleset targets more branches reviews stacked pull requests.

## When no review arrives

| Situation | Action |
|---|---|
| The base is outside the target set | when orch is present, request the reviewer through its mode owner, `approval-wait <PR#> --request-review --base-checkout PATH`, per orch's `references/gates.md` § Copilot requests, which routes its `off` and `fallback` answers. Without orch, request directly: `gh pr edit <PR#> --add-reviewer @copilot`. The request works on a base the ruleset does not target |
| The request, after an `approval` answer or made directly, draws nothing | close the pull request and open a fresh one against the default branch |
| The reviewer already reviewed this pull request once and a new review is needed | reopen it, which re-arms the reviewer |
| The reviewer never reviewed this pull request | reopening does nothing. Only the manual request, or a new pull request against a targeted base, draws one |

Evidence for the manual route: probe pull request `vanillagreencom/kendex#2527`, based on `ken-1329-probe-base`, which the ruleset does not target. `gh pr edit 2527 --add-reviewer @copilot` was accepted, and `copilot_work_started` followed 36 seconds later.

## What the waiter reports

Orch's `approval-wait` resolves the same target set once per wait and matches the pull request's `baseRefName` against it. It compares `~ALL`, `~DEFAULT_BRANCH` and literal refs only. A set holding any glob pattern (`*`, `?`, `[` or `\`) is `unresolved`, and so is a set behind a failed ruleset read other than a permission denial. Reviewer silence on a base outside the set is reported as status `unreviewable` (exit 1), and on an `unresolved` set as `timeout`; neither is the fail-open `proceeded`. Its JSON carries `base_ref`, `auto_review_targeted`, `auto_review_target_source` and `auto_review_targets`. Full contract: `approval-wait --help`. The stacked-chain sequence is orch's `references/gates.md` § Stacked pull requests.
