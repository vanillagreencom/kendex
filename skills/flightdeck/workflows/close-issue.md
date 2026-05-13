# Workflow: `close-issue` — Recognize Terminal State + Tear Down Pane

Inner pane has signaled it's done. Verify the signal, mark the issue terminal in master state, kill the window, leave the registry entry in place for the final report, and either advance to the next queued issue or let the watch loop's termination check fire.

Issue-mode workflow only. Generic/ad-hoc terminal signals stay in `workflows/session-handle-prompt.md`; issue `watch.md` layers this two-signal verification and safe teardown on top of the generic `workflows/session-watch.md` underlay.

**Inputs**: `<ISSUE_ID>`. Caller (`watch.md` § 2) routes here when `pane-poll` returns the `terminal-state-reached` tag.

**Pre-conditions**: issue is registered; pane is alive but signaling completion; orchestration's own merge / cleanup steps already ran (their output is what we're reading).

**Post-condition**: issue's `state` = `merged` or `aborted` in master state; tmux window for the issue is gone; pane registry entry remains for `terminate.md` reporting and final cleanup; completion line emitted.

**Cleanup scope under Flightdeck**: per-issue finalization (the inner pane's `orchestration merge-pr` flow) honors a Flightdeck-mode guard via `skills/orchestration/scripts/flightdeck-mode`. The inner sweep is restricted to artifacts owned by the asking issue (its registered worktree, its registered branch, and the remote branch of its PR). Cross-branch / cross-worktree maintenance is the master's responsibility (or a standalone manual `merge-pr` run from outside Flightdeck); if a destructive prompt about unrelated artifacts still surfaces, `patterns/prompt-handlers.md` (`stale-no-pr-branch`, `stale-orphan-worktree`) tells master to answer `Keep ...`. The helper currently reads `.issues` directly via `jq`; when `docs/plans/flightdeck-session-management-reframe.md` lands, replace that with the normalized read seam introduced there.

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

1. Read pane: `tmux capture-pane -t "${pane_id:-$pane_target}" -p -S -200`. Prefer the stable `pane_id` (`%N`) from the registry over the human-readable `pane_target` — tmux reuses window indices after windows are destroyed, so a stale `pane_target` can after-the-fact point to an unrelated window (the daemon, the user's editor, etc.) and feed that window's text into the two-signal check. See `patterns/tmux-monitoring.md` § Stable-id rule.
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

Capture the outcome's summary fields from the buffer if present (PR number, merge commit, branch deleted-on-remote, etc.) — these go into the issue end-of-session report (`terminate.md` § 2).

---

## § 3: Update Master State

```
.agents/skills/flightdeck/scripts/pane-registry set-state <ISSUE_ID> <merged|aborted>
.agents/skills/flightdeck/scripts/pane-registry log-decision <ISSUE_ID> terminal-state-reached "<outcome-summary>"
```

Persist any captured summary fields via `pane-registry set <ISSUE_ID> <field> <value>`.

---

## § 4: Tear Down Window

Delegate the destructive teardown to the registry. **Never** derive a kill target from `pane_target` (`session:window.index`) — tmux reuses window indices after windows are destroyed, so the stored `pane_target` can after-the-fact point to an unrelated window (the daemon, the user's editor, ...), and a naive `tmux kill-window -t "${pane_target%.*}"` would destroy that unrelated workload (#16). The registry stores a stable `pane_id` (`%N`) at init time; the helper uses it as the only correct destructive target.

This step runs AFTER § 3 has already written the terminal state (`merged|aborted|dead`). The helper enforces that contract — it will refuse to kill an alive pane whose registry state is non-terminal unless `--force` is passed.

1. Run the safe teardown:
   ```
   .agents/skills/flightdeck/scripts/pane-registry teardown-window <ISSUE_ID>
   ```
   The helper performs the kill, verifies the pane is actually gone via a post-kill liveness check, and exits with a status that distinguishes every outcome below. `pane-registry teardown-entry <ENTRY_ID>` is an alias of the same code path anticipating the TrackedEntry schema.

2. Branch on the helper's exit code:
   | Exit | Meaning | Action |
   |------|---------|--------|
   | `0`  | window/pane killed, OR already closed (terminal + dead pane) | proceed to § 5 |
   | `1`  | issue not registered — already removed by terminate or earlier cleanup | idempotent no-op; proceed to § 5 |
   | `3`  | registry drift: `pane_id` gone but state is non-terminal. The registry says we should still be running. Do NOT derive a kill target from `pane_target` (#16). | log a warning with the issue id, skip the destructive verify in step 3, continue. The state recorded in § 3 means terminate's archive still captures the outcome. |
   | `4`  | policy refusal: pane is alive but state is non-terminal. § 3 should have set a terminal state already — this signals an ordering bug in the caller. | log the helper's stderr and abort the workflow; the user must investigate. Do NOT silently rerun with `--force`. |
   | `5`  | tmux kill failed: pane is still alive after the kill attempt. The helper has already captured the kill's stderr. | forward the helper's stderr to the user; the user may need to kill the window manually. |
   | `6`  | registry read failure (flightdeck-state broken). | forward the helper's stderr; abort the workflow. Treating this as an idempotent no-op would mask state corruption. |

3. Verify the window is gone (defensive, skipped on exit 3/4/5/6): `tmux list-panes -a -F '#{pane_id}' | grep -qFx "<pane_id>"` — if the recorded `pane_id` is still alive after a `0` exit, log a warning (don't escalate; the helper's own post-kill check already escalates to exit 5 in that case, so a positive match here is a tmux-state race the user can sort out).

Pane registry entry is left in place for the issue end-of-session report (see `terminate.md` § 2). It carries the issue's history. Do NOT call `pane-registry remove` here — terminate is responsible for the final cleanup.

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
