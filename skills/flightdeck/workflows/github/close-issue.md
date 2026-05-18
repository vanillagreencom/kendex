# Workflow: `github close-issue` — Recognize Terminal State + Tear Down Pane

Inner pane has signaled it's done. Verify the signal, mark the GitHub issue terminal in master state, close the GitHub issue if the PR merge did not auto-close it, kill the window, leave the registry entry in place for the final report, and let the watch loop's termination check fire.

GitHub issue-mode workflow only. Generic/ad-hoc terminal signals stay in `workflows/shared/session-handle-prompt.md`; `github/watch.md` layers this two-signal verification and safe teardown on top of the generic `workflows/shared/session-watch.md` underlay.

**Inputs**: `<ISSUE_ID>`. Caller (`github/watch.md` § 3) routes here when `pane-poll` returns the `terminal-state-reached` tag.

**Pre-conditions**: issue is registered; pane is alive but signaling completion; the issue agent's own PR / cleanup steps already ran (their output is what we're reading).

**Post-condition**: issue's `state` = `merged` or `aborted` in master state; GitHub issue is closed with reason `completed` if needed; tmux window for the issue is gone; pane registry entry remains for `terminate.md` reporting and final cleanup; completion line emitted.

---

## § 1: Verify Terminal State (Two-Signal Rule)

A single sentinel match is not sufficient — pane output can include words like "MERGED" mid-session (for example, quoting a commit message). Require **at least two independent signals** before tearing down.

**Fast-path — orphaned (worktree gone + PR merged)**: when the registry's `worktree` directory does not exist on disk AND `gh pr view <pr_number>` returns `state: MERGED`, the issue is observably done regardless of pane content. The two-signal rule is satisfied by the worktree-gone + PR-merged pair; skip the buffer-signal accumulation and proceed directly to § 3 with `state = merged`.

Signals (any two):

| Signal | Source |
|--------|--------|
| Pane buffer contains `MERGED` banner with a PR reference (`PR #123`) | `tmux capture-pane` |
| Pane buffer contains explicit "Please end the session" / "session complete" | `tmux capture-pane` |
| Pane buffer contains destroyed-CWD failure pattern | `tmux capture-pane` (harness-specific — see adapter below) |
| Pane is idle (harness-specific quiescent indicator) | `tmux capture-pane` (harness-specific) |
| PR for this issue is `state == MERGED` (or PR was closed without merge) | `gh pr view <PR> --json state` |
| GitHub issue state is `CLOSED` for this issue | `gh issue view <ISSUE_ID> --json state` |

Implementation:

1. Read pane: `tmux capture-pane -t "${pane_id:-$pane_target}" -p -S -200`. Prefer the stable `pane_id` (`%N`) from the registry over the human-readable `pane_target` — tmux reuses window indices after windows are destroyed, so a stale `pane_target` can after-the-fact point to an unrelated window.
2. Apply portable buffer signals (banner, end-session text).
3. Apply harness-specific signals via the adapter for the registered harness:
   - **Claude Code**: idle indicator `* Idle` on its own line near buffer end; destroyed-CWD pattern includes `Path does not exist` and a path matching the worktree.
   - Other harnesses: add an adapter in `patterns/tmux-monitoring.md` § Per-harness signals; do not blanket-apply Claude Code's patterns.
4. Apply external signals: query PR state if `pr_number` is set; query GitHub issue state.
5. Count matched signals. If `< 2`, return to caller without tearing down — re-poll next cycle. False positive risk is not zero; favor an extra poll over a wrong teardown.

---

## § 2: Determine Outcome

Map signals to terminal state:

- PR state `MERGED` (or buffer banner says `MERGED`) → `state = merged`.
- PR state `CLOSED` without merge AND GitHub issue state `CLOSED` → `state = aborted`.
- Pane signals end-of-session but PR state is still `OPEN` and no other signal contradicts → return without teardown; the issue agent may have ended its turn but the merge hasn't actually landed yet. Re-poll.

Capture the outcome's summary fields from the buffer if present (PR number, merge commit, branch deleted-on-remote, etc.) — these go into the GitHub issue end-of-session report (`terminate.md` § 2).

