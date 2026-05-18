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

## § 3: Reused GitHub PR handlers

For these tags, follow the named section in `workflows/github/handle-prompt.md`, adapted only by replacing the domain reads/writes:

| Tag | GitHub handler section | Plan adaptation |
|-----|------------------------|-----------------|
| `merge-now` | § 3 | Read/write `entry.domain.plan_item.pr_number`; require `mergeStateStatus === "CLEAN"` before answering Merge. |
| `merge-ready-but-unknown` | § 4 | Preserve `entry.unknown_since`; gate wait, Merge, and force-merge transition with `FLIGHTDECK_AUTO_MERGE=0`. |
| `force-merge-confirm` | § 5 | Re-run the strict force-merge predicate immediately before answering; `FLIGHTDECK_AUTO_MERGE=0` pauses instead of answering. |
| `bot-review-wait-stuck` and issue `pi-bg-task-exit` | § 6 | Use plan PR number; never call Linear or project-management. |
| `rebase-multi-choice` | § 7 | Same preserve / apply / verify triplet; plan item worktree is `domain.plan_item.worktree`. |
| `force-push-prompt` | § 8 | Branch must be the current plan item branch / worktree; never approve sibling item force pushes. |
| `cleanup-prompt`, `stale-no-pr-branch`, `stale-orphan-worktree` | § 9 | Cleanup only when target equals `domain.plan_item.worktree` or this item branch, and terminal PR merge is already authoritative. |
| `multi-select-tabbed` | § 10 | Handle GitHub review, merge, rebase, and cleanup choices only. Linear audit/relation tabs are domain mismatch. |
| `bash-permission-prompt` issue extension | § 11 | Allow only read-only `gh` inspection; writes require the specific prompt tags above. |

Load-bearing safety rules inherited from the GitHub handler:

- `merge-now` requires fresh `gh pr view <PR> --json mergeStateStatus,reviewDecision,statusCheckRollup` and `mergeStateStatus === "CLEAN"` before answering Merge.
- `mergeStateStatus === "UNKNOWN"` routes to `merge-ready-but-unknown`; it is not merged directly.
- `FLIGHTDECK_AUTO_MERGE=0` gates `merge-now`, `merge-ready-but-unknown`, and `force-merge-confirm`.
- Strict force-merge predicate is `APPROVED ∧ all_checks_in {SUCCESS, SKIPPED} ∧ disjoint(PR_files, main_files_recently_changed) ∧ unknown_since > FLIGHTDECK_FORCE_MERGE_AFTER_SECS`.
- GitHub CLI failure retries once after 2s, then pauses; no merge, close, rebase, spawn, or cleanup proceeds on unknown GitHub state.

---

## § 4: Handler — `dependency-edge-resolution`

This is a plan-only internal routing step used by `workflows/plan/watch.md` after one item merges.

1. Read all entries with the same `domain.plan_item.plan_path`.
2. Find waiting items whose `depends_on` are all merged with non-null `merge_commit`.
3. Verify the plan file still exists and no dependency cycle appeared in the stored graph.
4. For each now-unblocked item in topological order:
   - Create its worktree with the worktree skill.
   - Write `<worktree>/tmp/brief.md` with the same header and section content shape documented in `workflows/plan/start.md` § 4.
   - Spawn with `flightdeck-session start --kind workflow --prompt "Read tmp/brief.md and execute end-to-end. Print the PR URL as the LAST line."`.
   - Update `state="submitting"` and `domain.plan_item.phase="in-progress"`.
5. If any create/write/spawn step fails, set `paused_for_user = {entry_id:<ITEM_ID>, reason:"plan-dependent-spawn-failed", prompt_text:<stderr>}` and stop.

Never ask a child pane to run a master-side plan command. Spawned item prompts are self-contained implementation briefs.

---

## § 5: Plan-specific cleanup scope

Plan cleanup may affect only the tracked item's own resources:

- Worktree target must equal `domain.plan_item.worktree`.
- Branch target must equal the stored plan item branch/worktree name.
- Sibling plan worktrees are always declined/kept, even if the prompt proposes batch cleanup.
- No cleanup runs until `workflows/plan/close-item.md` verifies `gh pr view <PR> --json state,mergeStateStatus,mergeCommit` with `state === "MERGED"` and `mergeCommit !== null`.

## Returns

To `plan/watch.md` § 4.
