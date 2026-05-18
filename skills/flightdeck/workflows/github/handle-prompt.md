# Workflow: `github handle-prompt` — GitHub Issue Prompt Handler

Routes GitHub issue-specific prompt tags for a `kind="issue"` entry. Generic prompt/event tags live in `workflows/shared/session-handle-prompt.md`; `github/watch.md` calls that file first for `oc-question`, `pi-question`, `bash-permission-prompt`, `awaiting-direction`, safe `generic-multi-choice`, `terminal-state-reached`, `pi-bg-task-exit`, and `domain-mismatch` guard handling.

**Inputs**: `<ISSUE_ID>`, `<TAG>` (GitHub issue-only substate from `prompt-classify` or computed by the issue workflow), captured buffer or structured event details.

**Pre-conditions**: master state initialized; `<ISSUE_ID>` is registered as `kind="issue"`; state is `prompting`; GitHub-mode skills (`github`, `worktree`) are available.

**Post-condition**: a response was sent and decision logged, issue state/domain fields were updated, or `master_state.paused_for_user` is set and the watch loop yields.

---

## § 1: Domain guard and lookup

Read the normalized issue entry:

```bash
ENTRY_JSON=$(.agents/skills/flightdeck/scripts/pane-registry list --format json \
  | jq -c --arg id "<ISSUE_ID>" '.[] | select((.id // .issue) == $id)')
```

Require `kind == "issue"`. If this handler is invoked for `kind=adhoc` or `kind=workflow`, treat it as a bug in the caller: log `domain-mismatch`, take no destructive action, set `paused_for_user`, and return.

Use `pane_target`, `pane_id`, `worktree`, `domain.issue.pr_number`, and adapter metadata from `ENTRY_JSON`. Legacy `pane-registry get <ISSUE_ID>` remains a compatibility read, but new logic should prefer normalized entries.

---

## § 2: Handler — `cleanup-prompt`

Some agents propose cleanup of multiple worktrees. GitHub issue mode may clean only the asking issue's own worktree.

1. Extract the target worktree path from the prompt buffer.
2. Compare it to `domain.issue.worktree` from the registry.
3. Equal → answer the affirmative option (usually `--option 1`).
4. Not equal → answer the negative/keep option or send a scope-to-self payload.
5. Log `cleanup-prompt <answer>`.

---

## § 3: Handler — `bot-review-wait-stuck` and issue `pi-bg-task-exit` continuation

Master does not re-invoke long-running waiters inside the pane. It observes PR state and nudges the issue agent.

1. Query:
   ```bash
   gh pr view <PR> --json statusCheckRollup,reviewDecision,latestReviews,labels,mergeStateStatus,state
   ```
2. Parse bot check conclusion, review decision, status checks, and latest human reviews.
3. Decision matrix:
   - Bot check `SUCCESS`, all required CI checks green, and `reviewDecision == APPROVED` (or no reviewers required) → answer `Skip` / continue.
   - `CHANGES_REQUESTED` → instruct the pane to address review feedback.
   - CI failed → instruct the pane to inspect failing jobs and fix.
   - Bot or CI still pending but elapsed beyond threshold → escalate with observed state.
   - Real human reviewer pending → escalate.
4. Log decision.

When `session-handle-prompt.md` handles `pi-bg-task-exit` for an issue entry and the task command is `bot-review-wait`, `ci-wait`, or another PR waiter, resume here to recover downstream PR/CI/review state before deciding whether to nudge or escalate.

---

## § 4: Handler — `rebase-multi-choice`

The issue agent is asking how to resolve conflicts.

1. Identify the upstream merged PR or default-branch change whose code must be preserved.
2. Gather **PRESERVE** details from the upstream diff: signatures, wrappers, parameters, and behavior that must not be reverted.
3. Gather **APPLY** details from the current issue's PR/branch: field renames, type updates, and intended local refactors.
4. Choose **VERIFY** commands that prove both sides are intact.
5. Compose a single payload containing the selected option plus the preserve/apply/verify triplet.
6. Send via `pane-respond <pane_target> "<payload>" --tag rebase-multi-choice`.
7. Log decision.

