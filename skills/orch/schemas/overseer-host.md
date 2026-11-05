# Overseer host

The `scripts/overseer-host` command selects the runtime the overseer's own session runs in from `ORCH_OVERSEER_HOST`, and speaks the protocol below to it. Read this file when opening, reading or stopping an overseer session, or when reading the fleet record's `overseer` object.

`resolve` prints `tmux` for an empty or `tmux` setting, selecting `scripts/overseer-host-tmux`; another value names an executable provider. Registration and the plain succession command refuse another runtime as `runtime-unsupported`. Runtime controller launches use the fleet's tmux session directly.

`oversee register` uses `resolve` and `inspect` for the live-holder check. `oversee-succeed` uses inspection to read its caller. The runtime's `start-controller` and `request-transfer` open, retire and publish controllers through their own effects in the fleet's tmux session. [Controller start and adoption](../workflows/oversee.md#controller-start-and-adoption) names their request and outcome route. The host protocol does not choose accounts or own succession.

## Provider protocol

A `SESSION` is the runtime's own identifier of one session: on tmux a pane id, `%N`.

| Verb | Arguments | Result |
|---|---|---|
| `create` | `--cwd DIR (--after SESSION \| --session NAME) [--name NAME] --line COMMAND` | Open a session running `COMMAND` from `DIR`, at the base index of the session `--after` names or of the runtime session `--session` names, and print one line, `session=SESSION window=WINDOW server=SERVER`, before the harness has drawn anything. A create that opened a session and could not start the command in it closes that session again and fails. HUP, INT and TERM do not interrupt a create between opening the session and printing its line, so a caller's close-out can read the session off it. |
| `inspect` | `--session SESSION [--launch] [--server PID --server-start EPOCH [--server-socket PATH]]` | Print one keyed line, `session= window= server= state=STATE`, then the session's snapshot. Without `--launch`, `STATE` is `lib/lane-state.sh`'s word for the session, which that shared judge defines, with `wall_kind=auth` or `wall_kind=usage` on a walled reading and no wall kind on any other state. `cause=` names each scan the judge could not run, comma-separated, and `probe=` the child probe's exit status where one is `process-probe`. `--launch` is the first-turn reading of a session opened seconds ago: `working` where a turn is in flight anywhere on the screen, `asking` where the folder-trust dialog holds the harness, `idle` otherwise; under `asking` the snapshot is the line that holds it. With a recorded socket, tmux verifies the recorded server pid and start before reading the pane and includes `server_start=` in its answer. A stopped recorded server, including a missing or refused recorded socket, or a different start is `state=gone`. A saved server identity without a socket still binds the read to that server; if it runs but cannot be judged from the caller socket, inspection refuses `session-unreadable`. A failed process or pane-list read also refuses and includes its cause. A session the runtime no longer lists is `state=gone` with no snapshot, at exit 0, `window` and `server` then `none`; a session that stops being listed during the read answers the same. |
| `deliver` | `--session SESSION`, the block on stdin | Put the block where the session's harness reads it and print `deliver=ROUTE session=SESSION`. The block is consumed whole whatever the outcome. A session the runtime no longer lists refuses at exit `4` under `session-gone`. |
| `stop` | `--session SESSION [--successor SESSION]` | End the harness, close the session and print `stopped session=SESSION window=WINDOW`. With `--successor`, the successor keeps its base index and becomes the selected window. Without it, undo an uncommitted insertion and restore the displaced windows. A session the runtime no longer lists prints `window=none` at exit 0. |

- A refusal is one keyed line on stderr, `<provider>: <key> <field>=<value>`, with the runtime's own words under it, at exit 1. A usage error exits 2.
- The dispatcher passes all provider bytes and exit codes unchanged. It refuses a verb outside the four as `verb-invalid` at exit 2 and a provider path that is not executable as `host-unavailable` at exit 2.
- A caller decides on `state=` and relays the snapshot under its own refusal as detail.

### Recorded harness observation

The tmux provider adds `harness_state=running|stopped|unknown` beside `state=`. Fleet readers use this fact for the recorded harness process. The pane's `state=` keeps its existing meaning.

- `running`: the saved PID is alive with the saved process start. A saved exit from an earlier run cannot override this identity.
- `stopped`: the saved identity has ended and the pane observation is `exited`, which requires shells only. A missing process, zombie or different process start ends the saved identity. A bound `exit.run` supplies the completed identity after active fields clear.
- `unknown`: no bound identity exists, a read fails, or an ended identity's pane does not read `exited`. A program started by a person after the harness exits therefore reads unknown. Pane presence never proves a running harness.

`harness_cause=` names the reason for `unknown`: `record-unreadable`, `server-start-unreadable`, `record-unbound`, `identity-unrecorded`, `identity-invalid`, `state-read-failed`, `start-read-failed`, `process-probe-failed`, `pane-not-exited` or `pane-gone`. A provider that records no process identity answers unknown.

## The tmux provider

`overseer-host-tmux --help` owns its options. Without `inspect --server-socket`, it reaches the tmux server the caller's tmux calls reach: the one `$TMUX` names, or the person's own at the socket tmux derives from their uid when `$TMUX` is unset (`scripts/lib/tmux-server.sh`).

| Verb | tmux calls |
|---|---|
| `create` | `new-window -d -b` before the session's configured base index, for a predecessor's session or a named session, `-n NAME -c DIR`; then `COMMAND` and `Enter` through `lib/pane-write.sh`'s `pane_write`, which types only into a pane at its shell. The new window's `@orch_overseer_displaced` option holds the displaced window ids in index order. Failed pane-write cleanup restores them before closing the new window. `server=` is the tmux server pid, the first half of the `<server pid> <pane id>` key every reader of the session record compares. |
| `inspect` | `capture-pane -pJ` is the snapshot. The settled reading feeds it, the pane's pid and its foreground command to `lane_state`; `--launch` reads it whole through `pane_working` and `pane_trust_dialog`. |
| `deliver` | Nothing forwards the block: the harness in the pane reads the watch log inside its own turn. The verb proves the pane is live. `ROUTE` is `watch-log`. |
| `stop` | Without a successor, swap the inserted window through its recorded displaced windows, then `kill-window` in one client call. This restores their indexes and preserves gaps when renumbering is off. With a successor, `kill-window`, clear the successor's displacement option, and `select-window` in one client call. The successor keeps the base index create gave it. |

## The session record

A confirmed runtime start or transfer publishes the oversee state's `overseer` object from its typed pending controller and observed identity. [workflow-state.md § Oversee state](workflow-state.md#oversee-state) owns the record contract. `oversee register` records a hand-opened session.

`watch` is the fleet watch a confirmed `start-controller` launched or found claimed, written by that launch's confirmation: `{runner, unit}` for a watch the job launcher started as a user unit, `{runner, pid, start}` for one it started as a process group, the group leader's pid and start, or `runner: claimed` with the claim's own identity where the start found the watch already claimed. The claim beside the fleet state, `oversee-watch.pid`, stays the watch's liveness record, which `orch-runtime watch status` reads; `watch` names what started it. A succession keeps the field as it stands. The request field that carries the watch's launch line is `StartController.watch` in [`runtime/src/ops/controller.rs`](../runtime/src/ops/controller.rs).

`request-transfer` records its successor in `pending` before opening it. The effect publishes only after confirming the successor; a failed launch before retirement restores the predecessor's pending state. `oversee register` records a hand-opened session and keeps its generation when the record proves the same server, server start and pane. A runtime adoption uses `adopt-controller`; a native resume uses `start-controller` with the controller's `resume` field. The watch reads the published controller and keeps running across succession.
