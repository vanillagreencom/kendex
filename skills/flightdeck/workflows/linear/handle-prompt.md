# Workflow: `handle-prompt` — Issue Prompt Handler

Routes issue-specific prompt tags for a `kind="issue"` entry. Generic prompt/event tags live in `workflows/shared/session-handle-prompt.md`; issue `watch.md` calls that file first for `oc-question`, `pi-question`, `bash-permission-prompt`, `awaiting-direction`, safe `generic-multi-choice`, `terminal-state-reached`, `pi-bg-task-exit`, and `domain-mismatch` guard handling.

**Inputs**: `<ISSUE_ID>`, `<TAG>` (issue-only substate from `prompt-classify` or computed by the issue workflow), captured buffer or structured event details.

**Pre-conditions**: master state initialized; `<ISSUE_ID>` is registered as `kind="issue"`; state is `prompting`; issue-mode skills (`github`, `linear`, `worktree`, `project-management`) are available.

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

Some agents propose cleanup of multiple worktrees. Issue mode may clean only the asking issue's own worktree.

1. Extract the target worktree path from the prompt buffer.
2. Compare it to `domain.issue.worktree` from the registry.
3. Equal → answer the affirmative option (usually `--option 1`).
4. Not equal → answer the negative/keep option or send a scope-to-self payload.
5. Log `cleanup-prompt <answer>`.

---

## § 3: Handler — `stale-no-pr-branch` / `stale-orphan-worktree`

Defensive coverage for older orchestration builds or bypassed managed-mode guards. These prompts are out of scope for a per-issue pane.

1. Identify the keep option:
   - `Keep branch` over `Delete branch`.
   - `Keep worktree` over `Remove worktree`.
2. Send the keep answer. Do not invent a delete/remove instruction.
3. Log the decision and append a process-violation note for the end-of-session report.

Never escalate these tags to the user; the safe answer is mechanical.

---

## § 4: Handler — `bot-review-wait-stuck` and issue `pi-bg-task-exit` continuation

Master does not re-invoke `bot-review-wait` inside the pane. It observes PR state and nudges the orchestrator.

1. Query `gh pr view <PR> --json statusCheckRollup,reviewDecision,latestReviews,labels,mergeStateStatus`.
2. Parse bot check conclusion, review decision, and latest human reviews.
3. Decision matrix:
   - Bot check `SUCCESS` and `reviewDecision == APPROVED` (or no reviewers required) → answer `Skip` / continue.
   - `CHANGES_REQUESTED` → escalate to review-feedback path.
   - Bot still pending but elapsed beyond threshold → escalate with observed state.
   - Real human reviewer pending → escalate.
4. Log decision.

When `session-handle-prompt.md` handles `pi-bg-task-exit` for an issue entry and the task command is `bot-review-wait`, `ci-wait`, or another issue waiter, resume here to recover downstream PR/CI state before deciding whether to nudge or escalate.

---

## § 5: Handler — `rebase-multi-choice`

The issue agent is asking how to resolve conflicts.

1. Identify the upstream merged issue/PR whose code must be preserved.
2. Gather **PRESERVE** details from the upstream PR diff: signatures, wrappers, parameters, and behavior that must not be reverted.
3. Gather **APPLY** details from the current issue's PR/branch: field renames, type updates, and intended local refactors.
4. Choose **VERIFY** commands that prove both sides are intact.
5. Compose a single payload containing the selected option plus the preserve/apply/verify triplet.
6. Send via `pane-respond <pane_target> "<payload>" --tag rebase-multi-choice`.
7. Log decision.

---

## § 6: Handler — `force-push-prompt`

Auto-approve only bounded force-pushes.

All must be true:

1. The command uses `--force-with-lease`, not raw `--force`.
2. No other in-flight session depends on this branch/ref.
3. The remote tip belongs to the current orchestrator identity; no foreign commits would be dropped.

If satisfied, answer the affirmative option. Otherwise set `paused_for_user` with the failing predicate.

---

## § 7: Handler — `audit-relation-prompt`

Issue audit is creating or classifying follow-up issues.

