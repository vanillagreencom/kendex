# Workflow: `github handle-prompt` — GitHub Issue Prompt Handler

Routes GitHub-specific prompt tags for one tracked `kind="issue"` entry whose domain key is `entry.domain.github_issue`. Generic prompt/event tags live in `workflows/shared/session-handle-prompt.md`.

**Inputs**: `<ISSUE_NUMBER>`, `<TAG>`, captured buffer or structured event details.

**Pre-conditions**:
- Entry exists and has `domain.github_issue`.
- `github` and `worktree` skills are available. Do not load `linear` or `project-management`.
- `gh` is authenticated.

**Post-condition**: a response was sent and logged, entry state/domain fields were updated, or `paused_for_user` is set.

---

## § 1: Domain guard and lookup

Read normalized entry:

```bash
ENTRY_JSON=$(.agents/skills/flightdeck/scripts/pane-registry list --format json \
  | jq -c --arg id "<ISSUE_NUMBER>" '.[] | select((.id // (.domain.github_issue.number|tostring?)) == $id)')
```

Require:

```jq
.kind == "issue" and (.domain.github_issue? != null)
```

Use `pane_target`, `pane_id`, `worktree`, `domain.github_issue.pr_number`, and adapter metadata from `ENTRY_JSON`. If `domain.issue` is present without `domain.github_issue`, this is a Linear entry; set `paused_for_user` with `reason="domain-mismatch"` and return without action.

---

## § 2: gh helper policy

All GitHub CLI calls in this handler use:

1. Run the command.
2. If it exits non-zero, wait 2s and retry once.
3. If the retry exits non-zero, emit activity warning `gh-cli-unavailable issue=<N> command=<cmd> stderr=<stderr>`, set `paused_for_user.reason="gh-cli-unavailable"`, and return.

Applies to `gh pr view`, `gh pr edit`, `gh issue view`, and any label/check inspection.

---

## § 3: Handler — `merge-now`

`merge-now` is auto-answered only after fresh authoritative GitHub state proves the PR is mergeable.

1. If `FLIGHTDECK_AUTO_MERGE=0`, set `paused_for_user = {issue_id:<N>, reason:"auto-merge-disabled", prompt_text:<buffer>}` and return.
2. Run first, before any Merge answer:
   ```bash
   gh pr view <PR> --json mergeStateStatus,reviewDecision,statusCheckRollup
   ```
3. Compute required-check success. Every required check conclusion must be `SUCCESS` or `SKIPPED`; missing fields, pending, cancelled, timed out, failed, or neutral unknown values are not green.
4. Auto-Merge predicate:
   ```text
   mergeStateStatus === "CLEAN"
     AND reviewDecision === "APPROVED" (or unset with no pending reviewers)
     AND every required check conclusion ∈ {SUCCESS, SKIPPED}
   ```
5. Predicate true → answer `Merge` through `pane-respond`, log `merge-now Merge`, set state `merge-ready` only if the child is handing merge back to master; otherwise let the child continue its own merge workflow.
6. `mergeStateStatus === "UNKNOWN"` → emit `merge-ready-but-unknown`, set/extend `unknown_since`, and return to `github/watch.md` § 5. Do not auto-Merge.
7. `mergeStateStatus === "DIRTY"` → set `paused_for_user = {issue_id:<N>, reason:"pr-merge-conflict", prompt_text:<state summary>}`.
8. `mergeStateStatus === "BEHIND"` → answer Update Branch / auto-rebase only when `FLIGHTDECK_AUTO_REBASE=1`. Default for GitHub lane is `0`, so escalate with `reason="pr-behind"` unless explicitly enabled.
9. `BLOCKED`, `HAS_HOOKS`, missing fields, or any other state → escalate. Do not answer Merge.

---

## § 4: Handler — `merge-ready-but-unknown`

1. If `FLIGHTDECK_AUTO_MERGE=0`, set `paused_for_user = {issue_id:<N>, reason:"auto-merge-disabled", prompt_text:<buffer>}` and return. Do not answer wait, Merge, force-merge, or transition to `force-merge-confirm` while auto-merge is disabled.
2. Re-fetch:
   ```bash
   gh pr view <PR> --json mergeStateStatus,reviewDecision,statusCheckRollup,files
   ```
