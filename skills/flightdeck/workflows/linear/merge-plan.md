# Workflow: `linear merge-plan` — Conflict Graph + Merge Order

Compute the file-intersection conflict graph for all `merge-ready` PRs, sort by smallest-scope-first, execute the next safe merge.

Issue-mode workflow only. It is invoked by `workflows/linear/watch.md` after the generic `workflows/shared/session-watch.md` loop has reconciled entries and routed domain-neutral prompts through `workflows/shared/session-handle-prompt.md`.

**Inputs**: master state (read-only at entry); the implicit list of `merge-ready` issues.

**Pre-conditions**: `watch.md` § 4 detected ≥1 issue in `merge-ready` state.

**Post-condition**: at most one merge executed per invocation; the merged issue transitions to `merged`; conflict graph and merge queue updated for the remaining set.

---

## § 1: Build Conflict Graph

1. Collect PR numbers for all issues currently in `merge-ready`:
   ```
   pane-registry list | jq '.[] | select(.state == "merge-ready") | .pr_number' | sort -u
   ```
2. Build the graph:
   ```
   .agents/skills/flightdeck/scripts/pr-conflict-graph <PR1> <PR2> ...
   ```
3. Persist:
   ```
   flightdeck-state set conflict_graph <graph-json>
   ```

---

## § 2: Sort Merge Queue

1. Read `prs[].file_count` from the graph output.
2. Sort ascending by `file_count`. Tiebreak by PR number ascending.
3. The result is the merge queue. Persist:
   ```
   flightdeck-state set merge_queue <ordered-issue-id-list>
   ```

See `patterns/decision-biases.md` § Smaller-PR-first merge order and § Merge-order tiebreakers for rationale.

---

## § 3: Execute Next Merge

1. Pop the head of `merge_queue`.
2. Re-validate immediately before merging:
   ```
   github pr-view <PR>
   ```
   Use the `mergeable`, `mergeStateStatus`, `reviewDecision`, and `statusCheckRollup` fields from its output. (If the state is transient `UNKNOWN`, prefer `github await-mergeable <PR>` to bound the wait — see § 3.5.)
3. Decision:
   - `MERGEABLE` + `CLEAN` + APPROVED + all-checks-green → **direct the per-issue agent**: the per-issue agent is the one that owns merging its own PR. If its pane is alive and idle, send a message instructing it to run its `merge-pr` workflow on its current PR (no `⤵` from flightdeck — flightdeck observes-and-directs). If its pane is dead or absent (rare edge case for a PR whose session already ended), invoke the github skill's wrapper:
     ```
     github pr-merge <PR> --squash --delete-branch
     ```
     Branch on exit code (the wrapper distinguishes outcomes that raw `gh pr merge` collapses to a single 0):
     - `0` (MERGED) → § 4. The PR landed immediately.
     - `75` (QUEUED FOR AUTO-MERGE) → set the issue's `substate = queued-for-auto-merge`; do NOT mark merged. The merge will fire when CI / branch protection clear; the watch loop will catch the eventual MERGED state on a later poll. Push the issue back to the queue tail.
     - `1` (BLOCKED) → escalate (`paused_for_user`); the wrapper's stderr classifies the block as transient or permanent — surface that in the pause message.
   - `UNKNOWN` AND elapsed since first observed < `FLIGHTDECK_FORCE_MERGE_AFTER_SECS` → push back to queue tail; return to § 1 (graph unchanged).
   - `UNKNOWN` AND elapsed ≥ threshold AND force-merge predicate satisfied (see `patterns/conflict-detection.md`) → direct the per-issue agent to force-merge. If no live pane, invoke `github pr-merge <PR> --force --squash --delete-branch` (admin path) and apply the same exit-code branching above.
   - `DIRTY | BEHIND` with overlap → escalate (set `paused_for_user`); return to caller.
4. On successful merge (exit 0):
   - `pane-registry set-state <ISSUE_ID> merged`.
   - `pane-registry set <ISSUE_ID> pr_number <number>` (if not already set).

### § 3.5: Bounded UNKNOWN wait (optional)

If the queue head is in `UNKNOWN` state and you want to bound the wait without yielding the full poll cycle:

```
github await-mergeable <PR>
```

Polls `state` and `mergeStateStatus` correctly (never `mergeable`, which stays `UNKNOWN` permanently after merge). Exit 0 + JSON on stdout when resolved; exit 124 on timeout. Use sparingly — extended waits should still go through the poll loop's `FLIGHTDECK_FORCE_MERGE_AFTER_SECS` clock so the master state remains consistent across compaction.

---

## § 4: Recompute Graph

After each merge:

1. Remove the merged issue from `merge_queue`.
2. Recompute the graph against the remaining `merge-ready` issues — main has moved; some PRs may now be `BEHIND` and need rebase before becoming truly merge-ready again.
3. If any PR's state flipped to `BEHIND` post-merge, transition that issue back to `submitting` (its agent will detect the conflict on next sync and prompt for rebase, which the `rebase-multi-choice` handler covers).
4. Return to § 1 if more issues remain in the queue.

---

## § 5: Empty Queue

When `merge_queue` is empty after a merge or no `merge-ready` issues remain at entry, return to `watch.md` § 5. The watch loop continues polling for new merge-ready transitions.

---

## Skip-If

- No issue is currently in `merge-ready` state at entry → return immediately.

## Returns

To `watch.md` § 5 (bell cleanup) → § 6 (termination check).
