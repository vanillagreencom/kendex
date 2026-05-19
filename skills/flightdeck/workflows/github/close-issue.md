# Workflow: `github close-issue` — Verify Merge + Close GitHub Issue

Recognize terminal state for one GitHub issue, verify the PR is actually merged through GitHub, close the issue only when needed, and safely tear down the pane.

**Inputs**: `<ISSUE_NUMBER>`.

**Pre-conditions**:
- Entry has `domain.github_issue`.
- Caller saw `terminal-state-reached` or equivalent completion signal.
- `gh` is authenticated.

**Post-condition**: issue entry is `merged` or `aborted`, `domain.github_issue.merge_commit` is persisted when merged, and the pane/window is safely torn down. The registry entry remains for `github/terminate.md`.

---

## § 1: Load entry

Read normalized entry:

```bash
ENTRY_JSON=$(.agents/skills/flightdeck/scripts/pane-registry list --format json \
  | jq -c --arg id "<ISSUE_NUMBER>" '.[] | select((.id // (.domain.github_issue.number|tostring?)) == $id)')
```

Require `domain.github_issue.number`, `domain.github_issue.url`, and `domain.github_issue.worktree`. If missing, set `paused_for_user = {issue_id:<N>, reason:"domain-mismatch", prompt_text:"missing domain.github_issue"}` and return.

---

## § 2: gh failure policy

Every `gh pr view`, `gh issue view`, and `gh issue close` command:

1. Run once.
2. Retry once after 2s on non-zero exit.
3. On second failure, emit activity warning `gh-cli-unavailable issue=<N> command=<cmd> stderr=<stderr>`, set `paused_for_user.reason="gh-cli-unavailable"`, and return without closing or tearing down.

---

## § 3: Authoritative merge verification (required)

Pane-buffer text alone is never sufficient. Before any call to `gh issue close <N> --reason completed`, require all of these:

1. Tracked entry has recorded `entry.domain.github_issue.pr_number`.
2. Authoritative PR view says merged:
   ```bash
   gh pr view <PR> --json state,mergeStateStatus,mergeCommit
   ```
   Required: `state === "MERGED"` AND `mergeCommit !== null`.
3. If the issue is already closed:
   ```bash
   gh issue view <N> --json state
   ```
   and `state == "CLOSED"`, no-op cleanly. Emit structured log line:
   ```text
   github-close-issue issue=<N> pr=<PR> already-closed auto-closed-by-fixes
   ```
   Do not throw and do not call `gh issue close` again.
4. If issue is open after PR merge verification, close it:
   ```bash
   gh issue close <N> --reason completed
   ```

Two-signal rule for GitHub lane means: `domain.github_issue.pr_number` recorded + authoritative `gh pr view` merged result. Pane text like `MERGED`, `session complete`, or a stale terminal banner is advisory only and never closes an issue by itself.

---

## § 4: Determine outcome

- `state === "MERGED"` and `mergeCommit !== null` → outcome `merged`.
- PR missing or PR not merged → return to watch without teardown unless § 2 paused. The child may have printed completion before GitHub finished.
- `state == "MERGED"` but `mergeCommit == null` → set `paused_for_user = {issue_id:<N>, reason:"gh-pr-merge-commit-missing", prompt_text:<gh pr view JSON>}` and do not close or tear down. This rare GitHub inconsistency needs operator visibility.
- PR closed without merge → outcome `aborted` only if a separate explicit abort/cancel signal exists; otherwise pause for user.

---

## § 5: Update master state

Persist merged outcome:

```bash
.agents/skills/flightdeck/scripts/pane-registry set-state <N> merged
.agents/skills/flightdeck/scripts/pane-registry set <N> merge_commit '"<MERGE_COMMIT_SHA>"'
.agents/skills/flightdeck/scripts/pane-registry log-decision <N> terminal-state-reached "merged via authoritative gh pr view"
```

Because the entry is GitHub-domain, `pane-registry set <N> merge_commit ...` must write to `entry.domain.github_issue.merge_commit`.

For aborted outcome, set state `aborted` and log the explicit abort signal.

For merged outcomes only, immediately run the safe post-merge local-main sync helper after the state/pr/merge fields are recorded and before teardown:

```bash
.agents/skills/flightdeck/scripts/flightdeck-repo-sync main --project-root <PROJECT_ROOT> --remote origin --branch main --json
```

Branch only on JSON `status`. `synced|already-synced` records/reports `repo.main_synced`; `blocked` records/reports `repo.main_sync_blocked` with `ahead`, `behind`, `dirty_paths`, `reason`, and `commands_suggested`; `failed` records/reports `repo.main_sync_failed`. Sync block/failure never downgrades the already verified PR outcome and never authorizes reset, stash, discard, or force-push. Do not run this helper for queued auto-merge or any state that is not observably merged.

---

## § 6: Tear down window safely

Use the same stable-pane teardown contract as Linear:

```bash
.agents/skills/flightdeck/scripts/pane-registry teardown-window <N>
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

Entry remains for `github/terminate.md`; do not remove it here.

---

## § 7: Emit completion line

<output_format>
[For merged:]
GitHub issue #[N] ✅ merged — PR #[PR] ([MERGE_COMMIT_SHORT]) — window closed

[For aborted:]
GitHub issue #[N] ⨯ aborted — window closed
</output_format>

## Returns

To `github/watch.md` for the next polling pass.