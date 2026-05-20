# Workflow: `plan handle-prompt` — Plan Item Prompt Handler

Routes plan-specific prompt tags for one tracked entry whose domain key is `entry.domain.plan_item`. Generic prompt/event tags live in `workflows/shared/session-handle-prompt.md`; GitHub PR prompt semantics are reused from `workflows/github/handle-prompt.md` with the plan domain key.

**Inputs**: `<ITEM_ID>`, `<TAG>`, captured buffer or structured event details.

**Pre-conditions**:
- Entry exists and has `domain.plan_item`.
- `github` and `worktree` skills are available. Do not load `linear` or `project-management`.
- `gh` is authenticated.

**Post-condition**: a response was sent and logged, entry state/domain fields were updated, or `paused_for_user` is set.

---

## § 1: Domain guard and lookup

Read normalized entry:

```bash
ENTRY_JSON=$(.agents/skills/flightdeck/scripts/pane-registry list --format json \
  | jq -c --arg id "<ITEM_ID>" '.[] | select((.id // .domain.plan_item.item_id) == $id)')
```

Require:

```jq
.domain.plan_item? != null
```

Use `pane_target`, `pane_id`, `worktree`, `domain.plan_item.pr_number`, `domain.plan_item.plan_path`, `domain.plan_item.item_id`, and adapter metadata from `ENTRY_JSON`. If `domain.issue` or `domain.github_issue` is present, set `paused_for_user` with `reason="domain-mismatch"` and return without action.

---

## § 2: gh helper policy

All GitHub CLI calls in this handler use:

1. Run the command.
2. If it exits non-zero, wait 2s and retry once.
3. If the retry exits non-zero, emit activity warning `plan-gh-cli-unavailable item=<ITEM_ID> command=<cmd> stderr=<stderr>`, set `paused_for_user.reason="gh-cli-unavailable"`, and return.

Applies to `gh pr view`, `gh pr edit`, and any label/check inspection.

---

## § 3: Handler — `pre-pr-ready-for-review`

Child has pushed commits and is waiting for the supervisor to gate PR creation. Mirrors `workflows/github/handle-prompt.md` § 3, adapted to `domain.plan_item`.

1. If `FLIGHTDECK_PRE_PR_REVIEW=0`, run the disabled-review approval steps with the same checked-write contract as `workflows/shared/pre-pr-review.md` § 6: atomic-write `<WT>/tmp/pre-pr-approved.md` with body `Pre-PR review disabled by FLIGHTDECK_PRE_PR_REVIEW=0` (on failure set `paused_for_user.reason="pre-pr-review-error"` and return), `pane-respond` the approval instruction from § 6 step 2 with the PR body wording adjusted to reference the plan path + item id (on failure set `paused_for_user.reason="pre-pr-review-error"` and return), then set `domain.plan_item.review_status = "pre-pr-approved"`. Return.
2. Otherwise initialize-only on first entry: if `domain.plan_item.review_status` is null/unset, set it to `"pre-pr-reviewing"` and `domain.plan_item.review_reports = []`. Do NOT touch `domain.plan_item.review_rounds`; the shared workflow owns it (`workflows/shared/pre-pr-review.md` § 1, § 7).
3. Invoke `⤵ workflows/shared/pre-pr-review.md <ITEM_ID> plan_item`.
4. The shared workflow sets `review_status` to `pre-pr-approved`, `pre-pr-fixing`, or sets `paused_for_user.reason` to `pre-pr-review-loop-stalled` / `pre-pr-review-error` / `pre-pr-review-empty-diff` and pane-responds accordingly. Do not duplicate that logic here.
5. Return to `plan/watch.md` § 4 without further action.

---

## § 4: Reused GitHub PR handlers

For these tags, follow the named section in `workflows/github/handle-prompt.md`, adapted only by replacing the domain reads/writes:

| Tag | GitHub handler section | Plan adaptation |
|-----|------------------------|-----------------|
| `merge-now` | § 4 | Read/write `entry.domain.plan_item.pr_number`; require `mergeStateStatus === "CLEAN"` before answering Merge. |
| `merge-ready-but-unknown` | § 5 | Preserve `entry.unknown_since`; gate wait, Merge, and force-merge transition with `FLIGHTDECK_AUTO_MERGE=0`. |
| `force-merge-confirm` | § 6 | Re-run the strict force-merge predicate immediately before answering; `FLIGHTDECK_AUTO_MERGE=0` pauses instead of answering. |
| `bot-review-wait-stuck` and issue `pi-bg-task-exit` | § 7 | Use plan PR number; never call Linear or project-management. |
| `rebase-multi-choice` | § 8 | Same preserve / apply / verify triplet; plan item worktree is `domain.plan_item.worktree`. |
| `force-push-prompt` | § 9 | Branch must be the current plan item branch / worktree; never approve sibling item force pushes. |
| `cleanup-prompt`, `stale-no-pr-branch`, `stale-orphan-worktree` | § 10 | Cleanup only when target equals `domain.plan_item.worktree` or this item branch, and terminal PR merge is already authoritative. |
| `multi-select-tabbed` | § 11 | Handle GitHub review, merge, rebase, and cleanup choices only. Linear audit/relation tabs are domain mismatch. |
| `bash-permission-prompt` issue extension | § 12 | Allow only read-only `gh` inspection; writes require the specific prompt tags above. |

