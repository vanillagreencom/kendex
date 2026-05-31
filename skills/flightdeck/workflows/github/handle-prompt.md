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

## § 3: Handler — `pre-pr-ready-for-review`

Child has pushed commits and is waiting for the supervisor to gate PR creation. Master fans out reviewers, hands findings back, and loops until approved.

1. If `FLIGHTDECK_PRE_PR_REVIEW=0`, run the disabled-review approval steps with the same checked-write contract as `workflows/shared/pre-pr-review.md` § 6: atomic-write `<WT>/tmp/pre-pr-approved.md` with body `Pre-PR review disabled by FLIGHTDECK_PRE_PR_REVIEW=0` (on failure set `paused_for_user.reason="pre-pr-review-error"` and return), `pane-respond` the approval instruction from § 6 step 2 (on failure set `paused_for_user.reason="pre-pr-review-error"` and return), then set `domain.github_issue.review_status = "pre-pr-approved"`. Return.
2. Otherwise initialize-only on first entry: if `domain.github_issue.review_status` is null/unset, set it to `"pre-pr-reviewing"` and `domain.github_issue.review_reports = []`. Do NOT touch `domain.github_issue.review_rounds`; the shared workflow owns it (`workflows/shared/pre-pr-review.md` § 1, § 7).
3. Invoke `⤵ workflows/shared/pre-pr-review.md <ISSUE_NUMBER> github_issue`.
4. The shared workflow sets `review_status` to `pre-pr-approved`, `pre-pr-fixing`, or sets `paused_for_user.reason` to `pre-pr-review-error` / `pre-pr-review-empty-diff` for true workflow failures. Soft round caps are handled autonomously inside the shared workflow. Do not duplicate that logic here.
5. Return to `github/watch.md` § 4 without further action.

---

## § 4: Handler — `merge-now`

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

## § 4.5: Handler — `merge-permission-blocked`

A child or wrapper attempted `gh pr merge` but GitHub rejected the capability (for example `GraphQL: <actor> does not have the correct permissions to execute MergePullRequest`). Treat this as readiness/capability split, not a user decision.

1. Re-run authoritative state:
   ```bash
   gh pr view <PR> --json state,mergeStateStatus,reviewDecision,statusCheckRollup,mergeCommit
   ```
2. If `state === "MERGED"` and `mergeCommit !== null`, invoke `workflows/github/close-issue.md <N>` or return to watch so the terminal close path records the merge. Do not use the failed merge exit as proof.
3. If the PR is still ready (`mergeStateStatus === "CLEAN"`, review approved or no pending reviewers, and required checks `SUCCESS` / `SKIPPED`), do not set `paused_for_user` for the permission denial itself. Persist the monitoring marker with checked persistence before returning; the daemon's `merge-permission-monitor` scheduled wake re-enters `github/watch.md` at least once per 60s while this marker remains:
   ```bash
   UPDATED_ENTRY_JSON=$(jq -c '.state="ready" | .domain.github_issue.phase="merge-blocked-permission" | .domain.github_issue.merge_blocked_permission={reason:"MergePullRequest permission denied", pr:<PR>, ready:true, last_checked_at:"<ISO8601>"}' <<< "$ENTRY_JSON")
   .agents/skills/flightdeck/scripts/flightdeck-state write-entry <N> "$UPDATED_ENTRY_JSON"
   .agents/skills/flightdeck/scripts/pane-registry log-decision <N> merge-permission-blocked "PR #<PR> ready; merge capability denied; monitoring for manual merge or permission/token change" || true
   ```
   If the `write-entry` call fails, set `paused_for_user = {issue_id:<N>, reason:"merge-permission-blocked-persist-failed", prompt_text:<stderr>}` and return. The `log-decision` call is best-effort only after the durable marker write succeeds. Do not rely on the child pane emitting another prompt; the persisted marker is the poller arm.
4. Keep monitoring GitHub authoritative state on later watch cycles. Close/teardown only after `gh pr view <PR> --json state,mergeStateStatus,mergeCommit` returns `state === "MERGED"` and `mergeCommit !== null`.
5. If the readiness predicate is no longer true, route to the existing deterministic handler (`merge-ready-but-unknown`, conflict/behind, bot-review, or CI failure). Pause only for those handlers' novel/destructive conditions.

---

## § 5: Handler — `merge-ready-but-unknown`

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

## § 6: Handler — `force-merge-confirm`

Force merge is allowed only for persistent `UNKNOWN` after the threshold and only when the force-merge predicate holds. Re-run the same `gh pr view` check immediately before answering.

- If `FLIGHTDECK_AUTO_MERGE=0`, set `paused_for_user = {issue_id:<N>, reason:"auto-merge-disabled", prompt_text:<buffer>}` and do not answer the force-merge option.
- Predicate true → answer the force-merge option and log `{unknown_since, elapsed, predicate:"passed"}`.
- Predicate false → set `paused_for_user` and do not answer.

Never force-merge `DIRTY`, `BEHIND` with overlap, `BLOCKED`, `HAS_HOOKS`, or missing-state PRs.

---

## § 7: Handler — `bot-review-wait-stuck` and issue `pi-bg-task-exit`

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

## § 8: Handler — `rebase-multi-choice`

1. If `FLIGHTDECK_AUTO_REBASE != 1`, set `paused_for_user = {issue_id:<N>, reason:"pr-behind", prompt_text:<buffer>}`. GitHub lane defaults to no auto-rebase.
2. If enabled, build preserve/apply/verify guidance from upstream merged PRs and current branch diff.
3. Send one combined payload with selected option plus preserve/apply/verify triplet.
4. Log decision.

---

## § 9: Handler — `force-push-prompt`

Auto-approve only bounded force pushes:

1. Command uses `--force-with-lease`, not raw `--force`.
2. Remote tip belongs to the current child branch `issue-<N>`.
3. No other tracked entry depends on that branch/ref.

Otherwise pause with the failed predicate.

---

## § 10: Handler — `cleanup-prompt`, stale branch/worktree prompts

GitHub lane may clean only the tracked issue's own worktree/branch.

- Target equals `domain.github_issue.worktree` or branch `issue-<N>` → answer affirmative safe cleanup.
- Target differs → answer keep/decline.
- `stale-no-pr-branch` / `stale-orphan-worktree` → always choose keep unless the target exactly matches this issue's worktree/branch and terminal state is already verified.

---

## § 11: Handler — `multi-select-tabbed`

Only handle GitHub review, merge, rebase, and cleanup choices. For any tab that contains Linear-only audit/relation/descope choices, set `paused_for_user.reason="domain-mismatch"`.

---

## § 12: Issue-mode extension for `bash-permission-prompt`

Generic permission handling lives in `session-handle-prompt.md`. GitHub mode may additionally allow read-only commands:

| Pattern | Why safe |
|---------|----------|
| `^gh (pr (view|list|files|diff|checks)|issue view|run (list|view))` | Read-only GitHub inspection. |

Do not approve writes (`gh pr merge`, `gh issue close`, `gh pr edit`, labels), force pushes, branch deletion, worktree removal, or `main` mutation through a bash permission prompt. Those must surface as specific GitHub issue tags.

## Returns

To `github/watch.md` § 4 (or back to it after the shared review workflow returns).