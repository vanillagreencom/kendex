# Pi runtime reference

Read when orch runs on Pi: delegating through `pi-agents-tmux`, a lane's mail wake, a Pi overseer's watch. The tools' own calling rules are the package's [instructions](https://github.com/vanillagreencom/kendex/blob/main/pi-extensions/pi-agents-tmux/instructions.md), which Pi loads with the package. This page holds what orch adds.

## Pane agents (Pi)

Record every delegation in workflow state: the agent name and the `taskId` a call returns, under `child_sessions[agent].agent_id` or `review_agent_ids[...]`.

A pane agent (`pane: true`) runs in a tmux pane where a tmux server answers. Where none answers, it runs headless as a background one-shot, and its result opens with `pane-fallback reason=no-tmux`.

A background agent, or a pane agent run headless, keeps its conversation only under a `sessionKey`. Without one, each call starts a fresh session; [agent-transcripts.md](agent-transcripts.md) says how to find it. Pass a workflow-scoped key:

- a dev, fix or CI delegation: `sessionKey: "dev-[ISSUE_ID]"`, which a pane ignores and a headless run resumes;
- a reviewer kept across rounds: `sessionKey: "review-issue-[ISSUE_ID]"`.

## Background deadline

`bgTaskTimeoutMs` bounds a background child, and a pane agent run headless, from the child's launch. A validation run has no time limit, so the deadline covers the child's own work and one `orch-runtime validate entry --wait --run-dir [RUN_DIR]` call. That call returns within its wait budget (`orch-runtime validate entry --help`). A child waiting on a run resumes the call after each exit 3 with `state=running`. Raise the setting only where a child's own work needs longer.

The package's [README § Setup](https://github.com/vanillagreencom/kendex/blob/main/pi-extensions/pi-agents-tmux/README.md#setup) names the settings files that set it. A hosted lane reads its host's file; a control VM's settings do not set it.

## Context before reuse

Before reusing an idle agent, apply [skill-rules.md § Delegation](skill-rules.md#delegation) with `get_subagent_result`, called as the package's instructions say. Read the agent's `contextBudget`, never the parent's own usage. Stop an exhausted pane and delegate the new task fresh with its saved result. A background reuse past the guard starts fresh and reports `reused as fresh (context N%)`: store the `sessionKey` it returns in workflow state in place of the exhausted one.

## Steering and completion recovery (Pi)

Use `steer_subagent` only to correct this Pi session's own pane child mid-run. Its success reads `Bridge: active` and names the child's `sessionFile` under this session's runtime. Where the bridge target is unavailable, the tool queues an inbox message that the pane reads only when idle, which is no mid-run steering. For idle follow-up work, queue a new `subagent` task to the same pane instead. Message a running Pi lane that is not this session's child with `lane-mail send`, never the bridge; the pi-session-bridge CLI reads its state and answers its dialogs ([lane-reach.md § Per harness](lane-reach.md#per-harness)).

Count a completion as an agent's return only when its task ID matches the one stored in workflow state. A repeated display is no second return. `get_subagent_result` also recovers a missed or truncated pane completion, and changes no ownership or delivery. A `needs_completion` answer means the child finished a turn without its `complete_subagent` record, which is no return. Send the same pane one recovery instruction to call `complete_subagent` for the stored `taskId`.

## Lane mailbox wake (Pi)

A Pi lane arms no mailbox monitor ([watch-delivery.md § Lane mailbox monitor](watch-delivery.md#lane-mailbox-monitor)), so its launch brief and relaunch line carry no arm line. The `pi-hooks` lane mail wake ([README § Lane mail wake](https://github.com/vanillagreencom/kendex/blob/main/pi-extensions/pi-hooks/README.md#lane-mail-wake)) starts a turn in the idle lane. The turn opens with what the `lane-mail-deliver` hook's judge hands over after a tool call: `lane-mail-check: unread=[N]` and the envelopes, already marked read. Act on every envelope as its text directs, answers and directives alike. A halt among them names the `lane-mail inbox` command that reads it. A turn that opens on any other `lane-mail-check:` line is the judge's refusal; clear it as after a tool call.

The launch fails a Pi lane before its window where the wake would not load ([lane-directive.md § Launch gate](lane-directive.md#launch-gate)). Repair it on the lane machine, or on the host for `location=hosted`. Then send the item's `launch-lane` request again. It relaunches over the `stopped` record the refusal left, and on a host the provider's `create` takes the item it already holds with `--relaunch`.

`pi-mail-wake-missing` means the selected `pi-hooks` lists no lane mail wake. Its `root`, `scope` and `location` name the deciding install, and `update=` names the command that updates it there:

| Scope | Repair |
|---|---|
| `global` | Set `PI_CODING_AGENT_DIR` to the reported `root`; resolve a home-relative host root under that host's home. Run the command `update=` names: `kendex update-pi --scope global` for a carrier the settings load by path, or `pi install npm:[NAME]` for one installed from npm. |
| `project` | Run the command `update=` names from the project containing `root`: `kendex update-pi --scope project` for a carrier the settings load by path, or `pi install npm:[NAME]` for one installed from npm. In a linked worktree with no manifest of its own, `update-pi` refuses project writes and has no `--project-path` option: have the install owner replace the carrier the project settings' `packages` entry names from its updated source. A global update does not repair a project carrier. |

`pi-mail-wake-off` means the carrier lists the wake and the settings `file=` names turn it off. Load `extensions/lane-mail-wake.ts` again in that file's selection with `pi config`, or `pi config --local` for a project file.

`pi-selection-unresolved` means the selection in the settings `file=` names is no list of strings, or holds an `entry=` the gate cannot read as a plain path. Such an entry holds a glob character, a `~`, a `file:` URL or a backslash, or starts with `#`, `./` or `!` after its prefix. Rewrite that selection as plain paths, `extensions/lane-mail-wake.ts` among them.

On a hosted lane the gate reads the Pi root's `settings.json` and the worktree's `.pi/settings.json` through the provider's `cat`. The provider's `create` supplies `pi-root`. The default `.pi/agent` is available on a provider that supports home-relative transfers, and a confined provider needs a usable named root. See [Launch on a provider](../schemas/lane-host.md#launch-on-a-provider). Repair `compaction-on` in the host settings file that leaves compaction enabled. For `reason=no-window-read`, update the host's carrier to one that puts `context_window` on hook payloads.

## Standing watch (Pi)

The oversee watch ([watch-delivery.md](watch-delivery.md)) reaches a Pi overseer through a `pi-background-tasks` output wake. The package's [instructions](https://github.com/vanillagreencom/kendex/blob/main/pi-extensions/pi-background-tasks/instructions.md) give the spawn parameters.

| Step | Call |
|---|---|
| Arm | `bg_task action: "spawn"` on the numbered follow command of [watch-delivery.md](watch-delivery.md), with `notifyOnOutput: true`, `notifyMode: "always"`, `notifyOnExit: true` and `timeoutSeconds: 300`. The timeout is the follow's expiry, where watch-delivery.md checks the watch is alive. Keep the pid the spawn returns (`Started [ID] (pid [PID])`): `bg_status` stops only by `pid`, and the list shows it on each task's line. |
| Read | A wake carries an inline tail capped at `outputAlertMaxChars`. Read the log numbered from the line after the last number handled: `awk 'NR >= [NEXT_LINE] { print NR ": " $0 }' "[RUN_DIR]/watch.log"`. |
| Re-arm | The per-task wake budget ends in one "wake budget exhausted" notice. Stop that follow with `bg_status action: "stop"` on the kept pid, then spawn a new one from the line after the last number handled. |
| Exit | On every exit wake, whatever ended the task, run the watch-delivery.md checks. While they read a live watch, run `bg_status action: "list"`. Spawn a new follow from the line after the last number handled only when the list does not show the kept pid as running. This keeps at most one follow, even after a stop or a replayed wake. |

pi-session-bridge relays the `bg_task.*` activity events to external observers only, never to this session.
