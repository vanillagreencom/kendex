# Oversee

Standing fleet mode: burn down unblocked work items by launching one orch session per item and shepherding every PR to merge. The overseer launches, watches, unblocks, and merges — it never implements or reviews.

## 1. Resolve The Launch Surface

Once per session, first match wins:

1. `$TMUX` set → tmux lanes: launch each item with `open-terminal` (`lanes pick` chooses the account lane; launch flags sized per item — `handoff.md` § 2).
2. The harness ships session or thread launching (Codex threads, Claude Code agent teams, a desktop app's session tool or bundled skill) → use it: one managed session per item, carrying the same brief `open-terminal` would render.
3. Neither → no parallel surface. Say so once and work the queue sequentially in this session: `start [ISSUE_ID]` per item, § 2 selection between items.

## 2. Select Work

Unblocked, non-terminal items from the tracker, gated exactly as `start.md` gates them (ancestor chain, blocker union, container rules). Ownership is settled by tooling, not judgment: an item whose `worktree create` exits 75 belongs to another session — skip it. Keep at most `ORCH_OVERSEER_LANES` items in flight.

## 3. Launch

Per item, mint the brief `/orch start [ISSUE_ID]` (or `/orch start github [OWNER/REPO]#[N]`), size launch flags to the item, and launch on the § 1 surface. Record the lane:

```bash
.agents/skills/orch/scripts/workflow-state append oversee lanes '{"issue":"[ISSUE_ID]","surface":"[SURFACE]","launched_at":"[NOW]"}'
```

## 4. Watch And Advance

When `.agents/skills/review-gate/scripts/pr-watch.sh` exists, run it as the single state reducer across every open PR; otherwise fall back to per-PR `approval-wait`/`queue-wait` ([references/gates.md](../references/gates.md)). Never hand-roll a transition-keyed monitor.

- A lane's PR merges → mark the lane done, launch the next unblocked item.
- A lane's session ends with no merged PR → inspect its worktree and PR state, re-launch once with the same brief; a second death is surfaced to the user, not retried.
- A lane blocks on something only its own session can answer → that is the lane's report to surface, not the overseer's to answer.

## 5. Stop

Queue empty, or the user stops it. Report one line per lane: merged SHAs, still-open PRs, items skipped as owned or blocked.
