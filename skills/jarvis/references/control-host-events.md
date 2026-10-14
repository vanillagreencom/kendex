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

Mail text is limited to 4000 characters. Control characters use JSON string escapes. A space protects quoted text lines that begin with `EVENT ` or `cursor:`. Metadata and diagnostic values stay on one physical line. Their spaces and non-ASCII characters use JSON escapes as well. Consumer checks use the same rule for their text. Other supported headers are `EVENT overseer-unread`, `EVENT root-unreachable`, `EVENT presence-renew-failed` and `EVENT timeout`. Timeout blocks are skipped. The pass cursor is a public protocol record. Consumers do not edit its root positions.

## Delivery

The first complete pending block starts one fixed settle. Later events do not move the deadline. At the deadline, home-root blocks come first. Each priority group keeps log order. The serialized batch holds at most 60 KB and never cuts a block. Deferred blocks stay pending. A single consumer block larger than the cap reports `event-too-large`; split that check's output into complete smaller blocks.

The home mailbox writer receives one directive with a retained delivery key. A restart retries the saved bytes with that key. Only a normal send receipt or the exact key's repeated-delivery receipt commits progress. The mailbox remains the delivery ledger. The loop prints one batch pointer without its body. Read the body through the installed deliver hook or `lane-mail inbox --item overseer` from the home.

`vm-watch.sh` discovers registered projects separately on each machine through `kendex project list`. It skips noted rows. It uses each root's mailbox command and logical count. The canonical `events --mark-read` command records owner-message consumption for the relay. Unreachable roots report their cause while other roots continue. A missing host executable reports `kendex-missing` with `fix=install-kendex-on-host-PATH`.

## Presence

The loop schedules presence every 120 seconds independently of mail acquisition. Before each hold touch, it checks that the recorded server, start, pane and native session match a live session and its matching hook context is younger than 300 seconds. The host requests that current permission after it resolves each hold path. Tool calls and turn ends update context through the existing hooks. A stopped or unbound session renews nothing. An unavailable native probe denies renewal and leaves mail delivery active. Unknown native delivery health supplies no extra renewal permission.

Each root resolves `SLACK_JARVIS_SESSION_FILE` through the Slack package's presence-settings owner. That owner preserves supported old-name fallback and new-name precedence. An empty path creates no hold. The path can be absolute, begin with `~/`, or be relative to that root. Its parent directory must exist. Local and host renewals use the machine that owns the root. A failed renewal reports once until a successful renewal clears that failure. Ordinary mail polls neither clear nor replace renewal failures.
