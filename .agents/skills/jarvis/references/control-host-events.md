# Control-host events

Read when starting, recovering or extending the event producer in the [session workflow](../workflows/session.md#control-host-events).

The [producer](../scripts/lib/watch.py) declares the event encoding, every header and its fields, the pass cursor and the batch state.

## Input log

`watch-loop` appends each changed local and declared-host pass to `events.log` under `JARVIS_LOG_DIR`, and keeps its progress in `batch.json` beside it.

- Give each Jarvis home that runs at the same time its own log directory.

An `EVENT` line opens a block, and the next `EVENT` or `cursor:` line closes it. A consumer check appends complete blocks under an exclusive advisory lock on the event log's inode:

- Open the log for append, or seek to its current end after taking the lock. Never write at a position cached before the lock.
- Write each append in full before releasing the lock.
- When no next event closes the last block, end the append with `cursor: {"side":"consumer","roots":{}}`.
- Encode the text as the producer encodes mail text.

A consumer check sends no mailbox batch and changes no batch state.

```text
EVENT mail repo=NAME file=to-lane destination=KEY root=FULL_PATH
ID KIND re RE
TEXT
EVENT mail repo=NAME file=to-overseer destination=KEY root=FULL_PATH
ID KIND to=owner ref= options= recommend= deadline=
TEXT
cursor: {"side":"consumer","roots":{}}
```

- Leave pass cursor bookkeeping and root positions to the producer.
- Preserve the event log's positions and inode. Avoid truncating, replacing or rotating it outside the producer.

## Delivery

The loop reads its own home's relay through the sibling Slack command `listen --status --root HOME`.

- It emits `EVENT relay-down` on an unhealthy reading and `EVENT relay-up` when a later reading is `ok`.
- A failed or unreadable status emits `EVENT relay-unavailable`, which never shows recovery.
- The mailbox signal can reach a running session while Slack is down.

The loop polls `jarvis-session report-due`, which runs `orch-runtime report due` with the controller's session start as its floor, and appends each distinct `EVENT report-due` to the event log.

- Minute cadence, quiet hours, time zone and paths come from orch's [report settings](../../orch/references/settings.md#reports).
- The Jarvis reader supplies no fleet state, so `ORCH_REPORT_EVERY_ISSUES` has no effect.
- A failed report send stays due until an owner notice receipt names the report attachment.
- Neither the producer nor the handoff stores a due time.

The loop adds `EVENT owner-unread` for an owner message that stays unread in the home inbox; the Slack relay pages the owner from it.

The loop adds `EVENT owner-unanswered` for a delivered owner message that no reply, later reply in its thread, closed ask or progress record covers.

- With a positive `JARVIS_VOICE_REMIND_SECS`, it repeats that event for an open voice request each period until a final reply; a progress notice is not one.
- The loop judges coverage from the default handoff and its archive.
- The event reminds the session; it never means the message is unread.

Every 30 seconds the loop reads the home's own controller for a wall: `jarvis-env.sh wall HOME` names the bound controller and its rows file.

- The reading is agent-runtime's session verdict of the rows its hooks write for the controller's pane, `agent-runtime rows verdict --kind session`: an auth wall for a signed-out account, a usage wall for one out of room.
- The verdict reads usage walls on Claude Code and Pi, and auth walls on Claude Code alone. A controller on another harness never reads walled, and this check tells nobody about it.
- It reads a live, bound controller whatever its context stamp's age. A quiet session that is not walled starts nothing.
- On a wall of either kind it runs `jarvis-session succeed --home HOME --account-walled` once, so the successor leaves the walled account and opens with the home's stored Start brief.
- It then sends the owner one notice, `lane-mail notice --item overseer --to owner`, naming the walled session, the time the loop read the wall, the cause, the account and the succession's outcome.
  - The outcome is the account the successor runs on, the refusal and its detail, or, for a transfer still open, a replacement that is starting, with no account named; `jarvis-session status` shows the rest.
- A wall is one episode of one controller, its session in its pane.
- A wall already reported starts nothing and sends nothing again until its episode ends: the controller in control reads unwalled, or another controller is walled, such as a successor or a session resumed in another pane.
- When the loop ends with the predecessor before the succession answers, the next loop sends the owed notice once a controller is bound. The notice names the successor's account when another session is in control, and says the outcome was not read when the walled session is, in any pane.
- An unreadable verdict of the bound controller's rows, the runtime's refusal of that read included, reports `root-unreachable` once and starts nothing. So does a missing agent-runtime or mailbox package.
- A status read the runtime refuses, such as the wrapper's `setup-required` before its setup has run, reports `root-unreachable` once with the runtime's line and starts nothing. Presence reads that refusal as no live session and reports nothing.
- An unsent notice reports `root-unreachable` once and is retried each check. A retry the mailbox refuses as a repeat of the same text counts as sent: the owner holds it.

A host change takes effect after a stop and restart.

A single consumer block over the batch's 60 KiB cap reports `event-too-large`; split that check's output into complete smaller blocks.

The loop prints one batch pointer without its body; the [session workflow](../workflows/session.md#control-host-events) reads the body.

`vm-watch.sh` discovers registered projects on each machine through `kendex project list --json`.

- For hosted repository discovery and the account used on the control host, see [Control host setup](agent-reach.md#control-host-setup).
- It skips an entry whose `worktree` is set, and one whose `state` is neither `ok` nor `git-unclassified`.
- A root that lists but cannot be reached reports its failure once, and the other roots continue.
- A folder git cannot classify, `state` `git-unclassified`, such as a linked worktree whose main checkout was moved or deleted, is such a root.
  - The mail pass reports `root-unreachable` once for it, with `root=` the folder and `cause=` the state then kendex's Git error.
  - The presence pass reports `presence-renew-failed` once for it.
- A missing host executable reports `kendex-missing` with `fix=install-kendex-on-host-PATH`. No other listing failure does.

## Restart and destination identity

- Keep `events.log` and `batch.json` across restarts, including after an interruption or storage failure. Restart with this producer and leave recovery data untouched.
- Do not downgrade to an older producer after reclamation starts.
- Keep `JARVIS_CONTROL_HOST` at its original alias through the first upgrade: the producer binds old `host` state to that alias as `ssh:ALIAS`.
  - With no configured control alias, old host state stays dormant, and added aliases do not inherit it.
  - Restore the original control alias before binding that dormant state.
- After binding, a changed alias is another destination and never borrows the former alias's cursor.
- A removed destination stops after restart and keeps its progress for re-adding the same alias.
- Keep one stable SSH alias per physical destination. Never retarget it to another mailbox as a restart. The package proves no physical machine identity behind SSH configuration.

## Adoption from an earlier reader

Run `watch-loop --home HOME --initial-pass PASS_FILE` once to start fresh continuing state from a complete, reconciled public `vm-watch.sh` pass.

- Repeat `--initial-pass PASS_FILE` for each destination to adopt.
- The command saves state and exits before it acquires mail, sends a batch or schedules work.
- Then launch the ordinary `watch-loop --home HOME`.
- Keep initialization flags out of `ORCH_WAKE_START` and restart commands.

1. Keep the same absolute Jarvis home, log directory, destination declarations and stable SSH aliases through the switch.
   - Confirm that the log directory holds neither `batch.json` nor `events.log`, not even an empty one.
   - If either exists, restart in the ordinary way.
   - Never remove state to meet this precondition.
2. Finish the earlier reader's final drain.
   - Hand its results and outstanding delivery obligations to the continuing session.
   - Stop the earlier reader through its process owner.
   - Confirm it stopped.
   - Do not edit its private offsets.
   - Adoption imports no pending send or reminder ledger; finish those obligations, or keep their explicit consumer handoff.
3. Capture a successful, complete public pass for each destination to adopt.
   - Locally, run `.agents/skills/jarvis/scripts/vm-watch.sh --home HOME --side local > PASS_FILE`.
   - For a declared remote destination, run the same current package's public pass on that machine through the authorized machine access route, with `--side ssh:ALIAS` and its actual absolute home.
   - On the control host, run it as `JARVIS_CONTROL_USER` when that is set.
   - A remote loop's transported reader does not show that the matching package is installed there.
   - Without the matching public pass, stop adoption or keep ordinary from-beginning acquisition. This procedure installs nothing.
4. Reconcile every event in the captured outputs against the earlier reader's final results, by mail identity.
   - Hand every unhandled result to the session before adoption.
   - A pass begins with kept history, so its output can include mail already handled.
   - Resolve a failed root read; a failed root is not an empty successful root.
   - Then capture the pass again.
5. From the Jarvis home, run the native `lane-mail inbox --item overseer` for the final home inbox handoff.
   - A local home pass records positions but prints no ordinary home to-lane mail as `EVENT mail`, so the pass alone does not prove the session received those rows.
6. Initialize once with those unchanged pass files.
   - On a refusal, keep the files.
   - Fix the prerequisite the refusal names.
   - Never edit a footer.
   - Never force a reset.
   - After success, start the packaged loop under the [session workflow](../workflows/session.md#control-host-events).
   - Record the consumer's adoption and the private reader's retirement on the consumer's tracker.

Unsupplied destinations and newly discovered roots start from the beginning, and can replay kept history. On a satellite, initialization admits only `local`.

- The operator binds each unsigned pass to its actual destination, stable alias and home; the footer authenticates none of them.
- Capturing a public pass marks owner messages consumed for the relay, through `events --mark-read`; that mark proves no human handling and deletes no envelope.
- Kept mail stays readable through `lane-mail events --item overseer --box BOX --after 0` without `--mark-read`, under the mailbox's ordinary retention.

## Satellite

A satellite is a home whose `JARVIS_MAIN_HOST` is set.

- Install the standing watch loop under [README: Use from another computer](../README.md#use-from-another-computer). Preview the unit with `watch-loop install --home HOME --print`.
- Save the main-host binding before installing. The unit reads the saved binding at startup. It keeps the installer's exported `KENDEX_ENV_FILE`, `XDG_STATE_HOME` and `JARVIS_LOG_DIR` paths. Reinstall from the same environment you use for forwarding if those paths change.
- Read the service with `systemctl --user --property=ActiveState,SubState,Result show -- jarvis-watch.service` and its log with `journalctl --user -u jarvis-watch.service`.
- Its loop reads only its own home's mailbox, as a registered home.
- It runs no host pass, renews no presence and polls no `report-due`.
- For forwarding, follow [Agent reach: Status](agent-reach.md#status).

## Presence

The loop renews a live, bound session's presence hold apart from mail acquisition.

- An unavailable native probe denies renewal and leaves mail delivery active.

The producer's declared Slack package resolves each target root's `SLACK_JARVIS_SESSION_FILE`; a target root needs no Slack installation.

- An empty path creates no hold.
- The path can be absolute, start with `~/`, or be relative to that root, and its parent directory must exist.
- A failed renewal reports once, until a successful renewal clears it.
