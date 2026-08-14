# Oversee

Standing fleet mode: burn down unblocked work items by launching one orch session per item and shepherding every PR to merge. The overseer launches, watches, unblocks, and merges — it never implements or reviews.

## 1. Resolve The Launch Surface

Once per session, first match wins:

1. `$TMUX` set → tmux lanes: launch each item with `open-terminal` (`lanes pick` chooses the account lane; launch flags sized per item — `handoff.md` § 2).
2. The harness ships session or thread launching (Codex threads, Claude Code agent teams, a desktop app's session tool or bundled skill) → use it: one managed session per item, carrying the same brief `open-terminal` would render.
3. Neither → no parallel surface. Say so once and work the queue sequentially in this session: `start [ISSUE_ID]` per item, § 2 selection between items.

## 2. Select Work

Unblocked, non-terminal items from the tracker, gated exactly as `start.md` gates them (ancestor chain, blocker union, container rules). Ownership is settled by tooling, not judgment: an item whose `worktree create` exits 75 belongs to another session — skip it. Every surface claims through that same gate — create the item's worktree (or record the claim in workflow-state) BEFORE launching its session; thread/session surfaces have no other atomic claim, and two lanes must never take one item. Read the lane cap and keep at most that many items in flight:

```bash
.agents/skills/orch/scripts/orch-env ORCH_OVERSEER_LANES 3
```

## 3. Launch

Per item, mint the brief `/orch start [ISSUE_ID]` (or `/orch start github [OWNER/REPO]#[N]`) plus the terminal condition: the item is complete only when its PR is MERGED and its worktree cleaned up — an opened PR is not done. `/orch` slash syntax does nothing in Codex: a Codex CLI lane uses the form open-terminal renders — `Read .agents/skills/orch/SKILL.md and execute the orch start workflow for [ITEM]` — and a Codex Desktop thread uses `$orch start [ITEM]` (`handoff.md` § 2), each still carrying the terminal condition. Size launch flags to the item and launch on the § 1 surface.

Record the lane. First use only — when `exists` reports false, run `init` (init overwrites: never re-init a live lane log):

```bash
.agents/skills/orch/scripts/workflow-state exists --json oversee
```
```bash
.agents/skills/orch/scripts/workflow-state init oversee
```
```bash
.agents/skills/orch/scripts/workflow-state append oversee lanes '{"issue":"[ISSUE_ID]","surface":"[SURFACE]","launched_at":"[NOW]"}'
```

## 4. Watch And Advance

When `.agents/skills/review-gate/scripts/pr-watch.sh` exists, run it as the single state reducer across every open PR — it exits 2 without `GH_REPO`, so resolve and export it in the same call; otherwise fall back to per-PR `approval-wait`/`queue-wait` ([references/gates.md](../references/gates.md)). Never hand-roll a transition-keyed monitor. On a Codex lane the export-plus-reducer shape below is classifier-rejected with no compliant rewrite — use the per-PR waiter fallback there.

```bash
export GH_REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
.agents/skills/review-gate/scripts/pr-watch.sh
```

- A lane's PR merges → mark the lane done, launch the next unblocked item.
- A lane's session ends with no merged PR → inspect its worktree and PR state, re-launch once with the same brief; a second death is surfaced to the user, not retried.
- A lane blocks on something only its own session can answer → that is the lane's report to surface, not the overseer's to answer.

## 5. Stop

Queue empty, or the user stops it. Report one line per lane: merged SHAs, still-open PRs, items skipped as owned or blocked.
