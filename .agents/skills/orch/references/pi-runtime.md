# Pi runtime reference

Read when orch runs on Pi: delegating through `pi-agents-tmux`, a lane's mail wake, a Pi overseer's watch. The tools' own calling rules are the package's instructions, which Pi loads with the package ([pi-agents-tmux instructions](https://github.com/vanillagreencom/kendex/blob/main/pi-extensions/pi-agents-tmux/instructions.md)); this page holds what orch adds.

## Pane agents (Pi)

Record every delegation in workflow state: the agent name and the `taskId` a call returns, under `child_sessions[agent].agent_id` or `review_agent_ids[...]`.

A pane agent (`pane: true`) runs in a tmux pane where a tmux server answers. Where none does, it runs headless as a background one-shot and its result opens with `pane-fallback reason=no-tmux`: a hosted lane whose provider runs the harness outside tmux, such as `lane-host-ssh`, and a local lane inside the confinement wrapper, which hides the tmux socket.

A background agent, or a pane agent run headless, keeps its conversation only under a `sessionKey`; without one each call starts a fresh session, which [agent-transcripts.md](agent-transcripts.md) says how to find. Pass a workflow-scoped key:

- a dev, fix or CI delegation: `sessionKey: "dev-[ISSUE_ID]"`, which a pane ignores and a headless run resumes;
- a reviewer kept across rounds: `sessionKey: "review-issue-[ISSUE_ID]"`.

## Background deadline

`bgTaskTimeoutMs` bounds a background child, and a pane agent run headless, from the child's launch; the package's default is 2 hours. A validation run has no time limit, so the deadline covers the child's own work and one `orch-runtime validate entry --wait --run-dir [RUN_DIR]` call, which returns within 540 seconds: a child waiting on a run resumes that call after each exit 3 with `state=running`. Raise the setting only where a child's own work needs longer.

The setting is the user's `~/.pi/agent/settings.json`, or `$PI_CODING_AGENT_DIR/settings.json` where that variable is set, under `kendex.extensionManager.config["@vanillagreen/pi-agents-tmux"].bgTaskTimeoutMs`. Trusted project settings in `.pi/settings.json` override it. A hosted lane reads its host's file; a control VM's settings do not set it.

## Context before reuse

Before reusing an idle agent, apply [skill-rules.md § Delegation](skill-rules.md#delegation) with `get_subagent_result`, as the package's instructions call it. Read its `contextBudget`, never the parent's own usage. An exhausted pane is stopped and the new task delegated fresh with its saved result. A background reuse past the guard starts fresh and reports `reused as fresh (context N%)`: store the `sessionKey` it returns in workflow state in place of the exhausted one.

## Steering and completion recovery (Pi)

Use `steer_subagent` only for a mid-run correction of this Pi session's own pane child; its success reads `Bridge: active` and names the child's `sessionFile` under this session's runtime. Where the bridge target is unavailable, the tool queues an inbox message that the pane reads only when idle, which is no mid-run steering: for idle follow-up work, queue a new `subagent` task to the same pane instead. A running Pi lane that is not this session's child is messaged with `lane-mail send`, never the bridge; the pi-session-bridge CLI reads its state and answers its dialogs ([lane-reach.md § Per harness](lane-reach.md#per-harness)).

Count a completion as an agent's return only when its task ID matches the one stored in workflow state; a repeated display is no second return. `get_subagent_result` also recovers a missed or truncated pane completion and changes no ownership or delivery. A `needs_completion` answer means the child finished a turn without its `complete_subagent` record: it is no return. Send the same pane one recovery instruction to call `complete_subagent` for the stored `taskId`.

## Confinement

On Linux a local Pi lane runs inside agent-runtime's `bwrap` wrapper: the tree read-only except the paths its launch grants, a private `/tmp`, and the user's runtime folder hidden. The lane's Pi session bridge gets a folder of its own under its mailbox, named by `PI_BRIDGE_DIR`. On any other host the lane runs unconfined under the cause `macos-profile-unbuilt` (agent-runtime `confine.rs` `answer`).

## Lane mailbox wake (Pi)

A Pi lane arms no mailbox monitor ([watch-delivery.md § Lane mailbox monitor](watch-delivery.md#lane-mailbox-monitor)): its launch brief and relaunch line carry no arm line. The `pi-hooks` lane mail wake starts a turn in the idle lane when unread mail lands, an answer included, or when the session settles with mail unread. It runs the `lane-mail-deliver` hook's judge, and the turn opens with what that judge hands over after a tool call: `lane-mail-check: unread=[N]` and the envelopes, already marked read. Act on every envelope as its text directs, answers and directives alike; a halt among them names the `lane-mail inbox` command that reads it. A turn opening on any other `lane-mail-check:` line is the judge's refusal, which the lane clears as it would after a tool call. The package's [README](https://github.com/vanillagreencom/kendex/blob/main/pi-extensions/pi-hooks/README.md) § Lane mail wake states what it does.

The launch fails a Pi lane before its window where the wake would not load ([lane-directive.md § Launch gate](lane-directive.md#launch-gate)). Repair it on the lane machine, or on the host for `location=hosted`, then send the item's `launch-lane` request again: it relaunches over the `stopped` record the refusal left, and on a host the provider's `create` takes the item it already holds with `--relaunch`.

`pi-mail-wake-missing` means the selected `pi-hooks` lists no lane mail wake. Its `root`, `scope` and `location` name the deciding install, and `update=` the command that updates it there:

| Scope | Repair |
|---|---|
| `global` | Set `PI_CODING_AGENT_DIR` to the reported `root`; resolve a home-relative host root under that host's home. Run the command `update=` names: `kendex update-pi --scope global` for a carrier the settings load by path, or `pi install npm:[NAME]` for one installed from npm. |
| `project` | Run the command `update=` names from the project containing `root`: `kendex update-pi --scope project` for a carrier the settings load by path, or `pi install npm:[NAME]` for one installed from npm. In a linked worktree with no manifest of its own, `update-pi` refuses project writes and has no `--project-path` option: have the install owner replace the carrier the project settings' `packages` entry names from its updated source. A global update does not repair a project carrier. |

`pi-mail-wake-off` means the carrier lists the wake and the settings `file=` names turn it off. Load `extensions/lane-mail-wake.ts` again in that file's selection with `pi config`, or `pi config --local` for a project file.

`pi-selection-unresolved` means the selection in the settings `file=` names is no list of strings, or holds an `entry=` the gate cannot read as a plain path: one with a glob character, a `~`, a `file:` URL or a backslash, or one that starts with `#`, `./` or `!` after its prefix. Rewrite that selection as plain paths, `extensions/lane-mail-wake.ts` among them.

On a hosted lane the gate reads the same files on the host through the provider's `cat`: the Pi root's `settings.json`, the provider's root else `.pi/agent`, and the worktree's `.pi/settings.json`. Its refusals there are `compaction-on` (a settings file leaves Pi's compaction on), `pi-settings-unreadable`, `pi-carrier-unreadable`, `unsupported-for-oversee harness=pi reason=no-window-read` (the carrier puts no `context_window` on the hook payloads) and `pi-mail-wake-missing` with `location=hosted retry=launch-lane`. Before the provider creates anything, a Pi lane billing a Claude seat is refused as `host-pi-claude-seat` (agent-runtime `effects/prepare/gate.rs`).

## Standing watch (Pi)

The oversee watch ([watch-delivery.md](watch-delivery.md)) reaches a Pi overseer through a `pi-background-tasks` output wake. The spawn parameters are the package's [instructions](https://github.com/vanillagreencom/kendex/blob/main/pi-extensions/pi-background-tasks/instructions.md).

| Step | Call |
|---|---|
| Arm | `bg_task action: "spawn"` on the numbered follow command of [watch-delivery.md](watch-delivery.md), with `notifyOnOutput: true`, `notifyMode: "always"`, `notifyOnExit: true` and `timeoutSeconds: 300`. The timeout is the follow's expiry, where watch-delivery.md checks the watch is alive. Keep the pid the spawn returns (`Started [ID] (pid [PID])`): `bg_status` stops only by `pid`, and the list shows it on each task's line. |
| Read | A wake carries an inline tail capped at `outputAlertMaxChars`, so read the log numbered from the line after the last number handled: `awk 'NR >= [NEXT_LINE] { print NR ": " $0 }' "[RUN_DIR]/watch.log"`. |
| Re-arm | The per-task wake budget ends in one "wake budget exhausted" notice. Stop that follow with `bg_status action: "stop"` on the kept pid, then spawn a new one from the line after the last number handled. |
| Exit | On every exit wake, whatever ended the task, run the watch-delivery.md checks, and while they read a live watch, `bg_status action: "list"`. Spawn a new follow from the line after the last number handled only when the list does not show the kept pid as running. This keeps at most one follow, even after a stop or a replayed wake. |

The `bg_task.*` activity events that pi-session-bridge relays reach external observers only, never this session.
