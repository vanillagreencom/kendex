# Pull-request publication

Read when [submit-pr.md](../workflows/submit-pr.md) builds the pull request body, arms auto-merge, reruns a failed CI run or judges the merge gates, and when another workflow looks up one of those contracts. `[ISSUE_ID]` is the item's workflow-state key, and `[WORKTREE_PATH]` is the item's worktree.

## PR body

Read when building or rebuilding a pull request body.

Write the body to `[WORKTREE_PATH]/tmp/pr-body-[ISSUE_ID]-[TIMESTAMP].md` (`git-context timestamp compact`) with the harness file-write tool or `apply_patch`, never redirection or a heredoc.

```markdown
## Summary
[1-3 bullets describing the changes]

## Merge danger
- **Door:** [one-way or two-way. A change that deletes data, migrates a format or changes a published contract is one-way.]
- **Blast radius:** [who breaks if this is wrong]

## Context
- **[DECISION_ID]**: [ONE_LINE_SUMMARY] — `[DECISION_FILE_PATH]`
- **Research**: [TITLE] — `[RESEARCH_FILE_PATH]`

## Completed Issues
- Closes [ISSUE_REF] - [TITLE]
  - Closes [SUB_ISSUE_REF] - [SUB_TITLE]

## Done-when evidence
[N]: [PROOF]

## Created Issues
- [ISSUE_ID] - [TITLE] — Project: [PROJECT]

## QA Metrics
[Results from the QA agents that ran — project-configurable.]

## Merge decision
[Pending the merge attempt. The lane records the returned merge-route line here.]

## Proposed rules
[Each string in workflow state `pr_comment_review.proposed_rules`.]

## Test Plan
[Before-and-after evidence: the test that failed before and passes now, or the command output before and after.]
```