3. If state is still `UNKNOWN`, preserve existing `unknown_since` or set it to now.
4. If elapsed is below `FLIGHTDECK_FORCE_MERGE_AFTER_SECS` (default 240), answer wait/continue if the prompt offers it; otherwise log and yield.
5. If elapsed exceeds threshold, re-check `FLIGHTDECK_AUTO_MERGE`; if it is `0`, set `paused_for_user.reason="auto-merge-disabled"` and return without transitioning to `force-merge-confirm`.
6. If auto-merge is enabled, evaluate force-merge predicate from `patterns/conflict-detection.md`:
   - `reviewDecision == "APPROVED"` (strict; do not substitute unset review with "no pending reviewers");
   - all checks `SUCCESS` or `SKIPPED`;
   - disjoint from other live PRs and recent main changes;
   - `unknown_since > FLIGHTDECK_FORCE_MERGE_AFTER_SECS`;
   - no authoritative conflict state.
7. Predicate true → transition to `force-merge-confirm`.
8. Predicate false → set `paused_for_user` with the failed predicate list.

---

## § 5: Handler — `force-merge-confirm`

Force merge is allowed only for persistent `UNKNOWN` after the threshold and only when the force-merge predicate holds. Re-run the same `gh pr view` check immediately before answering.

- If `FLIGHTDECK_AUTO_MERGE=0`, set `paused_for_user = {issue_id:<N>, reason:"auto-merge-disabled", prompt_text:<buffer>}` and do not answer the force-merge option.
- Predicate true → answer the force-merge option and log `{unknown_since, elapsed, predicate:"passed"}`.
- Predicate false → set `paused_for_user` and do not answer.

Never force-merge `DIRTY`, `BEHIND` with overlap, `BLOCKED`, `HAS_HOOKS`, or missing-state PRs.

---

## § 6: Handler — `bot-review-wait-stuck` and issue `pi-bg-task-exit`

1. Query:
   ```bash
   gh pr view <PR> --json statusCheckRollup,reviewDecision,latestReviews,labels,mergeStateStatus
   ```
2. Bot check `SUCCESS` and approved/no pending reviewers → answer `Skip` / continue.
3. `CHANGES_REQUESTED` → prompt the child to address review feedback.
4. Bot still pending beyond threshold or real human reviewer pending → set `paused_for_user`.
5. If `gh` fails, follow § 2.

For `pi-bg-task-exit` from GitHub waiters (`bot-review-wait`, `ci-wait`), resume here after the generic handler returns.

---

## § 7: Handler — `rebase-multi-choice`

1. If `FLIGHTDECK_AUTO_REBASE != 1`, set `paused_for_user = {issue_id:<N>, reason:"pr-behind", prompt_text:<buffer>}`. GitHub lane defaults to no auto-rebase.
2. If enabled, build preserve/apply/verify guidance from upstream merged PRs and current branch diff.
3. Send one combined payload with selected option plus preserve/apply/verify triplet.
4. Log decision.

---

## § 8: Handler — `force-push-prompt`

Auto-approve only bounded force pushes:

1. Command uses `--force-with-lease`, not raw `--force`.
2. Remote tip belongs to the current child branch `issue-<N>`.
3. No other tracked entry depends on that branch/ref.

Otherwise pause with the failed predicate.

---

## § 9: Handler — `cleanup-prompt`, stale branch/worktree prompts

GitHub lane may clean only the tracked issue's own worktree/branch.

- Target equals `domain.github_issue.worktree` or branch `issue-<N>` → answer affirmative safe cleanup.
- Target differs → answer keep/decline.
- `stale-no-pr-branch` / `stale-orphan-worktree` → always choose keep unless the target exactly matches this issue's worktree/branch and terminal state is already verified.

---

## § 10: Handler — `multi-select-tabbed`

Only handle GitHub review, merge, rebase, and cleanup choices. For any tab that contains Linear-only audit/relation/descope choices, set `paused_for_user.reason="domain-mismatch"`.

---

## § 11: Issue-mode extension for `bash-permission-prompt`

Generic permission handling lives in `session-handle-prompt.md`. GitHub mode may additionally allow read-only commands:

| Pattern | Why safe |
|---------|----------|
| `^gh (pr (view|list|files|diff|checks)|issue view|run (list|view))` | Read-only GitHub inspection. |

Do not approve writes (`gh pr merge`, `gh issue close`, `gh pr edit`, labels), force pushes, branch deletion, worktree removal, or `main` mutation through a bash permission prompt. Those must surface as specific GitHub issue tags.

## Returns

To `github/watch.md` § 4.