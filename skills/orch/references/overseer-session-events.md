# Overseer session events

Read when [oversee.md § 4](../workflows/oversee.md#4-watch-and-advance) handles a line about the overseer's own session. [oversee-events.md § Event kinds](oversee-events.md#event-kinds) holds every other line.

## Recovery requests

Once per pass, the watch judges the recorded controller's session, account and context, then requests any recovery:

- Dead controller: the watch requests `request-transfer` with `cause: dead`, from the pending successor or the recorded launch fields and handoff. A record that supplies neither, the line's `record=`, gets no request.
- Walled controller, or live controller on its credit reserve: the watch requests `request-transfer` with `cause: walled`, and the overseer walk excludes the spent account.
- Under `AGENT_RUNTIME_CONTROLLER_SUCCESSION=off`, the watch requests no recovery for a dead, walled or reserve controller, and a provider stop is only resumed.

Recovery opens a fresh session, never a native resume. A Codex or Copilot controller's failed turn is read from its own session record, so a Copilot 429 rate limit walls it whatever its account reads.

## Provider stops

The watch recovers a stopped overseer by the stop's kind, which agent-runtime names, with nobody typing:

1. A usage limit, spent credit or an empty pool is the account's limit. The overseer moves to the first account with room in the walk. If no account has room, the walled case is pending (§ Pending walled case).
2. An ended or refused sign-in moves the overseer to another account at once, never back to the same one. The owner gets one notice naming the account to sign in again. With no other account, the walled case is pending, and its own account's reset does not resume it.
3. An overload, a server error, a broken stream, a network drop, a safety flag or Codex's capacity refusal is the provider not answering. The wake resumes the overseer on its own account once per pass. The first turn that returns ends the episode, and so does a failure read after 30 minutes with none read. After 30 minutes the overseer moves to the first entry with room on another provider, a move asked and retried as any recovery is. With no such entry, or a move refused or asked no more, it is resumed still.
4. The owner is told once, with the cause, when a walled case becomes pending, when its own account stays unread 30 minutes past its reset, and when the watch asks a transfer no more.
5. The owner's notices go through the overseer mailbox's owner channel, each kind once per episode. A notice the channel did not take is sent again on each pass until it lands, whatever its episode has done since.

A walk that is refused or leaves an entry unread decides no successor: the watch walks again on the next pass.

A usage-limit banner on the overseer's pane proves no wall by itself: the pane also relays lane banners. A current login wall needs no usage confirmation.

### Pending walled case

A walled case is pending when its walk chooses no successor, or leaves a provider unread 30 minutes after the case was announced. A pending case has two ways out:

- The watch walks again on each pass. Once the walk chooses an account with room, the watch requests the transfer.
- When the account judgement reads the overseer's own account with room, whatever mark it answers, and the pane, read with that room, stands idle, the watch asks the wake to resume the overseer there, once for the wall. The wake types the resume past the usage banner, as it does for a lane at a passed wall.

A turn run on the overseer, as one the owner types, holds the case on every pass it runs without ending it: nothing announces the wall again, resumes the overseer or moves it, whatever the account or the session's last failure reads. Once the turn stops, the case is pending as before, and only the walk or the resume ends it. This holds for a wall that a session's own record holds too.

A failed turn that a Codex or Copilot session's own record holds stays walled whatever its account reads (§ Recovery requests), so its own account's room never resumes it: only the walk ends it.

Every other pass that does not read the own account with room keeps the case walled: the account read fails, its headroom is unmeasured or unreadable, or the judgement answers before reading it. Such a pass walks and reads the reset as a walled pass does.

If the own account reads room and the pane stands idle, the overseer is resumed on it and nothing is walked on that pass, even where another account has room.

The owner gets one notice when the case becomes pending. It says whether the walk answered none or could not read a provider. A later failure on the same wall starts no new episode and sends no new notice. A resumed turn that stops at a new wall is a new episode, with its own notice and its own resume.

The watch keeps the reset it last read for the own account. If a later read of that account fails or leaves it unread, the reset stands. If the account is still unread 30 minutes past that reset, the owner is told once, with the cause.

## Recovery outcomes

The line announces a recovery; the duty's next run submits its request. An admitted transfer is not confirmed: its open intent owns completion. The outcomes land on the watch's stderr, `oversee-watch.err` beside the fleet state:

- `transfer-refused cause=[KEY]` under a `watch-step-failed` line: the request was refused. The recovery stays announced, and the next pass asks again.
- `successor-unread cause=[LINE]` under a `watch-step-failed` line: the walk could not answer. The recovery stays announced, and the next pass walks again. `[LINE]` names each unread host with its cause, or each unread entry with its judge's answer.
- `overseer-relaunch-failed pane=[PANE] attempt=[N] retry=[pending|exhausted] step=[STEP]`, or `overseer-capacity-failed` for a reserve recovery: the transfer failed. `retry=pending` asks again on the duty's next run: a dead recovery once more, a walked recovery while each failure leaves its successor's account unproved, which the next walk holds out. Read the failed intent with `.agents/skills/orch/scripts/orch-runtime state inspect --fleet`.
- `overseer-provider-move pane=[PANE] cause=[CAUSE] since=[EPOCH] intent=[INTENT]`: a provider stop past 30 minutes asked the move to another provider.
- `overseer-notice-sent pane=[PANE] notice=[auth|walled|account-unread|no-successor]`: the owner got that kind's notice for the episode. The sign-in notice is `overseer-auth-wall.txt` in the fleet state directory, and every other notice is `overseer-no-successor.txt` there. `overseer-notice-failed` says a send the next pass repeats.
- `overseer-record-unreadable pane=[PANE] harness=[HARNESS] cause=[CAUSE]`: a Codex or Copilot controller's own session record could not be read, so its hook rows were judged alone.

Replace the overseer by hand ([oversee.md § Controller start and adoption](../workflows/oversee.md#controller-start-and-adoption)):

- after `retry=exhausted`, which the `overseer-no-successor` notice reports;
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
