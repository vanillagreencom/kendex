# Control-host events

Read when starting, recovering or extending the event producer in the [session workflow](../workflows/session.md#control-host-events).

## Input log

`watch-loop` appends changed local and host passes to `events.log` under `JARVIS_LOG_DIR`. Unchanged cursor-only results add no log entry. Its `batch.json` retains logical read progress, deferred block spans, an immutable current send and a cursor checkpoint. Restart recovers later cursors from the log after that checkpoint. Keep both files across restart. Each simultaneous Jarvis home needs a separate log directory.

An `EVENT` line opens a block. The next `EVENT` line or `cursor:` line closes it. LF is the physical line separator. An unfinished final block waits for its closing boundary. Consumer checks append complete blocks under an exclusive advisory lock on the event log inode. Write each append in full before releasing that lock. End the append with `cursor: {"side":"consumer","roots":{}}` when no next event closes its last block. Consumer checks send no mailbox batch and change no batch state.

```text
EVENT mail repo=NAME file=to-lane
ID KIND re RE
TEXT
EVENT mail repo=NAME file=to-overseer
ID KIND to=owner ref= options= recommend= deadline=
TEXT
cursor: {"side":"consumer","roots":{}}
```

Mail text keeps ordinary quotes, backslashes, Unicode and LF line breaks. Other control characters use visible escapes. A space protects text lines that begin with `EVENT ` or `cursor:`. The final text holds at most 4000 characters, including complete escapes and protective spaces. Metadata and diagnostic values encode whitespace and control characters to remain single tokens on one physical line. Consumer checks use the same rule for their text. Other supported headers are `EVENT overseer-unread`, `EVENT owner-unread`, `EVENT owner-unanswered`, `EVENT owner-unanswered-failed`, `EVENT root-unreachable`, `EVENT presence-renew-failed` and `EVENT timeout`. `EVENT owner-unread id=ID at=AT` has no text line. `EVENT owner-unanswered id=ID at=AT kind=KIND` carries the message text. Timeout blocks are skipped. The pass cursor is a public protocol record. Its byte length and relative block spans retain the full root path and transport side for root-specific mail and presence blocks. Whole-side failures and consumer blocks have no root origin. Consumers do not edit that bookkeeping or its root positions.

## Delivery

The first complete pending block starts one fixed settle. Later events do not move the deadline. At the deadline, local home-root blocks come first. Full path and transport side identify the home. Display names do not identify roots. Each priority group keeps log order. The serialized batch holds at most 60 KB and never cuts a block. Deferred blocks stay pending. A single consumer block larger than the cap reports `event-too-large`; split that check's output into complete smaller blocks.

The home mailbox writer receives one directive with a retained delivery key. A restart retries the saved bytes with that key. Only a normal send receipt or the exact key's repeated-delivery receipt commits progress. The mailbox remains the delivery ledger. The loop prints one batch pointer without its body. Read the body through the installed deliver hook or `lane-mail inbox --item overseer` from the home.

`vm-watch.sh` discovers registered projects separately on each machine through `kendex project list`. It skips noted rows. It runs the producer's mailbox command against each root's mailbox data and logical count. The canonical `events --mark-read` command records owner-message consumption for the relay. Unreachable roots report each stable operation, category and machine code once while other roots continue. The first report keeps its diagnostic text. Changing traceback paths do not create another report. A successful read clears that root's failure. A missing host executable reports `kendex-missing` with `fix=install-kendex-on-host-PATH`.

## Presence

The loop schedules presence every 120 seconds independently of mail acquisition. Before discovery, settings and host transport, it requires current native permission. Before each hold touch and after a failed blocking operation, it checks that the recorded server, start, pane and native session match a live session and its matching hook context is younger than 300 seconds. The host requests current permission before work and after it resolves each hold path and obtains its timestamp. A session that ends during a settings or transport wait permits neither a touch nor a new renewal-failure report. Tool calls and turn ends update context through the existing hooks. A stopped or unbound session renews nothing. An unavailable native probe denies renewal and leaves mail delivery active. Unknown native delivery health supplies no extra renewal permission.

The producer's declared Slack package resolves each target root's `SLACK_JARVIS_SESSION_FILE` through its unchanged presence-settings owner. Target roots need no Slack installation. Host transport carries the same dependency code bytes and uses the host caller's environment. That owner preserves supported old-name fallback and new-name precedence. An empty path creates no hold. The path can be absolute, begin with `~/`, or be relative to that root. Its parent directory must exist. Local and host renewals use the machine that owns the root. A failed renewal reports once until a successful renewal clears that failure. Ordinary mail polls neither clear nor replace renewal failures.
