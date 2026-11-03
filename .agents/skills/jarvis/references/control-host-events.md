# Control-host events

Read when starting, recovering or extending the event producer in the [session workflow](../workflows/session.md#control-host-events).

The [producer](../scripts/lib/watch.py) declares the event encoding, pass cursor and batch state.

## Input log

`watch-loop` appends changed local and declared-host passes to `events.log` under `JARVIS_LOG_DIR`. Unchanged cursor-only results add no log entry. Its `batch.json` retains logical read progress, deferred block spans, an immutable current send and a cursor checkpoint. Restart recovers later cursors from the log after that checkpoint. Keep both files across restart. Each simultaneous Jarvis home needs a separate log directory.

An `EVENT` line opens a block. The next `EVENT` line or `cursor:` line closes it. LF is the physical line separator. An unfinished final block waits for its closing boundary. Consumer checks append complete blocks under an exclusive advisory lock on the event log inode. Write each append in full before releasing that lock. End the append with `cursor: {"side":"consumer","roots":{}}` when no next event closes its last block. Consumer checks send no mailbox batch and change no batch state.

```text
EVENT mail repo=NAME file=to-lane destination=KEY root=FULL_PATH
ID KIND re RE
TEXT
EVENT mail repo=NAME file=to-overseer destination=KEY root=FULL_PATH
ID KIND to=owner ref= options= recommend= deadline=
TEXT
cursor: {"side":"consumer","roots":{}}
```

Every new root-specific block, including unread, unreachable and presence blocks, adds `destination=KEY root=FULL_PATH` to its header. Keys are `local` or `ssh:ALIAS`, never a display basename. The cursor and footer origin retain the acquisition root and transport side. An `owner-unread` header names the shared mailbox root; its cursor and footer origin identify the registered Jarvis home. These paths can differ for a linked worktree. Header fields survive batching into the actual home mailbox directive. Existing consumer blocks and saved pending bytes are unchanged.

Mail text keeps ordinary quotes, backslashes, Unicode and LF line breaks. Other control characters use visible escapes. A space protects text lines that begin with `EVENT ` or `cursor:`. The final text holds at most 4000 characters, including complete escapes and protective spaces. Metadata and diagnostic values encode whitespace and control characters to remain single tokens on one physical line. Consumer checks use the same rule for their text. Other supported headers are `EVENT forward-failed`, `EVENT overseer-unread`, `EVENT owner-unread`, `EVENT owner-unanswered`, `EVENT owner-unanswered-failed`, `EVENT root-unreachable`, `EVENT presence-renew-failed` and `EVENT timeout`. `EVENT owner-unread id=ID at=AT` has no text line. `EVENT owner-unanswered id=ID at=AT kind=KIND` carries the message text. `EVENT forward-failed request=REF key=KEY cause=CAUSE` has no text line and may add `detail=`; `KEY` is the forward's delivery key, so a reused request reference's later forward is another event. Timeout blocks are skipped. The pass cursor is a public protocol record. Its byte length and relative block spans retain the full root path and transport side for root-specific mail and presence blocks. Whole-side failures and consumer blocks have no root origin. Consumers do not edit that bookkeeping or its root positions.

## Delivery

The loop reads the producer's own home relay through the sibling Slack command `listen --status --root HOME` every 30 seconds, independently of mailbox acquisition and pending delivery. Another machine's relay is outside this check. Slack owns freshness and reconnect classification. A public unhealthy reading emits `EVENT relay-down` once until an `ok` reading emits `EVENT relay-up`. An initial `ok` reading emits nothing. Unbound homes retain Slack's explicit `failing` or `never` reading. A failed or unreadable status emits `EVENT relay-unavailable` once per stable failure and preserves the last readable state; it never establishes recovery. These events identify `home=HOME` and use the existing log, restart cursor and session mailbox. The independent mailbox signal can reach a running session while Slack is down; the unavailable relay cannot deliver a page.

The loop polls `jarvis-session report-due` every 30 seconds independently of mail acquisition. That command reuses orch's `oversee-report due` with the controller's session start as its floor. It appends each distinct `EVENT report-due reason=... since=...` once to the same event log and batches it through the mailbox. Restart recovers its emitted-event fingerprint through the existing pass cursor. Minute cadence, quiet hours, time zone and paths use orch's existing consumer settings. The Jarvis reader supplies no fleet state, so ORCH_REPORT_EVERY_ISSUES is ignored and performs no GitHub reads. A failed report send remains due until an owner notice receipt names the report attachment. No due time is stored in the producer or handoff.

Each destination has one independently scheduled mail job and presence job in the existing executor. A completed healthy pass is accepted without waiting for another host. A failed pass retains only its destination's progress and cause. Declaration reordering cannot move read positions. Host changes take effect after the existing stop/restart route.

The first complete pending block starts one fixed settle. Later events do not move the deadline. At the deadline, blocks acquired from the local home come first. The acquisition root's full path and transport side identify the home, not the header's mailbox path. Display names do not identify roots. Each priority group keeps log order. The batch's event body holds at most 60 KiB and never cuts a block. Deferred blocks stay pending. A single consumer block larger than the cap reports `event-too-large`; split that check's output into complete smaller blocks.

The home mailbox writer receives one directive with a retained delivery key. A restart retries the saved bytes with that key. Only a normal send receipt or the exact key's repeated-delivery receipt commits progress. The mailbox remains the delivery ledger. The loop prints one batch pointer without its body. Read the body through the installed deliver hook or `lane-mail inbox --item overseer` from the home.

`vm-watch.sh` discovers registered projects separately on each machine through `kendex project list`; the host lists a hosted repository only after [Agent reach: Control host setup](agent-reach.md#control-host-setup). It skips noted rows. It runs the producer's mailbox command against each root's mailbox data and logical count. The canonical `events --mark-read` command records owner-message consumption for the relay. Unreachable roots report each stable operation, category and machine code once while other roots continue. The first report keeps its diagnostic text. Changing traceback paths do not create another report. A successful read clears that root's failure. A missing host executable reports `kendex-missing` with `fix=install-kendex-on-host-PATH`.

## Restart and destination identity

Keep `JARVIS_CONTROL_HOST` at its original alias through the first upgrade. The producer freezes that value as `legacy_control_host` before recovering old `host` cursor records and log tails into `ssh:ALIAS`. It retains generation, offsets, deferred positions, immutable pending bytes and delivery key. Without a configured control alias, old host state stays dormant; additional aliases do not inherit it. Restore the original control alias before binding that dormant state. The old record contains no evidence of an alias changed before this first binding.

After binding, changing an alias creates another destination and never borrows the former alias's cursor. Removing a destination stops its work after restart and retains its progress for re-adding the same alias. A consumer keeps one stable SSH alias per physical destination and does not retarget that alias to another mailbox as a restart. The package proves no physical-machine identity behind SSH configuration.

## Satellite

A satellite, a home whose `JARVIS_MAIN_HOST` is set, reads only its own home's mailbox, as a registered home. It runs no host pass, renews no presence and polls no `report-due`. Every 60 seconds it runs `jarvis-session forward-drain` instead. The drain prints `EVENT forward-failed` for a forward whose cause is `mailbox-missing`, `send-failed`, `setting-invalid` or `receipts-missed`, and for one closed as `answer-unseen`. The loop appends each block once: the pass cursor keeps the headers already appended, so a restart appends none twice. A failed drain reports once as `EVENT root-unreachable` for the home.

## Presence

The loop schedules presence every 120 seconds independently of mail acquisition. Before discovery, settings and host transport, it requires current native permission. Before each hold touch and after a failed blocking operation, it checks that the recorded server, start, pane and native session match a live session and its matching hook context is younger than 300 seconds. The host requests current permission before work and after it resolves each hold path and obtains its timestamp. A session that ends during a settings or transport wait permits neither a touch nor a new renewal-failure report. Tool calls and turn ends update context through the existing hooks. A stopped or unbound session renews nothing. An unavailable native probe denies renewal and leaves mail delivery active. Unknown native delivery health supplies no extra renewal permission.

The producer's declared Slack package resolves each target root's `SLACK_JARVIS_SESSION_FILE` through its unchanged presence-settings owner. Target roots need no Slack installation. Host transport carries the same dependency code bytes and uses the host caller's environment. That owner preserves supported old-name fallback and new-name precedence. An empty path creates no hold. The path can be absolute, begin with `~/`, or be relative to that root. Its parent directory must exist. Local and host renewals use the machine that owns the root. A failed renewal reports once until a successful renewal clears that failure. Ordinary mail polls neither clear nor replace renewal failures.
