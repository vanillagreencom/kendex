# Oversee

Standing fleet mode: burn down unblocked work items by launching one orch session per item and shepherding every PR to merge. The overseer launches, watches, unblocks, and merges — it never implements or reviews. It runs unattended by default: the user may be gone for hours, so a blocked lane is the overseer's to unblock, not the user's to notice.

## 1. Resolve The Launch Surface

Once per session, first match wins:

1. `$TMUX` set → tmux lanes: launch each item with `open-terminal` (`lanes pick` chooses the account lane; launch flags sized per item — `handoff.md` § 2).
2. The harness ships session or thread launching (Codex threads, Claude Code agent teams, a desktop app's session tool or bundled skill) → use it: one managed session per item, carrying the same brief `open-terminal` would render.
3. Neither → no parallel surface. Say so once and work the queue sequentially in this session: `start [ISSUE_ID]` per item, § 2 selection between items.

## 2. Select Work

Unblocked, non-terminal items from the tracker, gated exactly as `start.md` gates them (ancestor chain, blocker union, container rules). A GitHub item labeled `blocked` is not a candidate (the tracker's only "not for the fleet" signal, mirroring Linear's blocked label). Ownership is settled by tooling, not judgment: an item whose `worktree create` exits 75 belongs to another session. On the tmux surface that claim IS `open-terminal`'s own worktree create — never pre-create the worktree; an owned item is skipped and its siblings still launch. A surface that creates its own worktree environment (Codex app threads) records the claim in workflow-state before launch; that record is not atomic, so it guards a restarted overseer against re-launching; oversee runs as at most one session per repo, and that single-launcher rule is what keeps two lanes off one item. Read the lane cap and keep at most that many items in flight:

```bash
.agents/skills/orch/scripts/orch-env ORCH_OVERSEER_LANES 3
```

## 3. Launch

Per item, mint the brief `/orch start [ISSUE_ID]` (or `/orch start github [OWNER/REPO]#[N]`) plus the terminal condition: the item is complete only when its PR is MERGED and its worktree cleaned up — an opened PR is not done. The brief also carries question routing: "If your harness can message other sessions (a session list plus a send-message tool), push any blocking question to the overseer session that launched you the moment it arises — the user may not be watching this session — and still raise it locally through your normal question tool. Without such messaging, just ask normally; the overseer's watch will find it." `/orch` slash syntax does nothing in Codex: a Codex CLI lane uses the form open-terminal renders — `Read .agents/skills/orch/SKILL.md and execute the orch start workflow for [ITEM]` — and a Codex Desktop thread uses `$orch start [ITEM]` (`handoff.md` § 2), each still carrying the terminal condition. Size launch flags to the item and launch on the § 1 surface.

Record the lane (`[NOW]` as `date -u +%Y-%m-%dT%H:%M:%SZ`; the first lane's value is the fleet start that § 4 passes as `--since`). First use only — when `exists` reports false, run `init` (init overwrites: never re-init a live lane log):

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

One blocking command, passed the fleet's start as `--since` (the first lane's `launched_at` — the same value on every run, never "now", so a merge landing between two runs is still reported by the next), `--item` for every live item, and every live lane's tmux window name (none on a non-tmux surface); it exits on the first event that needs the overseer and prints one event: an `EVENT` line, or for `merged` one `EVENT merged` line per merged item — handle every line. Re-run it after handling each event with the live set updated — a merged item and a dead lane's window drop out. Never hand-roll a monitor. It runs `pr-watch.sh` when the review-gate skill is installed and skips that step otherwise (`gate-stale` is then invisible — [references/gates.md](../references/gates.md) § Multi-PR watching); only a new `<pr> <kind>` line is itself an event, and the baseline persists across re-runs of the fleet — keyed on the repo and `--since`, one more reason the same `--since` goes to every run — so attention that arrives between two runs is the next run's event, while attention standing since the fleet's first run is context appended to the next event.

```bash
.agents/skills/orch/scripts/oversee-watch --interval 240 --since [FLEET_SINCE] --item [ISSUE_ID]... [LANE_WINDOW...]
```

- `merged` → mark the lane done, launch the next unblocked item.
- A lane stopped by a harness session limit ("You've hit your session limit · resets HH:MM") is not dead: resume it under another auth lane (`lanes pick`; a Claude session resumed under a different `CLAUDE_CONFIG_DIR` needs its session files copied there), or wait for the shown reset and send the lane a one-line continuation nudge.
- `window-gone`, or any lane whose session ended with no merged PR → inspect its worktree and PR state, re-launch once with the same brief; a second death is surfaced to the user, not retried.
- `question` → answer it when available evidence already decides it: repo state, the issue body, a stated convention — including scope-narrowing calls and a lane's own well-argued recommendation. Relay to the user only what changes the product for a user or spends the owner's standing (retiring a reviewer, filing outside the repo, closing as won't-do). Either way, send the answer back to the lane. Non-tmux surfaces are covered by pushed questions; a surface with neither messaging nor an inspectable pane makes prolonged lane silence itself the needs-attention signal — inspect the session through that surface's own status tools.
- `pr-watch` → act on its attention lines; `heartbeat` → nothing needs the overseer, re-run.

## 5. Stop

Queue empty, or the user stops it. Report one line per lane: merged SHAs, still-open PRs, items skipped as owned or blocked.