---

## § 5: Handler — `force-push-prompt`

Auto-approve only bounded force-pushes.

All must be true:

1. The command uses `--force-with-lease`, not raw `--force`.
2. No other in-flight session depends on this branch/ref.
3. The remote tip belongs to the current issue agent identity; no foreign commits would be dropped.

If satisfied, answer the affirmative option. Otherwise set `paused_for_user` with the failing predicate.

---

## § 6: Handler — `merge-now`

The issue agent has already checked review, CI, branch protection, and thread gates. Master adds cross-session awareness and one final PR state read.

1. Re-fetch current PR state:
   ```bash
   gh pr view <PR> --json state,mergeStateStatus,reviewDecision,statusCheckRollup,files,labels
   ```
2. Compare this PR's files against other live unmerged PRs from tracked GitHub issue entries. If files overlap, escalate.
3. If no overlap and the PR is approved with all required checks green, answer `Merge`.
4. If the prompt asks for a force/admin merge while merge state is still `UNKNOWN`, defer to § 7.
5. If checks failed, review requested changes, or merge state is dirty/behind, answer the safe wait/fix option when present; otherwise escalate.
6. Log decision.

`FLIGHTDECK_AUTO_MERGE=0` escalates this prompt unconditionally.

---

## § 7: Handler — `force-merge-confirm`

See `patterns/conflict-detection.md`.

1. Record or read `unknown_since`.
2. Re-fetch PR state immediately before deciding.
3. Force-merge predicate:
   - review decision approved;
   - all checks are `SUCCESS` or `SKIPPED`, none failed;
   - `unknown_since` elapsed ≥ `FLIGHTDECK_FORCE_MERGE_AFTER_SECS`;
   - PR files are disjoint from recent default-branch changes and other live tracked PRs.
4. Predicate true → answer the force-merge option.
5. Predicate false and elapsed below threshold → answer wait.
6. Predicate false after threshold or state flips to dirty/behind with overlap → escalate.
7. Log decision.

---

## § 8: Handler — `multi-select-tabbed`

Tabbed checkbox prompts are GitHub issue-specific only when their choices reference PR review fixes, CI actions, rebase choices, force-push choices, cleanup scope, or merge actions.

1. Parse visible checkbox rows and tabs.
2. Apply the matching GitHub policy above (review/CI continuation, cleanup, rebase, force-push, or merge gating).
3. Send through `pane-respond --option-multi` / `--keys` as required by the harness.
4. Log selected rows.

If the checkbox prompt is generic and safe, it should be reclassified/handled as a generic prompt in `session-handle-prompt.md`; otherwise escalate.

---

## § 9: GitHub-mode extension for `bash-permission-prompt`

Generic permission handling lives in `session-handle-prompt.md`. If the only reason generic handling would escalate is a GitHub-domain read-only command, GitHub mode may extend the allowlist with:

| Pattern | Why safe in GitHub issue mode |
|---------|-------------------------------|
| `^gh (pr (view|list|files|diff|checks)|issue view|run (list|view))` | Read-only GitHub inspection. |
| `^\.agents/skills/github/scripts/github\.sh (pr-data|pr-view|pr-threads|pr-review-status|pr-list-ready|pr-list-failing|pr-issue|await-mergeable|ci-logs|sticky-comment)` | Read-only GitHub wrapper inspection. |

Do not approve writes to the default branch, destructive git operations, force pushes, branch deletion, worktree removal, issue closure, or merge commands through a bash permission prompt. Those must surface as their specific GitHub issue tags.

---

## Returns

To `github/watch.md` § 4 for sequential GitHub issue routing, then back to the generic ack/yield path in `session-watch.md`.
