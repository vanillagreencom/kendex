# Overseer session events

Read when [oversee.md § 4](../workflows/oversee.md#4-watch-and-advance) handles a line about the overseer's own session. [oversee-events.md § Event kinds](oversee-events.md#event-kinds) holds every other line.

## Recovery requests

The watch judges the recorded controller's session, account and context once per pass, before it requests any recovery. It does not judge a record that `stop-controller` marked `off`, or one an open controller intent holds.

- A dead controller: the watch requests `request-transfer` with `cause: dead`, from its pending successor or its recorded launch fields and handoff. A record that supplies neither, the line's `record=`, gets no request.
- A walled controller, or a live controller on its credit reserve: the watch requests `request-transfer` with `cause: walled`, the spent account excluded from the overseer walk.
- Under `AGENT_RUNTIME_CONTROLLER_SUCCESSION=off` the watch requests no recovery for a dead, walled or reserve controller.

Recovery opens a fresh session, never a native resume.

A usage-limit banner on the overseer's pane proves no wall by itself: the pane also holds banners it relays from lanes. A current login wall needs no usage confirmation.

## Recovery outcomes

The line announces a recovery before its request; the duty's next run submits it. An admitted transfer is not a confirmed one: its open intent owns completion. These land on the watch's stderr, `oversee-watch.err` beside the fleet state:

- `transfer-refused cause=[KEY]` under a `watch-step-failed` line: the request was refused. The recovery stays announced, and the next pass asks again.
- `overseer-relaunch-failed pane=[PANE] attempt=[N] retry=[pending|exhausted] step=[STEP]`, or `overseer-capacity-failed` for a reserve recovery: the transfer failed. `step` is the failed intent's note, else its cause. `retry=pending` asks once more on the duty's next run. Read the failed intent with `.agents/skills/orch/scripts/orch-runtime state inspect --fleet`.

Replace the overseer by hand ([oversee.md § Controller start and adoption](../workflows/oversee.md#controller-start-and-adoption)) after `retry=exhausted`, after a walled walk that chose no successor, and wherever the watch requests no recovery: under `AGENT_RUNTIME_CONTROLLER_SUCCESSION=off`, or for a dead record that supplies no successor.

While a pass reads the controller exited or walled, or a controller intent stands open, the native-observation duty judges no lane. The other duties keep their schedule, so lane mail and owner asks are still read.

## Event kinds

### `overseer-dead`

`EVENT overseer-dead [PANE] window=[WINDOW] passes=[N] succession=[on|off] source=[SOURCE] [cause=memory-cap] [record=[GENERATION]:[PANE]|none]`: the recorded controller ended.

- `source=pane`: the recorded pane is gone from its server, or the server keeps it after its process exited. Said on its first pass.
- `source=record`: a saved exit over a pane holding only shells. Said on its first pass.
- `source=rows`: the harness's SessionEnd row over such a pane. Said on its first pass.
- `source=process`: the recorded process is gone, or the record names none. Said on its first pass.
- `source=context`: the session's context fills its window with no Stop row after the reading. Said after `ORCH_OVERSEER_DEAD_PASSES` passes, as is a pane holding only its shell while the recorded process still runs.
- `cause=memory-cap`: the control group's memory cap killed a process since the last live pass; the recovery's request carries it.
- `record=`: the record's launch fields cannot supply a successor, so the watch requests none.
- `succession=off`: the watch announces and recovers nothing.

The watch tells the owner of each death once, through the overseer mailbox's owner channel, naming the pane, the source and whether it requests recovery. Read § Recovery requests and § Recovery outcomes before treating the line as a replacement. The successor reads the handoff and follows the standing watch log.

### `overseer-walled`

`EVENT overseer-walled [PANE] window=[WINDOW] passes=[N] succession=[on|off] source=[SOURCE]`: the controller cannot take another turn on its account. The banner or the account reading follows the line.

- `source=auth`: a current login failure. Said on its first pass.
- `source=rows`: an authentication or usage failure its harness wrote. Said on its first pass; a usage row stands unless the account judge measures room below the mark.
- `source=account`: a live controller whose account has no headroom, a `plan_ended` account among them. Said on its first pass.
- `source=pane`: a usage banner on the pane, confirmed by the account judge on `ORCH_OVERSEER_DEAD_PASSES` passes.

The recovery is § Recovery requests. A login wall or an ended plan needs the owner to restore access or sign in to another account; a usage reset does not repair it.

### `overseer-reserve`

`EVENT overseer-reserve [PANE] window=[WINDOW] passes=1 succession=[on|off] source=[SOURCE]`: the account judge reads spendable credit below the launch reserve. The controller stays live while the watch requests its reserve recovery under § Recovery requests. No `overseer-mark` line goes with it. A refusal or an exhausted recovery leaves lane checks, mail and owner-ask deadlines running. A measured reading below the mark clears it; an unread one does not.

### `overseer-context-unmeasured`

`EVENT overseer-context-unmeasured [PANE] gap=[GAP]`: the overseer mailbox's `context.json` holds no reading, only the gap the turn-end hook gave. Nothing judges the overseer's context mark until a reading stands; no gap stops a lane or a launch. The line prints each pass the gap stands. Once it has stood two passes, the watch sends the owner one notice, the file `overseer-context-gap.txt`.

- `home-unnamed`, `home-mismatch`, `pane-unrecorded`: the fleet record names no launch home, another session's, or another pane or none. Run `.agents/skills/orch/scripts/orch-runtime register --fleet` from this pane to record them again.
- `session-record`: a Copilot session record that did not answer. Set the account's `statusLine` ([copilot-runtime.md § Account setup](copilot-runtime.md#account-setup)).
- `context-unmeasurable`: no reader of the session answered, and the session's own record holds no figure: a session before its first tool call, or one whose Copilot extension and status line both fail. Where the gap stands past the first tool call, hand the session over as the last bullet says.
- `usage-absent` on Codex: the rollout under the recorded launch home holds no `token_count` row yet. The overseer keeps running.
- Any other gap, `transcript-unnamed`, `usage-absent`, `usage-unread` or `session-mismatch`, is this session's own payload, transcript or usage line, which no record repairs. Hand the session over through [oversee.md § Succession](../workflows/oversee.md#succession) before the context wall.

A record naming another pane, another harness than the fleet record's for this pane, or another session than the pane's latest SessionStart row is another session's: it draws neither this line nor `overseer-context-stale`.

### `overseer-context-stale`

`EVENT overseer-context-stale [PANE] age=[SECONDS]`: the overseer's context record is more than an hour old, and a Stop row came after it. The hook ran and wrote no reading, so nothing judges the context mark. The line prints each pass while the record stays stale. Hand the session over as for `overseer-context-unmeasured`, and report the hook's stderr from that turn end.

### `overseer-mark`

`EVENT overseer-mark [PANE] kind=[context|headroom|rate|memory] value=[N] mark=[N] succession=[on|off]`: `orch-runtime marks --fleet` reached a mark on the recorded controller. The line repeats every `ORCH_OVERSEER_MARK_REPEAT` passes while the mark stands. An unmeasured judgement leaves the mark unknown.

The line under it names the step:

- `succession=on`: hand the session over at the next safe point through [oversee.md § Succession](../workflows/oversee.md#succession). Choose the successor with `.agents/skills/orch/scripts/orch-runtime successor --fleet --cwd [CHECKOUT] --predecessor [PANE] --mark [KIND]`, then ask `orch-runtime op --fleet --effect-exit` for `request-transfer` with `cause` `live`, its `.result.successor` as the successor and `.result.expected` as the expected record.
- `succession=off`: no successor opens. Write the overseer handoff file and ask the owner to start a fresh overseer session.
