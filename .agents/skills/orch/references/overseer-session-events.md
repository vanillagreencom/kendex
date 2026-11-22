# Overseer session events

Read when [oversee.md § 4](../workflows/oversee.md#4-watch-and-advance) handles a line about the overseer's own session. [oversee-events.md § Event kinds](oversee-events.md#event-kinds) holds every other line.

## Recovery requests

Once per pass, the watch judges the recorded controller's session, account and context, then requests any recovery:

- Dead controller: the watch requests `request-transfer` with `cause: dead`, from the pending successor or the recorded launch fields and handoff. A record that supplies neither, the line's `record=`, gets no request.
- Walled controller, or live controller on its credit reserve: the watch requests `request-transfer` with `cause: walled`, and the overseer walk excludes the spent account.
- Under `AGENT_RUNTIME_CONTROLLER_SUCCESSION=off`, the watch requests no recovery for a dead, walled or reserve controller.

Recovery opens a fresh session, never a native resume.

A usage-limit banner on the overseer's pane proves no wall by itself: the pane also relays lane banners. A current login wall needs no usage confirmation.

## Recovery outcomes

The line announces a recovery; the duty's next run submits its request. An admitted transfer is not confirmed: its open intent owns completion. The outcomes land on the watch's stderr, `oversee-watch.err` beside the fleet state:

- `transfer-refused cause=[KEY]` under a `watch-step-failed` line: the request was refused. The recovery stays announced, and the next pass asks again.
- `overseer-relaunch-failed pane=[PANE] attempt=[N] retry=[pending|exhausted] step=[STEP]`, or `overseer-capacity-failed` for a reserve recovery: the transfer failed. `retry=pending` asks once more on the duty's next run. Read the failed intent with `.agents/skills/orch/scripts/orch-runtime state inspect --fleet`.

Replace the overseer by hand ([oversee.md § Controller start and adoption](../workflows/oversee.md#controller-start-and-adoption)):

- after `retry=exhausted`;
- after a walled walk that chose no successor;
- wherever the watch requests no recovery: under `AGENT_RUNTIME_CONTROLLER_SUCCESSION=off`, or for a dead record that supplies no successor.

While a pass reads the controller exited or walled, or a controller intent stands open, the native-observation duty judges no lane. The other duties keep their schedule, so the watch still reads lane mail and owner asks.

## Event kinds

### `overseer-dead`

`EVENT overseer-dead [PANE] window=[WINDOW] passes=[N] succession=[on|off] source=[SOURCE] [cause=memory-cap] [record=[GENERATION]:[PANE]|none]`: the recorded controller ended.

- `record=`: the record's launch fields cannot supply a successor, so the watch requests none.
- `succession=off`: the watch announces and recovers nothing.

The watch tells the owner of each death once, through the overseer mailbox's owner channel. Read § Recovery requests and § Recovery outcomes before treating the line as a replacement. The successor reads the handoff and follows the standing watch log.

### `overseer-walled`

`EVENT overseer-walled [PANE] window=[WINDOW] passes=[N] succession=[on|off] source=[SOURCE]`: the controller cannot take another turn on its account. The banner or the account reading follows the line.

- § Recovery requests holds the recovery.
- A login wall (`source=auth`) or an ended plan (`plan_ended`) needs the owner to restore access or sign in to another account; a usage reset does not repair it.

### `overseer-reserve`

`EVENT overseer-reserve [PANE] window=[WINDOW] passes=1 succession=[on|off] source=[SOURCE]`: the account judge reads spendable credit below the launch reserve.

- The controller stays live while the watch requests its reserve recovery under § Recovery requests.
- A refusal or an exhausted recovery leaves lane checks, mail and owner-ask deadlines running.

### `overseer-context-unmeasured`

`EVENT overseer-context-unmeasured [PANE] gap=[GAP]`: the overseer mailbox's `context.json` holds no reading, only the gap the turn-end hook gave. Nothing judges the overseer's context mark until a reading stands. No gap stops a lane or a launch. After two passes, the watch sends the owner one notice, the file `overseer-context-gap.txt`.

- `home-unnamed`, `home-mismatch`, `pane-unrecorded`: run `.agents/skills/orch/scripts/orch-runtime register --fleet` from this pane to record the launch home and pane again.
- `session-record`: a Copilot session record did not answer. Set the account's `statusLine` ([copilot-runtime.md § Account setup](copilot-runtime.md#account-setup)).
- `context-unmeasurable`: no reader of the session answered, and the session's own record holds no figure. Where the gap stands past the first tool call, hand the session over as the last bullet says.
- `usage-absent` on Codex: the rollout holds no `token_count` row yet. The overseer keeps running.
- Any other gap is this session's own payload, transcript or usage line, which no record repairs. Hand the session over through [oversee.md § Succession](../workflows/oversee.md#succession) before the context wall.

### `overseer-context-stale`

`EVENT overseer-context-stale [PANE] age=[SECONDS]`: the overseer's context record is more than an hour old, and a Stop row came after it, so nothing judges the context mark.

- Hand the session over as for `overseer-context-unmeasured`.
- Report the hook's stderr from that turn end.

### `overseer-mark`

`EVENT overseer-mark [PANE] kind=[context|headroom|rate|memory] value=[N] mark=[N] succession=[on|off]`: `orch-runtime marks --fleet` reached a mark on the recorded controller.

- The line repeats every `ORCH_OVERSEER_MARK_REPEAT` passes while the mark stands.
- The line under it names the step:
  - `succession=on`: hand the session over at the next safe point through [oversee.md § Succession](../workflows/oversee.md#succession), with the line's `kind` as the successor choice's `--mark`.
  - `succession=off`: no successor opens. Write the overseer handoff file and ask the owner to start a fresh overseer session.
