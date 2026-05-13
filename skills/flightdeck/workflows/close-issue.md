# Workflow: `close-issue` — Recognize Terminal State + Tear Down Pane

Inner pane has signaled it's done. Verify the signal, mark the issue terminal in master state, kill the window, leave the registry entry in place for the final report, and either advance to the next queued issue or let the watch loop's termination check fire.

**Inputs**: `<ISSUE_ID>`. Caller (`watch.md` § 2) routes here when `pane-poll` returns the `terminal-state-reached` tag.

**Pre-conditions**: issue is registered; pane is alive but signaling completion; orchestration's own merge / cleanup steps already ran (their output is what we're reading).

**Post-condition**: issue's `state` = `merged` or `aborted` in master state; tmux window for the issue is gone; pane registry entry remains for `terminate.md` reporting and final cleanup; completion line emitted.

**Cleanup scope under Flightdeck**: per-issue finalization (the inner pane's `orchestration merge-pr` flow) honors a Flightdeck-mode guard via `skills/orchestration/scripts/flightdeck-mode`. The inner sweep is restricted to artifacts owned by the asking issue (its registered worktree, its registered branch, and the remote branch of its PR). Cross-branch / cross-worktree maintenance is the master's responsibility (or a standalone manual `merge-pr` run from outside Flightdeck); if a destructive prompt about unrelated artifacts still surfaces, `patterns/prompt-handlers.md` (`stale-no-pr-branch`, `stale-orphan-worktree`) tells master to answer `Keep ...`.

---

## § 1: Verify Terminal State (Two-Signal Rule)

A single sentinel match is not sufficient — pane output can include words like "MERGED" mid-session (e.g., quoting a commit message). Require **at least two independent signals** before tearing down.

**Fast-path — orphaned (worktree gone + PR merged)**: when the registry's `worktree` directory does not exist on disk AND `gh pr view <pr_number>` returns `state: MERGED`, the issue is observably done regardless of pane content. The two-signal rule is satisfied by the worktree-gone + PR-merged pair; skip the buffer-signal accumulation and proceed directly to § 3 with `state = merged`. This is the path triggered when `pane-poll` synthesizes `terminal-state-reached` via its `--worktree` / `--pr` cross-check.

Signals (any two):

| Signal | Source |
|--------|--------|
| Pane buffer contains `MERGED` banner with a PR reference (`PR #123`) | `tmux capture-pane` |
| Pane buffer contains explicit "Please end the session" / "session complete" | `tmux capture-pane` |
| Pane buffer contains destroyed-CWD failure pattern | `tmux capture-pane` (harness-specific — see adapter below) |
| Pane is idle (harness-specific quiescent indicator) | `tmux capture-pane` (harness-specific) |
| PR for this issue is `state == MERGED` (or PR was closed without merge) | `gh pr view <PR> --json state` |
| Issue tracker state is `Done` / `Cancelled` for this issue | tracker integration (linear / github-issues / etc.) |

Implementation:

1. Read pane: `tmux capture-pane -t <pane_target> -p -S -200`.
2. Apply portable buffer signals (banner, end-session text).
3. Apply harness-specific signals via the adapter for the registered harness:
   - **Claude Code**: idle indicator `* Idle` on its own line near buffer end; destroyed-CWD pattern includes `Path does not exist` and a path matching the worktree.
   - Other harnesses: add an adapter in `patterns/tmux-monitoring.md` § Per-harness signals; do not blanket-apply Claude Code's patterns.
4. Apply external signals: query PR state if `pr_number` is set; query tracker state if cheap.
5. Count matched signals. If `< 2`, return to caller without tearing down — re-poll next cycle. False positive risk is not zero; favor an extra poll over a wrong teardown.

---

## § 2: Determine Outcome

Map signals to terminal state:

- PR state `MERGED` (or buffer banner says `MERGED`) → `state = merged`.
- PR state `CLOSED` without merge AND issue tracker state cancelled → `state = aborted`.
- Pane signals end-of-session but PR state is still `OPEN` and no other signal contradicts → return without teardown; the orchestrator may have ended its turn but the merge hasn't actually landed yet. Re-poll.

Capture the outcome's summary fields from the buffer if present (PR number, merge commit, branch deleted-on-remote, etc.) — these go into the end-of-session report (`terminate.md` § 1).

---

## § 3: Update Master State

```
.agents/skills/flightdeck/scripts/pane-registry set-state <ISSUE_ID> <merged|aborted>
.agents/skills/flightdeck/scripts/pane-registry log-decision <ISSUE_ID> terminal-state-reached "<outcome-summary>"
```

Persist any captured summary fields via `pane-registry set <ISSUE_ID> <field> <value>`.

---

## § 4: Tear Down Window

1. Resolve the window: `WINDOW_TARGET="${pane_target%.*}"` (strip the pane index suffix).
2. Kill the window: `tmux kill-window -t "$WINDOW_TARGET"`.
3. Verify it's gone: `tmux list-windows -F '#{window_name}' | grep -qx "<window-name>"` — if still present, log a warning and continue (don't escalate; the user can clean up manually).

Pane registry entry is left in place for the end-of-session report (see `terminate.md` § 1). It carries the issue's history. Do NOT call `pane-registry remove` here — terminate is responsible for the final cleanup.

---

## § 5: Emit Completion Line

Per SKILL.md "Format Tags Are Literal": fill placeholders, omit empty fields, add nothing else.

<output_format>
[For merged:]
[ISSUE_ID] ✅ merged — PR #[N] ([MERGE_COMMIT_SHORT]) — window closed

[For aborted:]
[ISSUE_ID] ⨯ aborted — window closed
</output_format>

Goes through the same channel as the watch loop's other status output.

---

## § 6: Advance Queue

If `master_state.merge_queue` (or any other pending-issue queue) has more issues to process:

1. Continue normally — the watch loop's § 2 poll will pick up the next active pane on its next pass.

If no panes remain alive (every tracked issue is in `merged | aborted | dead`):

1. The watch loop's § 6 termination check will fire after `FLIGHTDECK_DEBOUNCE_CYCLES` consecutive cycles confirm all-done.

Either way, this workflow returns to `watch.md` § 2 for the next polling pass.

---

## Skip-If

- The two-signal rule was not satisfied → return to `watch.md` § 2 without teardown; re-poll next cycle.
- The issue is already terminal and its window is already gone (or terminate's final cleanup already removed the registry entry) → idempotent; just log and return.

## Returns

To `watch.md` § 2 (continue polling remaining panes).
