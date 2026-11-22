# Control-host events

Read when starting, recovering or extending the event producer in the [session workflow](../workflows/session.md#control-host-events).

The [producer](../scripts/lib/watch.py) declares the event encoding, every header and its fields, the pass cursor and the batch state.

## Input log

`watch-loop` appends each changed local and declared-host pass to `events.log` under `JARVIS_LOG_DIR`, and keeps its progress in `batch.json` beside it.

- Keep both files across restarts.
- Give each Jarvis home that runs at the same time its own log directory.

An `EVENT` line opens a block, and the next `EVENT` or `cursor:` line closes it. A consumer check appends complete blocks under an exclusive advisory lock on the event log's inode:

1. Open the log for append, or seek to its current end after taking the lock. Never write at a position cached before the lock.
2. Write each append in full before releasing the lock.
3. When no next event closes the last block, end the append with `cursor: {"side":"consumer","roots":{}}`.
4. Encode the text as the producer encodes mail text.

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

- Never edit the pass cursor's bookkeeping or its root positions.
- Never truncate, replace or logrotate `events.log`: an outside rotation cannot reconcile its positions with `batch.json`.

## Delivery

The loop reads its own home's relay through the sibling Slack command `listen --status --root HOME`.

- It emits `EVENT relay-down` on an unhealthy reading and `EVENT relay-up` when a later reading is `ok`.
- A failed or unreadable status emits `EVENT relay-unavailable`, which never shows recovery.
- Another machine's relay is outside this check.
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

A host change takes effect after a stop and restart.

A single consumer block over the batch's 60 KiB cap reports `event-too-large`; split that check's output into complete smaller blocks.

The loop prints one batch pointer without its body; the [session workflow](../workflows/session.md#control-host-events) reads the body.

`vm-watch.sh` discovers registered projects on each machine through `kendex project list`.

- The host lists a hosted repository only after [Agent reach: Control host setup](agent-reach.md#control-host-setup).
- On `JARVIS_CONTROL_HOST` with `JARVIS_CONTROL_USER` set, its mail and presence passes run as that account, as that section states.
- It skips noted rows.
- The canonical `events --mark-read` command records owner-message consumption for the relay.
- An unreachable root reports its failure once, and the other roots continue.
- A missing host executable reports `kendex-missing` with `fix=install-kendex-on-host-PATH`.

## Restart and destination identity

- After an interruption or a storage failure, keep both owner files and restart with this producer. Never edit their recovery data.
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
   - Stop the earlier reader through its process owner, and confirm it stopped.
   - Do not edit its private offsets or leave it sending alongside.
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
   - Resolve a failed root read and capture the pass again; a failed root is not an empty successful root.
5. From the Jarvis home, run the native `lane-mail inbox --item overseer` for the final home inbox handoff.
   - A local home pass records positions but prints no ordinary home to-lane mail as `EVENT mail`, so the pass alone does not prove the session received those rows.
   - Use the native reader for this drain, not the earlier private reader.
6. Initialize once with those unchanged pass files.
   - On a refusal, keep the files and fix the prerequisite it names.
   - Never edit a footer, delete state or force a reset.
   - After success, start the packaged loop through the session workflow's Monitor or `launch-job` route.
   - Keep its state and log for every restart.
   - Record the consumer's adoption and the private reader's retirement on the consumer's tracker.

Unsupplied destinations and newly discovered roots start from the beginning, and can replay kept history. On a satellite, initialization admits only `local`.

- The operator binds each unsigned pass to its actual destination, stable alias and home; the footer authenticates none of them.
- Skipping reconciliation or the final home inbox drain can lose a wake and is unsupported.
- Capturing a public pass marks owner messages consumed for the relay, through `events --mark-read`; that mark proves no human handling and deletes no envelope.
- Kept mail stays readable through `lane-mail events --item overseer --box BOX --after 0` without `--mark-read`, under the mailbox's ordinary retention.

## Satellite

A satellite is a home whose `JARVIS_MAIN_HOST` is set.

- Its loop reads only its own home's mailbox, as a registered home.
- It runs no host pass, renews no presence and polls no `report-due`.
- For forwarding, follow [Agent reach: Status](agent-reach.md#status).

## Presence

The loop renews a live, bound session's presence hold apart from mail acquisition.

- A stopped or unbound session renews nothing.
- An unavailable native probe denies renewal and leaves mail delivery active.

The producer's declared Slack package resolves each target root's `SLACK_JARVIS_SESSION_FILE`; a target root needs no Slack installation.

- An empty path creates no hold.
- The path can be absolute, start with `~/`, or be relative to that root, and its parent directory must exist.
- A failed renewal reports once, until a successful renewal clears it.