- Keep `## Merge decision` and `## Merge danger`: every change has a Door answer.
- On an existing pull request, keep its recorded merge decision through body updates. Use the pending text only before any attempt is recorded.
- Omit the other empty sections.
- Under `## Done-when evidence`, write one `N: text` line for each branch-provable Done-when box. `N` is the box's number in section order from 1. The text is its proving artifact at the head.
- Keep the `## Done-when evidence` section current on every body update. The runtime's close reads it where the lane cannot complete the item.
- Include each proposed rule once, and do not perform it.
- Take decision paths only from `decisions search --issue [ISSUE_ID]`.
- Check each decision path with `test -f [DECISION_FILE_PATH]`, one command per path. Omit a path that fails.
- Include qualified started bundle children in the child `Closes` lines: this pull request carries their implementation.
- For a GitHub item, save its live body from `gh issue view [N] --repo [OWNER/REPO] --json body --jq .body` under `tmp/` on every body build. Its classification under [SKILL.md § Tracker Resolution](../SKILL.md#tracker-resolution) picks `Refs` or `Closes`. A failed read stops the body build.

## Arm auto-merge

Read when [submit-pr.md § 2](../workflows/submit-pr.md#2-push-and-submit) step 5 arms a pull request.

Arm as soon as the pull request exists, on every pass through submit-pr.md § 2, for a pull request that will take the queue. The arm reads the merge route of [merge-pr.md § 5](../workflows/merge-pr.md#5-execute-the-merge) step 1, and arms nothing where that route takes the pull request past the queue.

- Arm only through `github.sh pr-merge --auto`. A raw `gh pr merge --auto` is never the arm.
- **Skip if** `.agents/skills/orch/scripts/orch-env ORCH_MERGE_AUTONOMY auto` prints anything but `auto`.
- **Skip if** workflow state `pr_order` reads `open-first` or `push-first`. The internal review of the pull request [start-worktree.md](../workflows/start-worktree.md) § 2.1 opened has not returned. The pass after [review-pr.md](../workflows/review-pr.md) § 9 arms it.

1. Read the bot token as [merge-pr.md § 4](../workflows/merge-pr.md#4-prepare) does. On `.configured: false`, arm nothing here: merge-pr.md § 4 decides whose name a merge lands under, and that workflow's § 4 and § 5 make the arm.

   ```bash
   .agents/skills/github/scripts/github.sh bot-token
   ```

2. Detach orphaned children before any arm.
   - **Skip if** workflow state already records `children_detached`: the detach runs once per item.
   - Run [merge-pr.md § 4.1](../workflows/merge-pr.md#41-detach-orphaned-children) for this item, `[ISSUE]` being `[ISSUE_ID]`, with its skip conditions and its per-orphan ask. A lane sends that ask through its ask gate.
   - An abort there arms nothing. Skip the rest of this section; [merge-pr.md](../workflows/merge-pr.md) § 4.1 runs the detach again.
   - Record the detach once it completes, or once the conditions of § 4.1 skip it:

   ```bash
   .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-pr-progress","step":"children-detached"}'
   ```

3. Read the pushed head as `[HEAD_SHA]`:

   ```bash
   git -C "[WORKTREE_PATH]" rev-parse HEAD
   ```

4. Arm:

   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY .agents/skills/github/scripts/github.sh -C "[WORKTREE_PATH]" pr-merge [PR_NUMBER] --auto --expected-head [HEAD_SHA]
   ```

5. Before you route the exit, record the decision by [merge-attempt.md § Record the merge decision](merge-attempt.md#record-the-merge-decision), with `[HEAD_SHA]`, this call's exit and its returned route.
   - `[STATE_KEY]` is `[ISSUE_ID]`, and `[MAIN_REPO_ROOT]` is this worktree.
   - On exit `1`, that section confirms removal of any earlier arm before the routing below.
6. Route the exit:

| Exit | Meaning | Action |
|---|---|---|
| `75` | Armed | Continue with the CI wait, the gate wait and submit-pr.md § 6.1. GitHub holds the merge as `pr-merge --help` § Approvals and review threads states |
| `0` | Merged | submit-pr.md § 6 enters [merge-pr.md](../workflows/merge-pr.md), whose § 3.2 takes a merged pull request straight to its post-merge steps |
| `1` | Armed nothing | Continue unarmed. [merge-pr.md](../workflows/merge-pr.md) § 5 takes the merge after submit-pr.md § 6.1 |

On exit `1`, report an `arm: no-merge-gate=` line once. `unverified` is a failed read of the base branch's rules. Any other gap names the setting that fixes it (`pr-merge --help`).

## One rerun per head

Read when a CI verdict on a pull request's head is `status=complete` with `verdict=fail`.

Rerun a transient runner failure, such as a lost runner or a dependency install that timed out, once per head before any fix round. `[HEAD]` is the verdict's `result.head`. `[STATE_KEY]` is the item's workflow-state key, `[ISSUE_ID]` in submit-pr.md.

1. Read the recorded rerun:

   ```bash
   .agents/skills/orch/scripts/orch-runtime state get --item [STATE_KEY] /ci_rerun/head
   ```

2. When its `result.value` is `[HEAD]`, this head had its rerun: take the caller's fix route.
3. Otherwise record the rerun for this head, then ask for it. Write the record before the ask, never after. `ci-rerun --help` says which failed run it reruns:

   ```bash
   .agents/skills/orch/scripts/orch-runtime op --item [STATE_KEY] --request-json '{"op":"record-pr-progress","step":"ci-rerun","head":"[HEAD]"}'
   env -u GH_REPO -u GITHUB_REPOSITORY .agents/skills/github/scripts/github.sh ci-rerun [PR_NUMBER] --required-only
   ```

4. On a `rerun run=[RUN_ID]` line, record the run on the item:

   ```bash
   .agents/skills/orch/scripts/orch-runtime op --item [STATE_KEY] --request-json '{"op":"record-pr-progress","step":"ci-rerun-run","head":"[HEAD]","run":[RUN_ID]}'
   ```

   Then return to the CI verdict call after the interval that call keeps between calls, never at once. That call then reads the rerun attempt as the current run.

5. A `no-rerun` line, or exit `1`, takes the caller's fix route.

## Merge gates

Read when submit-pr.md § 6.1 judges whether the pull request may merge, and when another workflow applies one gate.

A pull request merges on exactly four deterministic gates. `MERGE_READY = true` only when all four are met.

| # | Gate | Read |
|---|------|------|
| 1 | Internal review verdict recorded | The recorded review result |
| 2 | CI green | The result submit-pr.md § 5 recorded |
| 3 | Zero unresolved review comments | A final live check |
| 4 | Reviewer-gate verdict | The result submit-pr.md § 4 recorded |

Gates 2 and 4 check recorded results: do not run the waits again.

**Gate 1.**

- Managed: `review-pr.md` completed with verdict `pass`.
- Standalone: `json_paths` is non-empty. Read it:

  ```bash
  STATE_READ="$(.agents/skills/orch/scripts/orch-runtime state get --item [ISSUE_ID])" && jq -c '.result.value | {json_paths: (.json_paths // []), cycles: (.cycles // 0)}' <<<"$STATE_READ"
  ```

  Empty `json_paths` means no internal review is recorded. Report the unmet gate and recommend `orch review-pr [PR_NUMBER]`.

**Gate 2.**

- The submit-pr.md § 5 result is `status=complete` with `verdict=pass`.
- `verdict=none` meets the gate after its coverage check passes, with a `CI: none configured` note in the summary.
- Raw `gh pr checks` output is never the gate.
- On a `pr-merge --check` refusal, run `.agents/skills/github/scripts/github.sh ci-classify-refusal [PR_NUMBER]`. Report its `cause:` line with its detail. `ci-classify-refusal --help` gives the output contract.

**Gate 3.**

- `pr-threads` reports `unresolved_count == 0`.
- Every actionable PR-level bot comment has a reply, tracked in `pr_comment_review.replied`.
- `check-review-replies` exits 0.
- Replying to every bot comment stays the hygiene rule of submit-pr.md § 3, not a gate in any mode.

On a `check-review-replies` exit `1`, the command prints one line per failing rule.

- Rewrite each reply it counts as one of the three dispositions in [finding-disposition.md § Decision flow](../../reviewer/references/finding-disposition.md#decision-flow).
- A reply or comment counts only from the pull request's author, the identity the check runs as, or an `OWNER`, `MEMBER` or `COLLABORATOR` of the repository. Post it under one of those identities.
- `check-review-replies --help` names which replies do not count. The command reports them on stderr.

Exit `2` reached no verdict, and the gate is unmet.

**Gate 4.** Read the recorded gate mode, the one the runtime records per base ([gates.md § Gate-mode routing](gates.md#gate-mode-routing)):

```bash
.agents/skills/orch/scripts/orch-runtime state get --item [ISSUE_ID] /pr_review/mode
```

- `approval`: submit-pr.md § 4 ended `approved`, or a recorded `pr_approval.forced` or `pr_approval.reviewer_down` meets the gate.
- `off`: the gate does not apply.