Load-bearing safety rules inherited from the GitHub handler:

- `merge-now` requires fresh `gh pr view <PR> --json mergeStateStatus,reviewDecision,statusCheckRollup` and `mergeStateStatus === "CLEAN"` before answering Merge.
- `mergeStateStatus === "UNKNOWN"` routes to `merge-ready-but-unknown`; it is not merged directly.
- `FLIGHTDECK_AUTO_MERGE=0` gates `merge-now`, `merge-ready-but-unknown`, and `force-merge-confirm`.
- Strict force-merge predicate is `APPROVED ∧ all_checks_in {SUCCESS, SKIPPED} ∧ disjoint(PR_files, main_files_recently_changed) ∧ unknown_since > FLIGHTDECK_FORCE_MERGE_AFTER_SECS`.
- GitHub CLI failure retries once after 2s, then pauses; no merge, close, rebase, spawn, or cleanup proceeds on unknown GitHub state.

---

## § 5: Handler — `dependency-edge-resolution`

This is a plan-only internal routing step used by `workflows/plan/watch.md` after one item merges.

1. Read all entries with the same `domain.plan_item.plan_path`.
2. Find waiting items whose `depends_on` are all merged with non-null `merge_commit`.
3. Verify the stored graph and immutable brief artifacts:
   - Do not reread `domain.plan_item.plan_path` to rebuild child briefs.
   - Require `domain.plan_item.brief_artifact_path`, `domain.plan_item.brief_sha256`, and `domain.plan_item.plan_snapshot_sha256` for each item to be spawned.
   - Verify each artifact exists and its hash matches `brief_sha256`.
   - Verify no dependency cycle appeared in the stored graph.
4. For each now-unblocked item in topological order:
   - Before any worktree mutation, atomically claim the item under the Flightdeck state-lock:
     - Compare-and-swap `entry.state` from `waiting` to `spawning`.
     - Refuse to spawn if `entry.domain.plan_item.pr_number !== null`.
     - Refuse to spawn if `entry.domain.plan_item.merge_commit !== null`.
     - Refuse to spawn if a live pane is already registered for this entry.
     - On refusal, leave the entry unchanged, emit activity `plan-spawn-refused item=<ITEM_ID> reason=<reason>`, and continue to the next unblocked item.
   - Create its worktree with the worktree skill.
   - Write `<worktree>/tmp/brief.md` with the same header and verified immutable brief artifact documented in `workflows/plan/start.md` § 4; do not reintroduce omitted orchestration context. Track whether the brief was written so failure cleanup can remove it.
   - Spawn with `flightdeck-session start --kind workflow --prompt "Read tmp/brief.md and execute end-to-end. Follow its supervisor-handshake instructions. Print only what the brief tells you to print as the LAST line."` (matches `plan/start.md` § 4 step 5) and record the spawned pane id/entry metadata if creation succeeds.
   - Re-register / restore `entry.domain.plan_item` while preserving launch metadata, then transition item to in-progress with `state="submitting"` and `domain.plan_item.phase="in-progress"`.
   - On any create/write/spawn/register failure, remove `<worktree>/tmp/brief.md` if it was written, kill any spawned-but-unregistered pane, mark the entry `state="failed"` with `domain.plan_item.error = {phase:"<PHASE>", reason:"<REASON>", stderr:"<STDERR>"}`, emit activity `plan-spawn-failed item=<ITEM_ID> phase=<PHASE> reason=<REASON>`, and continue to the next unblocked item.
5. Yield after all now-unblocked items either spawn, fail, or are refused.

Never ask a child pane to run a master-side plan command. Spawned item prompts are self-contained implementation briefs.

---

## § 6: Plan-specific cleanup scope

Plan cleanup may affect only the tracked item's own resources:

- Worktree target must equal `domain.plan_item.worktree`.
- Branch target must equal the stored plan item branch/worktree name.
- Sibling plan worktrees are always declined/kept, even if the prompt proposes batch cleanup.
- No cleanup runs until `workflows/plan/close-item.md` verifies `gh pr view <PR> --json state,mergeStateStatus,mergeCommit` with `state === "MERGED"` and `mergeCommit !== null`.

## Returns

To `plan/watch.md` § 4 (or back to it after the shared review workflow returns).
