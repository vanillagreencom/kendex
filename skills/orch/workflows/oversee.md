# Oversee

Standing fleet mode: burn down unblocked work items by launching one orch session per item and shepherding every PR to merge. The overseer launches, watches, unblocks, and merges — it never implements or reviews. It runs unattended: a blocked lane is the overseer's to unblock, not the user's to notice.

## 1. Resolve The Launch Surface

Once per session, first match wins:

1. `$TMUX` set → tmux lanes: launch each item with `open-terminal` (`lanes pick` chooses the account lane; launch flags sized per item — `handoff.md` § 2).
2. The harness ships session or thread launching (Codex threads, Claude Code agent teams, a desktop app's session tool or bundled skill) → use it: one managed session per item, carrying the same brief `open-terminal` would render.
3. Neither → no parallel surface. Say so once and work the queue sequentially in this session: `start [ISSUE_ID]` per item, § 2 selection between items.

On a non-tmux surface, read lane questions, new tracker items, and session banners through the harness's own session and tracker tooling.

## 2. Select Work

Unblocked, non-terminal items from the tracker, gated exactly as `start.md` gates them (ancestor chain, blocker union, container rules). A GitHub item labeled `blocked` is not a candidate. An item whose `worktree create` exits 75 belongs to another session: skip it; its siblings still launch. On the tmux surface that claim IS `open-terminal`'s own worktree create — never pre-create the worktree. A surface that creates its own worktree environment (Codex app threads) records the claim in workflow-state before launch. Oversee runs as at most one session per repo. Read the lane cap and keep at most that many items in flight:

```bash
.agents/skills/orch/scripts/orch-env ORCH_OVERSEER_LANES 3
```

## 3. Launch

Per item, mint the brief `/orch start [ISSUE_ID]` (or `/orch start github [OWNER/REPO]#[N]`). The brief also carries question routing: "If your harness can message other sessions (a session list plus a send-message tool), push any blocking question to the overseer session that launched you the moment it arises — the user may not be watching this session — and still raise it locally through your normal question tool. Without such messaging, just ask normally; the overseer's watch will find it." `/orch` slash syntax does nothing in Codex: a Codex CLI lane uses the form open-terminal renders — `Read .agents/skills/orch/SKILL.md and execute the orch start workflow for [ITEM]` — and a Codex Desktop thread uses `$orch start [ITEM]` (`handoff.md` § 2). Size launch flags to the item, read `[NOW]` for the lane record below, then launch on the § 1 surface.

Record the lane. Read `[NOW]` as `date -u +%Y-%m-%dT%H:%M:%SZ` before the launch it timestamps, never after; the first lane's value is the fleet start that § 4 passes as `--since`. First use only — when `exists` reports false, run `init` (init overwrites: never re-init a live lane log):

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

One blocking command, passed the fleet's start as `--since` (the first lane's `launched_at` — the same value on every run, never "now"), `--item` for every live item, `--repo` for every repository the fleet has PRs in, and every live lane's tmux window name (none on a non-tmux surface). It exits on the first event that needs the overseer and prints one event: an `EVENT` line, or one line per item for `merged` and `triage` — handle every line. An `EVENT` line on stdout is handled even when the watch exits non-zero: handle it, fix what stderr names, then re-run. Re-run it after handling each event with the live set updated — a merged item and a dead lane's window drop out. Never hand-roll a monitor. It runs `pr-watch.sh` when the review-gate skill is installed and skips that step otherwise (`gate-stale` is then invisible — [references/gates.md](../references/gates.md) § Multi-PR watching); the `triage` check arms only when `LINEAR_TEAM` is set, so a fleet on a repo tracking its work elsewhere runs the same command and is told once on stderr that triage is off; the reducer covers every `--repo`, each keeping its own baseline, and prefixes every line with the repo it came from; only a new `<pr> <kind>` line is itself an event; attention standing since the fleet's first run is context appended to the next event. A PR in a repo no `--repo` names is unwatched, so a fleet shepherding work into consumer repos names each of them, the repo holding the items FIRST: `merged` and the heartbeat's open-PR list read that one, and past one repo the watch says so on stderr at start.

```bash
.agents/skills/orch/scripts/oversee-watch --interval 240 --since [FLEET_SINCE] --item [ISSUE_ID]... --repo [ITEMS_REPO] --repo [OTHER_REPO]... [LANE_WINDOW...]
```

### Judgement at every event

