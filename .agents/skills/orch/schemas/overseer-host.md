# Overseer host

The `scripts/overseer-host` command selects the runtime the OVERSEER's own session runs in from `ORCH_OVERSEER_HOST`. `resolve` prints `tmux` when the setting is empty or `tmux`, which is the included provider `scripts/overseer-host-tmux`. Any other value is an executable script path speaking the protocol below. The setting chooses once per session and the session record keeps the runtime. Today both launchers refuse any runtime but `tmux` as `runtime-unsupported` before anything opens, through one rule in `lib/overseer-launch.sh`, because each verifies the new session's account through its tmux pane; a provider for another runtime needs the account read in this protocol first. `oversee launch` opens a fleet's first overseer through `create`; `oversee-succeed` opens a successor through `create` and stops the predecessor through `stop`; both wait for the first working turn through `inspect --launch`. Account choice, the handoff, recovery limits, who owns a succession and when a session is retired stay in those callers. The adapter does four primitive things to one exact session.

## Provider protocol

A `SESSION` is the runtime's own identifier of one session: on tmux a pane id, `%N`.

| Verb | Arguments | Result |
|---|---|---|
| `create` | `--cwd DIR (--after SESSION \| --session NAME) [--name NAME] --line COMMAND` | Open a session running `COMMAND` from `DIR`, beside the session `--after` names or at the end of the runtime session `--session` names, and print one line, `session=SESSION window=WINDOW server=SERVER`, before the harness has drawn anything. A create that opened a session and could not start the command in it closes that session again and fails. HUP, INT and TERM do not interrupt a create between opening the session and printing its line, so a caller's close-out can read the session off it. |
| `inspect` | `--session SESSION [--launch]` | Print one keyed line, `session= window= server= state=STATE`, then the session's snapshot. `STATE` is `working`, `idle`, `asking`, `walled`, `exited`, `unjudged` or `gone`. Without `--launch` it is `lib/lane-state.sh`'s word for the session, with `cause=` naming a scan the judge could not run. `--launch` is the first-turn reading of a session opened seconds ago: `working` where a turn is in flight anywhere on the screen, `asking` where the folder-trust dialog holds the harness, `idle` otherwise; under `asking` the snapshot is the line that holds it. A session the runtime no longer lists is `state=gone` with no snapshot, at exit 0. |
| `deliver` | `--session SESSION`, the block on stdin | Put the block where the session's harness reads it and print `deliver=ROUTE session=SESSION`. The block is consumed whole whatever the outcome. A session the runtime no longer lists refuses at exit `4` under `session-gone`. |
| `stop` | `--session SESSION [--successor SESSION]` | End the harness, close the session and print `stopped session=SESSION window=WINDOW`. With `--successor`, the successor takes the stopped session's place first. A session the runtime no longer lists prints `window=none` at exit 0. |

- A refusal is one keyed line on stderr, `<provider>: <key> <field>=<value>`, with the runtime's own words under it, at exit 1. A usage error exits 2.
- The dispatcher passes all provider bytes and exit codes unchanged. It refuses a verb outside the four as `verb-invalid` at exit 2 and a provider path that is not executable as `host-unavailable` at exit 2.
- A caller decides on `state=` and relays the snapshot under its own refusal as detail.

## The tmux provider

`overseer-host-tmux --help` owns its options. It reaches the tmux server the caller's tmux calls reach: the one `$TMUX` names, or the person's own at the socket tmux derives from their uid when `$TMUX` is unset (`scripts/lib/tmux-server.sh`).

| Verb | tmux calls |
|---|---|
| `create` | `new-window -d -a` after the predecessor's window, or after the last window of the named session, `-n NAME -c DIR`; then `COMMAND` and `Enter` through `lib/pane-write.sh`'s `pane_write`, which types only into a pane at its shell. `server=` is the tmux server pid, the first half of the `<server pid> <pane id>` key every reader of the session record compares. |
| `inspect` | `capture-pane -pJ` is the snapshot. The settled reading feeds it, the pane's pid and its foreground command to `lane_state`; `--launch` reads it whole through `pane_working` and `pane_trust_dialog`. |
| `deliver` | Nothing forwards the block: the harness in the pane reads the watch log inside its own turn. The verb proves the pane is live. `ROUTE` is `watch-log`. |
| `stop` | `kill-window`; with a successor, `swap-window -d`, `kill-window` and `select-window` in one client call, so the successor holds the predecessor's index and no other window moves. |

## The session record

The launch that opens a session writes the oversee state's `overseer` object before the session's first turn, in the shape [workflow-state.md](workflow-state.md) § Oversee state states: `runtime`, `server`, the session (`pane` on tmux), `window`, `account`, `launch_line` and `generation`, one more than the record it replaces. A launch abandoned after that write puts the prior record back. `oversee register` writes the same record for a session a person opened by hand and keeps the generation where the record already names that session. `oversee-watch` at its start replaces only the fields it observes, and keeps the launcher's where the record names its own pane. `tests/overseer-host.sh` holds the dispatcher and the tmux provider; `tests/oversee_launch.sh` holds the launcher and the record.
