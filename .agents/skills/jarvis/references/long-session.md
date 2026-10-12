# Long sessions

## Homes

Each record kind has one home. Write a record to its home, never to the handoff.

| Record kind | Home |
|---|---|
| Standing rule | The skill or reference that owns it. |
| Durable fact, ruling, preference or lesson | A memory note under [memory.md:Notes](memory.md#notes). |
| Work, task or check | The tracker: an item, or a Done-when box on an item. |
| Open exchange | Its mailbox, read live: the user channel and each agent's channel. With orch installed, `lane-mail pending`, peer asks and `lane-mail events`. |
| Session state | The handoff. |

- Create each of the session's own tasks as a tracker issue through the tracker's existing issue creation command, in the one project the user names for session tasks. No repository dispatch reads that project.
- Record a session's check on another item as a Done-when box on that item. The box names the check, its evidence source, its trigger and its deadline. It follows the tracker's Verifying lifecycle: an open box keeps the item in Verifying, and the box closes only on recorded evidence or an explicit disposition. Add no label.
- Select the checks by the tracker's Verifying state, read across the workspace and every page. When the read fails, report the checks unavailable.

## Handoff

The current handoff is `state/handoff.md` in the [home layout](../README.md#home-layout). Read this contract when writing, reading or checking a handoff during the [session workflow](../workflows/session.md). Each item has a durable id and a recorded time. The current handoff has these four sections.

| Section | Required content |
|---|---|
| State | The session: where it runs, its holds, its wake registrations and its next report. The user's open questions as ids. Each task and awaited item as a tracker id with one next action. Record when this state was checked. |
| Sub-agents | Each running agent: its task file and result path. |
| Instructions in force | Each temporary instruction from the user, its source and the event that ends it. Link the home of a standing rule. |
| Progress log | One line per action at the time it occurs, with the operation, observed result and decision reason. Use [verification.md:Sources](verification.md#sources) to record the clock time. |

- At each wake, list the user's messages since the last such check that no reply, thread reply or progress log entry covers. Answer each one older than a short wait, or log what was done about it in the progress log.
- Keep a line only if its absence would cause the successor to act wrongly or repeat work.
- Remove a tracker id from State when its item closes. Keep the completion evidence on the item.
- Keep standing rules in one home. Link that home rather than repeating its text in the handoff.
- Remove a temporary instruction when its end event occurs. Remove its copied text when the instruction's standing home now states it.
- Apply [accounts-and-secrets.md:Secret transfer](accounts-and-secrets.md#secret-transfer) to handoff contents.
