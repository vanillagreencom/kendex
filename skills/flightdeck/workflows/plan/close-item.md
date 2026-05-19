# Workflow: `plan close-item` — Verify Merge + Close Plan Item

Recognize terminal state for one plan item, verify the PR is actually merged through GitHub, record the merge commit, and safely tear down only that item's pane/worktree.

**Inputs**: `<ITEM_ID>`.

**Pre-conditions**:
- Entry has `domain.plan_item`.
- Caller saw `terminal-state-reached` or equivalent completion signal.
- `gh` is authenticated.

**Post-condition**: item entry is `merged` or `aborted`, `domain.plan_item.merge_commit` is persisted when merged, and the pane/window is safely torn down. The registry entry remains for `plan/terminate.md`.

---

## § 1: Load entry

Read normalized entry:

```bash
ENTRY_JSON=$(.agents/skills/flightdeck/scripts/pane-registry list --format json \
  | jq -c --arg id "<ITEM_ID>" '.[] | select((.id // .domain.plan_item.item_id) == $id)')
```

Require `domain.plan_item.plan_path`, `domain.plan_item.item_id`, `domain.plan_item.item_title`, and `domain.plan_item.worktree`. If missing, set `paused_for_user = {entry_id:<ITEM_ID>, reason:"domain-mismatch", prompt_text:"missing domain.plan_item"}` and return.

---

## § 2: gh failure policy

Every `gh pr view` command:

1. Run once.
2. Retry once after 2s on non-zero exit.
3. On second failure, emit activity warning `plan-gh-cli-unavailable item=<ITEM_ID> command=<cmd> stderr=<stderr>`, set `paused_for_user.reason="gh-cli-unavailable"`, and return without closing, cleanup, or teardown.

---

## § 3: Authoritative merge verification (required)

Pane-buffer text alone is never sufficient. Before any worktree cleanup or terminal item closure, require all of these:

1. Tracked entry has recorded `entry.domain.plan_item.pr_number`.
2. Authoritative PR view says merged:
   ```bash
   gh pr view <PR> --json state,mergeStateStatus,mergeCommit
   ```
   Required: `state === "MERGED"` AND `mergeCommit !== null`.

Two-signal rule for plan lane means: `domain.plan_item.pr_number` recorded + authoritative `gh pr view` merged result. Pane text like `MERGED`, `session complete`, or a stale terminal banner is advisory only and never closes an item by itself.

---

## § 4: Determine outcome

- `state === "MERGED"` and `mergeCommit !== null` → outcome `merged`.
- PR missing or PR not merged → return to watch without teardown unless § 2 paused. The child may have printed completion before GitHub finished.
- `state == "MERGED"` but `mergeCommit == null` → set `paused_for_user = {entry_id:<ITEM_ID>, reason:"gh-pr-merge-commit-missing", prompt_text:<gh pr view JSON>}` and do not clean up or tear down. This rare GitHub inconsistency needs operator visibility.
- PR closed without merge → outcome `aborted` only if a separate explicit abort/cancel signal exists; otherwise pause for user.

---

## § 5: Update master state

Persist merged outcome:

```bash
.agents/skills/flightdeck/scripts/pane-registry set-state <ITEM_ID> merged
.agents/skills/flightdeck/scripts/pane-registry set <ITEM_ID> merge_commit '"<MERGE_COMMIT_SHA>"'
.agents/skills/flightdeck/scripts/pane-registry log-decision <ITEM_ID> terminal-state-reached "merged via authoritative gh pr view"
```

Because the entry is plan-domain, `pane-registry set <ITEM_ID> merge_commit ...` must write to `entry.domain.plan_item.merge_commit`.

For aborted outcome, set state `aborted`, set `domain.plan_item.phase="aborted"`, and log the explicit abort signal.

For merged outcomes only, immediately run the safe post-merge local-main sync helper after the state/pr/merge fields are recorded and before teardown/cleanup:

```bash
.agents/skills/flightdeck/scripts/flightdeck-repo-sync main --project-root <PROJECT_ROOT> --remote origin --branch main --json
```

Branch only on JSON `status`. `synced|already-synced` records/reports `repo.main_synced`; `blocked` records/reports `repo.main_sync_blocked` with `ahead`, `behind`, `dirty_paths`, `reason`, and `commands_suggested`; `failed` records/reports `repo.main_sync_failed`. Sync block/failure never downgrades the already verified PR outcome and never authorizes reset, stash, discard, or force-push. Do not run this helper for queued auto-merge or any state that is not observably merged.

---

## § 6: Tear down window safely

Use the stable-pane teardown contract:

```bash
.agents/skills/flightdeck/scripts/pane-registry teardown-window <ITEM_ID>
```

Never derive a kill target from `pane_target`. Respect helper exit codes:

| Exit | Meaning | Action |
|------|---------|--------|
| `0` | window/pane killed or already closed | proceed |
| `1` | entry missing | idempotent no-op |
| `3` | pane gone but state drift existed | log warning, continue |
| `4` | live pane but non-terminal state | abort; ordering bug |
| `5` | tmux kill failed | surface stderr |
| `6` | registry read failure | abort; state corruption |

Entry remains for `plan/terminate.md`; do not remove it here.

---

## § 7: Worktree cleanup

After § 3 authoritative merge verification and § 5 state persistence, clean up only the item's own worktree when the cleanup policy allows it:

```bash
.agents/skills/worktree/scripts/worktree remove <WORKTREE_PATH>
```

Rules:

- `<WORKTREE_PATH>` must exactly equal `domain.plan_item.worktree`.
- Never remove sibling plan worktrees.
- If cleanup fails because the branch is still protected, dirty, or not merged locally, keep the worktree and include the failure in `plan/terminate.md`; do not downgrade the already verified merge outcome.

---

## § 8: Emit completion line

<output_format>
[For merged:]
Plan item [ITEM_ID] ✅ merged — PR #[PR] ([MERGE_COMMIT_SHORT]) — window closed

[For aborted:]
Plan item [ITEM_ID] ⨯ aborted — window closed
</output_format>

## Returns

To `plan/watch.md` for the next polling pass and dependency-edge resolution.