---

## § 3: Close GitHub Issue If Needed

**Skip if** `state != merged`.

1. Query issue state:
   ```bash
   gh issue view "$ISSUE_ID" --json state,url
   ```
2. If `state == CLOSED`, do nothing; the PR's `Fixes #N` linkage or a user action already closed it.
3. If `state == OPEN`, close it with completed reason:
   ```bash
   gh issue close "$ISSUE_ID" --reason completed
   ```
4. If close fails because the issue is already closed or cannot be found after a successful merge, log a warning and continue. If close fails for auth/rate-limit, set `paused_for_user` with the stderr and do not tear down yet.

---

## § 4: Update Master State

```
.agents/skills/flightdeck/scripts/pane-registry set-state <ISSUE_ID> <merged|aborted>
.agents/skills/flightdeck/scripts/pane-registry log-decision <ISSUE_ID> terminal-state-reached "<outcome-summary>"
```

Persist any captured summary fields via `pane-registry set <ISSUE_ID> <field> <value>`.

---

## § 5: Tear Down Window

Delegate the destructive teardown to the registry. **Never** derive a kill target from `pane_target` (`session:window.index`) — tmux reuses window indices after windows are destroyed, so the stored `pane_target` can after-the-fact point to an unrelated window. The registry stores a stable `pane_id` (`%N`) at init time; the helper uses it as the only correct destructive target.

This step runs AFTER § 4 has already written the terminal state (`merged|aborted|dead`). The helper enforces that contract — it will refuse to kill an alive pane whose registry state is non-terminal unless `--force` is passed.

1. Run the safe teardown:
   ```
   .agents/skills/flightdeck/scripts/pane-registry teardown-window <ISSUE_ID>
   ```
2. Branch on the helper's exit code:

   | Exit | Meaning | Action |
   |------|---------|--------|
   | `0` | window/pane killed, OR already closed (terminal + dead pane) | proceed to § 6 |
   | `1` | issue not registered — already removed by terminate or earlier cleanup | idempotent no-op; proceed to § 6 |
   | `3` | registry drift: `pane_id` gone but state is non-terminal | log a warning and continue; state from § 4 preserves outcome |
   | `4` | policy refusal: pane is alive but state is non-terminal | log stderr and abort; do NOT silently rerun with `--force` |
   | `5` | tmux kill failed: pane is still alive after the kill attempt | forward stderr; user may need to kill manually |
   | `6` | registry read failure | forward stderr; abort |

3. Verify the window is gone (defensive, skipped on exit 3/4/5/6): `tmux list-panes -a -F '#{pane_id}' | grep -qFx "<pane_id>"` — if the recorded `pane_id` is still alive after a `0` exit, log a warning.

Pane registry entry is left in place for the GitHub issue end-of-session report. Do NOT call `pane-registry remove` here — terminate is responsible for final cleanup.

---

## § 6: Emit Completion Line

Per SKILL.md "Format Tags Are Literal": fill placeholders, omit empty fields, add nothing else.

<output_format>
[For merged:]
#[ISSUE_ID] ✅ merged — PR #[N] ([MERGE_COMMIT_SHORT]) — GitHub issue closed — window closed

[For aborted:]
#[ISSUE_ID] ⨯ aborted — window closed
</output_format>

Goes through the same channel as the watch loop's other status output.

---

## § 7: Advance Queue

If no panes remain alive (every tracked GitHub issue is in `merged | aborted | dead`):

1. The watch loop's termination check will fire after `FLIGHTDECK_DEBOUNCE_CYCLES` consecutive cycles confirm all-done.

Otherwise, continue normally — the watch loop's § 3 poll will pick up the next active pane on its next pass.

---

## Skip-If

- The two-signal rule was not satisfied → return to `github/watch.md` § 3 without teardown; re-poll next cycle.
- The issue is already terminal and its window is already gone (or terminate's final cleanup already removed the registry entry) → idempotent; just log and return.

## Returns

To `github/watch.md` § 3 (continue polling remaining panes).