1. Parse proposed issues and structure columns (`child of`, `related to`, `none`).
2. For each proposed `child of <current issue>`, run a conflict check against live PR file sets.
3. No conflict → accept `child of` under expansion bias.
4. Conflict or unrelated scope → choose `related` or another safe relation.
5. Capture created issue ids, titles, parents, projects, and priorities in master state for `terminate.md`.
6. Log decision.

---

## § 8: Handler — `merge-now`

The orchestrator has already checked review, CI, branch protection, and thread gates. Master adds only cross-session conflict awareness.

1. Run `pr-conflict-graph <THIS_PR> <OTHER_LIVE_PRS...>`.
2. If this PR overlaps another live unmerged PR, escalate.
3. If no overlap, answer `Merge`.
4. If the prompt reports `mergeStateStatus == UNKNOWN`, defer to § 9.
5. Log decision.

`FLIGHTDECK_AUTO_MERGE=0` escalates this prompt unconditionally.

---

## § 9: Handler — `merge-ready-but-unknown` / `force-merge-confirm`

See `patterns/conflict-detection.md`.

1. Record or read `unknown_since`.
2. Re-fetch PR state immediately before deciding.
3. Force-merge predicate:
   - review decision approved;
   - all checks are `SUCCESS` or `SKIPPED`, none failed;
   - `unknown_since` elapsed ≥ `FLIGHTDECK_FORCE_MERGE_AFTER_SECS`;
   - PR files are disjoint from recent main changes.
4. Predicate true → answer the force-merge option.
5. Predicate false and elapsed below threshold → answer wait.
6. Predicate false after threshold or state flips to dirty/behind with overlap → escalate.
7. Log decision.

---

## § 10: Handler — `external-fix-suggestions`, `cycle-fix-suggestions`, and `scope-creep-detected`

For `scope-creep-detected`, do not answer the pane. Set `paused_for_user = {issue_id, reason: "scope-creep-detected", prompt_text: <summary>}`.

For review fix prompts:

1. Evaluate each suggestion by expansion bias.
2. In-domain, mechanical fixes → include.
3. Different scope, measurement required, blocked dependency, or architectural change → defer.
4. All in scope → answer `All` or equivalent.
5. Mixed → answer with the in-scope subset and capture deferred follow-ups.
6. Scope-creep risk (`actual_files > 2 × declared_files`) → escalate.
7. Log decision.

---

## § 11: Handler — `descope-related`

The current PR absorbed part of a related/sibling issue's scope.

1. Default to the affirmative descope option when reconciliation shows overlap already implemented.
2. Capture the descope action in the issue decision log and end-of-session report.
3. Do not perform code changes here; this is tracking metadata only.

---

## § 12: Handler — `multi-select-tabbed`

Tabbed checkbox prompts are issue-specific only when their choices reference review fixes, audit issues, or merge/rebase actions.

1. Parse visible checkbox rows and tabs.
2. Apply the matching issue policy above (fix suggestions, audit relations, or rebase/merge guidance).
3. Send through `pane-respond --option-multi` / `--keys` as required by the harness.
4. Log selected rows.

If the checkbox prompt is generic and safe, it should be reclassified/handled as a generic prompt in `session-handle-prompt.md`; otherwise escalate.

---

## § 13: Issue-mode extension for `bash-permission-prompt`

Generic permission handling lives in `session-handle-prompt.md`. If the only reason generic handling would escalate is an issue-domain read-only command, issue mode may extend the allowlist with:

| Pattern | Why safe in issue mode |
|---------|------------------------|
| `^gh (pr (view|list|files|diff|checks)|issue view|run (list|view))` | Read-only GitHub inspection. |
| `^linear\s` | Linear CLI wrapper handles auth/scope; use only for issue metadata actions expected by this workflow. |

Do not approve writes to `main`, destructive git operations, force pushes, branch deletion, worktree removal, or merge commands through a bash permission prompt. Those must surface as their specific issue tags.

---

## Returns

To `watch.md` § 4 for sequential issue routing, then back to the generic ack/yield path in `session-watch.md`.