The overseer owns fleet judgement, not just liveness; every § 4 event is
handled under these rules:

- **Heartbeat backstop for lane filings.** Read every issue a lane creates — the
  `heartbeat` triage pass below surfaces them. A hypothetical,
  an unreproduced edge case, or a feature no issue's Done-when carries is
  canceled with a comment naming what it failed; genuine defects stay.
  Cancel only where the fleet brief grants triage authority and the lane's
  authorship is beyond doubt; any uncertainty means comment the
  recommendation and leave the issue open — elsewhere the
  project-management skill's approval gate stays the rule.
- **Cut scope blowups.** A PR whose diff outgrows its issue's Done-when goes
  back to the contract: keep the oversized work on a branch, land the
  contract. Machinery no issue ordered — a new subsystem, scanner, or lexer —
  is cut, never reviewed into shape.
- **End spirals.** A round whose finding shares a root cause with one a
  prior round patched is dispositioned by
  [references/finding-disposition.md § Recurrence](../references/finding-disposition.md#recurrence),
  which states the branches and their limits. Bots drip-feeding one class
  get the class exhausted in one audit pass, then dispositions without
  pushes. The overseer never orders a blanket `Declined` across a PR's open
  findings: each one is dispositioned on its own mechanism, and a decline
  that is nothing but a label turns the gate red.
- **Fix the source.** The same finding class on a third PR is a mechanism
  gap: file it and route the smallest deterministic check (a guard lane, a
  preflight rule, a refusing script) or one sentence in the owning skill
  through a lane as its own item — the overseer still implements nothing.
  Deterministic beats prose where it stays simple; complex or brittle
  machinery is worse than either.
- **Compact a lane before it runs out.** On the § 1 tmux surface, at every
  § 4 event, read each live lane's context use:

  ```bash
  .agents/skills/orch/scripts/lanes context
  ```

  A lane past ~50 `CONTEXT_USED_PCT` is compacted at its next safe point — an
  idle prompt, or the gap between review rounds, never mid-round — with a
  focus note naming its item, its open PRs and their thread state, what
  remains in its queue, and the standing rulings it works under.

  Surfaces 2 and 3 register no lane claim, so `lanes context` reports an empty
  fleet and this rule does not run there; they compact on their own harness's
  prompt, and the focus note is still the overseer's to hand over.
- **Decide without the user.** SKILL.md's ask gates stand unchanged — scope
  expansion, recorded decisions, and merge autonomy still ask. Any other
  reversible call takes the option that costs nothing, recorded in the fleet
  log; destructive actions and product direction wait for a human.


- `merged` → the PR is in; the owning lane finishes `merge-pr.md` § 5 on its own and a GitHub merge alone is not lane completion. Wake it only if it is not still inside that run, and read a reported failure there rather than advancing the item. Then run the repo's post-merge routine in the overseer main checkout: pull the merged base, build, refresh, verify, and run its lifecycle check. When the fleet's LAST item completes, run the `heartbeat` triage pass before closing out, whatever the tracker; items living in Linear also get `.agents/skills/orch/scripts/reconcile-work-items` (a GitHub-item fleet skips that with a note). Report both with the close-out.
- `lane-exited` → the window is alive but the harness under it is gone (its pane tail says why). A lane stopped by a harness session limit ("You've hit your session limit · resets HH:MM") is not dead: resume it under another auth lane (`lanes pick`; a Claude session resumed under a different `CLAUDE_CONFIG_DIR` needs its session files copied there), or wait for the shown reset and send the lane a one-line continuation nudge. Any other exit is the `window-gone` rule below.
- `usage-limit` → read the pane tail first and confirm the banner is the harness's own, not text the lane printed while working; a lane still working is left alone. Confirmed: move the item to another account lane (kill the window, then re-run the § 3 launch with `--relaunch --lane auto:[HARNESS]` — bare `auto` needs `--harness`), or wait for the reset the banner names and send the lane a one-line continuation nudge. Never launch onto the spent account again until its reset.
- `idle-after-return` → read its pane tail. A lane that has returned is available for another fleet launch; a lane still inside `merge-pr.md` § 5 step 1 is blocked on its queue wait, which reads as work in flight rather than idle.
- A lane whose session ended AFTER its PR merged but before `merge-pr.md` § 5 steps 2-6 finished → relaunch it into `merge-pr [PR_NUMBER]`. That run's already-merged route skips the merge and runs the tracker sync, project verification and worktree removal the dead lane never reached. The rule below does not reach this lane: its PR did merge.
- `window-gone`, or any lane whose session ended with no merged PR → inspect its worktree and PR state, re-launch once with the same brief and `open-terminal --relaunch` (without the flag the existing worktree reads as another session's claim and the item is skipped); a second death is surfaced to the user, not retried.
- `lane-asking` → read the pane, answer when available evidence already decides it, apply the ruling, and record it in the fleet log. Repo state, the issue body, a stated convention, scope-narrowing calls, and a lane's own well-argued recommendation are available evidence. Relay to the user only what changes the product for a user or spends the owner's standing (retiring a reviewer, filing outside the repo, closing as won't-do). Either way, send the answer back to the lane. On a surface with neither messaging nor an inspectable pane, prolonged lane silence is itself the needs-attention signal — inspect the session through that surface's own status tools.
- `triage` → team-wide: apply the filing bar to every emitted team item, regardless of lane authorship. Route a kept item or cancel it, then record a kept or canceled verdict in the fleet state's `triaged` list before re-running the watch. An emitted item is never left without that record.
  triaged is the verdict log, not the watcher baseline. The watcher rebuilds acknowledged triage keys from it in the first repository's OVERSEE_WATCH_STATE_DIR baseline; the default directory is `<project-root>/tmp/oversee-watch`. Deleting that baseline resets watcher dedup: the next pass rebuilds kept and canceled keys, while pending items emit again.
- `pr-watch` → handle every attention line. What each kind MEANS is `pr-watch.sh --help`; what follows is only what the overseer does about it. A detail ending in `(QUEUED: dequeue before pushing)` rides several kinds and outranks all of them: the lane dequeues before it can push anything.
  - `gate-stale` → healed only where a `heal-dispatched` line rides the same reduction. The reducer re-dispatches on every pass the line stands, so a standing line is dispatch-to-converge lag, not a queue of work: judge it on whether the dispatched writer run COMPLETED, never on a pass count, and read a cancelled pending duplicate in the writer's concurrency group as ordinary lag too. A standing line comes back only as reducer output appended to the next wake or heartbeat, never as a fresh event. Beside an `error` naming a failed writer dispatch, nothing was healed and the once-per-invocation budget is spent, so no other stale PR got a dispatch either: fix the dispatch path for the repo the line names before waiting on another pass, the workflow name against `PR_WATCH_WRITER_WORKFLOW`, `actions:write` on the credential, Actions enabled on that repo.
  - `heal-dispatched` → the reducer's note that this invocation's one dispatch fired. Nothing to do, and never an event on its own.
  - `threads-open` → verify the count against the API, then wake the owning lane with it.
  - `changes-requested` → wake the owning lane: a standing objection is the lane's to answer, never the overseer's to dismiss.
  - `untracked-claim`, `unreasoned-decline` → wake the lane to rewrite the reply per [references/finding-disposition.md](../references/finding-disposition.md); the gate stays red until it does.
  - `disarmed` → wake the lane to arm auto-merge. Arming stays the lane's reply-pass discipline; the overseer never adopts it as its own step. A detail marked `UNCONFIRMED` came from a cheap-mode reducer, and that one is evaluated before anyone arms.
  - `awaiting-stale` → trigger a re-review, or apply the fleet's on-timeout policy.
  - `head-moved` → the reduction describes the old head. Re-run the watch; nothing else.
  - `error` → many producers, and each line's own detail carries its remedy: follow that. One exception, whose remedy the detail does not carry: `writer dispatch failed for …` means fixing the dispatch path, never re-running, since a re-run re-attempts the same failing dispatch. An unevaluated PR is never healthy.
- `heartbeat` → the triage pass: `.agents/skills/linear/scripts/linear.sh issues list --team [TEAM] --created-since [Nd covering the fleet start] --max` (or the tracker's equivalent), drop IDs already recorded in the fleet state's `triaged`, and judge only issues a fleet lane filed — the candidate set is each lane item's created-issue records in workflow state (`audit_issues_created`, `pr_comment_review.issues_created`) plus each lane PR body's Created Issues section; the created-since listing backstops trackers without that state. Anything outside the set is left alone. Record each verdict with `workflow-state append oversee triaged '{"issue": "[ID]", "verdict": "[kept|canceled]", "reason": "[ONE_LINE]"}'`, then re-run.

## 5. Stop

Queue empty, or the user stops it. Report one line per lane: merged SHAs, still-open PRs, items skipped as owned or blocked.
