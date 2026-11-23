# Overseer takeover

Run this at succession, at takeover and after compaction.

- Load `mailbox` before the first command.
- Keep the orch `SKILL.md` rules and the installed project instructions in force.
- Read only the sections each step names, and print no state file.
- Every read below is bounded; read a record by item only when a step needs it.
- A takeover never submits a fresh `start-controller`: that is a fleet's first start ([watch-delivery.md § Reader directory](../references/watch-delivery.md#reader-directory)).

## 1. Read the mailbox and handoff

The overseer mailbox carries owner and delegate notes, and data notices a program writes there, which the watch reports as `data-note` and which give no instruction ([oversee-events.md § `data-note`](../references/oversee-events.md#data-note)).

- A note arrives through `.agents/skills/mailbox/scripts/lane-mail send --item overseer --directive --file [PATH]`, run from any project checkout.
- The [watch](oversee.md#4-watch-and-advance) reports each note at least once as `owner-note`.
- Peer overseers write the same mailbox; the watch reports their notes as `peer-note` ([peer-mail.md](../references/peer-mail.md)).
- Under single passes, the lane-mail hooks hand notes over instead, as `lane-mail-check: unread=` at turn end and after tool calls ([peer-mail.md § Who reads a note](../references/peer-mail.md#who-reads-a-note)).
- Reply with `lane-mail notice --item overseer --to owner --ref [NOTE_ID] --file [PATH]`.
- Word the reply under communication's [message wording](../../communication/references/messages.md) and orch's [Owner delivery](../references/communication-modes.md#owner-delivery) and [Thread delivery](../references/communication-modes.md#thread-delivery).
- Ask the owner a question under [communication-modes.md § Owner asks](../references/communication-modes.md#owner-asks), never in a question dialog.
- Read the linked communication and peer-mail sections when a note, reply or ask needs them.

1. Read the mailbox first in every session, before the handoff.
   - `.agents/skills/mailbox/scripts/lane-mail inbox --item overseer` prints every note no reader has taken, and moves the mailbox's cursor past them.
   - Act on each note but a data notice, or record it in the fleet log.
   - The watch reads through the same cursor, so it does not report those notes again. The exception is a note the watch read earlier and has not acknowledged; a repeated note id is one already seen.
   - `lane-mail pending --item overseer` lists what is still owed (`lane-mail --help`).
2. Read the standing instructions.
   - `orch-runtime state get --fleet /standing` answers the fleet state's `standing[]` rows as `result.value`.
   - Each row stays in force until the end its `end` names ([communication-modes.md § Recording](../references/communication-modes.md#recording)).
   - Act under each until its end comes, then lift it as that section says.
   - Then read the recent decisions: `orch-runtime state log takeover --fleet` answers the fleet log's bounded tail as `result.rows`.
3. Read the opening hold-check paragraph of [communication-modes.md § Handoff](../references/communication-modes.md#handoff).
   - Then read the handoff the brief names (default `tmp/handoffs/OVERSEER-HANDOFF.md`), its State and Workarounds, before the first decision.
   - Read that section's snapshot and writer rules before replacing the handoff.
4. Convert, once and before the first decision, a handoff that holds anything beyond that section's snapshot shape, such as a released orch's prose. **Skip if** the handoff is absent or holds that shape alone, as a rebuilt Stop or succession writes it. A dead or walled recovery reads the existing handoff at step 3 and takes this step by the same test. Otherwise:
   1. Move each live temporary instruction into `standing[]` as [§ Recording](../references/communication-modes.md#recording) adds a row, with its source as `id` and its end event as `end`, unless `standing[]` already holds that `id`.
   2. Lift each `standing[]` row whose end is proved, as that section lifts one.
   3. Move each other live obligation to its home in [§ Handoff](../references/communication-modes.md#handoff)'s list of what stays out, or confirm the home holds it. Keep each live hold in State with its ask or blocker id, and each open owner ask id.
   4. Write the snapshot once with `orch-runtime handoff --fleet --body [BODY]`, under that section's writer rules.
5. Read the open lane asks from the mailboxes, never from the handoff alone.
   - `.agents/skills/orch/scripts/orch-runtime handoff --fleet --asks` answers every ask a running lane's mailbox holds open, with its id and lane.
   - Answer each before reporting that no lane waits on the root.
6. Read the lane records with `orch-runtime state get --fleet /lanes`, keeping those whose `status` is `running`.
   - Read the controller record with `orch-runtime state get --fleet /controller`, and the account listing with `.agents/skills/orch/scripts/orch-runtime lane roster`.
   - Read the whole `fleet_log` or `lanes[]` only for a named unresolved question.
   - Load only the reference section the current event needs.
7. Fill the launch queue from the tracker, before [§ 2](#2-claim-and-follow-the-watch) reports the watch ready.
   - Read the current queue with `orch-runtime state get --fleet /launch_queue`.
   - Run [oversee.md § 2](oversee.md#2-select-work) selection against the tracker live, through every page. It judges each item by its last lane record of any status, from the `/lanes` read step 6 made.
   - Read the handoff's queue list as an index only. Once the selection completes, an item the list names that the selection does not keep leaves the queue, and an item the selection keeps that the list lacks joins it.
   - A selection that stops leaves the queue as it is.
   - Write the result as [oversee-events.md § Keep the report's inputs current](../references/oversee-events.md#keep-the-reports-inputs-current) does. Then launch under [oversee.md § 3](oversee.md#3-launch) where the cap has room.
8. Read the overseer's readiness with `.agents/skills/orch/scripts/orch-runtime ready --duty overseer`.
   - Each `unready duty=overseer setting=[KEY]` line names a key that `lane-mail ask --issue` refuses an ask without.
   - Report each such key to the owner, and send each owner ask without `--issue` and `--do` until the key is set.

- With no handoff, start from the tracker.
- With no item, handoff, note or pending owner ask, send the [§ Opening question](../references/communication-modes.md#opening-question).
- With an ask, wait for its resolution through [the watch](#2-claim-and-follow-the-watch).
- The handoff stays on the overseer's host; the default path is ignored through `/tmp/`.
- Before reading or writing a custom repository path, check that Git tracks no entry there and ignores the path. Otherwise stop and report it.
- [Stop](oversee.md#5-stop) rewrites the file.

## 2. Claim and follow the watch

### Fleet state address

The fleet's record is the oversee state ([workflow-state.md § Oversee state](../schemas/workflow-state.md#oversee-state)), at one address for the whole session.

- `[OVERSEE_STATE]` is the `result.path` of the command below, run from the overseer's checkout.
- [The watch](oversee.md#4-watch-and-advance) takes it as `--file`.
- `[OVERSEE_STATE_DIR]` is its directory.
- A command run outside the overseer's checkout names it with `orch-runtime --state-dir`, so that command reads and records the same fleet.
- [lane-directive.md § Launch gate](../references/lane-directive.md#launch-gate) states which repositories' checkouts a launch admits.

```bash
.agents/skills/orch/scripts/orch-runtime state path --fleet
```

### Watch reader

1. Read [watch-delivery.md](../references/watch-delivery.md) § The watch, § Reader directory, § Claim and the section and row for this harness.
2. Read the claim through `orch-runtime watch status --fleet`.
3. With a live claim, follow the log from the handoff's next unhandled line.
4. With no live claim, in a session the fleet state records as its overseer, start the watch from this session with the command of [oversee.md § 4](oversee.md#4-watch-and-advance).
   - Do this before following the log or reporting the watch ready.
   - Follow the log once `watch status` reads the claim `live`.
5. On a refusal, report it to the owner and do not report the watch ready.
   - `watch-running` names a claim another session holds; the runner's own keyed line names its cause.
   - A failed claim read takes watch-delivery.md § Claim's rule.

## 3. Handle delivered events

1. On delivery, read [oversee-reads.md](../references/oversee-reads.md) § Bounded lane reads or § Bounded issue reads, and [oversee.md § 4](oversee.md#4-watch-and-advance)'s Judgement at every event, only where the event needs them. Then read [oversee-events.md § Judgement rules](../references/oversee-events.md#judgement-rules) and the current [event kind](../references/oversee-events.md#event-kinds) alone.
2. Before selecting or launching work, read [oversee.md §§ 1-3](oversee.md#1-resolve-the-launch-surface) and the [lane-launch.md](../references/lane-launch.md) sections its § 3 names. Before stopping or preparing a succession, read [oversee.md § 5](oversee.md#5-stop). Read only the route the action needs.
3. After handling the event, keep following the watch under § 2.
