# Long sessions

## Start

- Keep one assistant in control at a time.
- Read the current handoff before taking control. Compare its state time with the clock and the user's staleness bound. Refuse a handoff outside that bound. Ask the user to set the bound if none exists.
- Register with the event source the user selected. Use its supported registration and delivery interface. The source can change without changing this session contract.
- Check the user channel and each agent's channel for unread events. Keep one communication channel per agent. Use the source's delivery order rather than sorting event ids.
- Reconcile each open item with its current source. Check what it waits for and why. Resume authorized work when the wait no longer applies.
- Follow [verification.md:Acceptance](verification.md#acceptance) when selecting which references to load.

## Event loop

- Read each delivered event and connect it to an open item or create that item.
- Handle user decisions through [decisions.md:Authority](decisions.md#authority). Use [communication.md:Message types](communication.md#message-types) for replies, notices and scheduled reports.
- Update the item's state after each action. Keep an unresolved obligation open until its acceptance check passes.
- Run the verify pass after handling events and before waiting again. Check the due entries in the verify list at their sources under [verification.md:Sources](verification.md#sources). Record the outcome and take the named next action on failure.
- Wait through the selected event source when no authorized work or due check remains.

## Handoff

Each item has a durable id and a recorded time. Keep these sections in the current handoff.

| Section | Required content |
|---|---|
| State | What is running, where it runs, holds and event registrations. Record when this state was checked. |
| Owed and open | Each obligation, its owner, source link, acceptance check and wait condition. Include due audits and their next check. |
| Instructions in force | Each temporary instruction, who gave it, when they gave it and when it ends. Link the home of a standing rule. |
| Context | Facts needed to judge an open item that its source does not hold. Name the item each fact serves. |
| Agent contact | How to reach each agent and receive its events. |
| Verify | Each open check, the source to read, the result that closes it, its due time and the next action on failure. |
| Open requests | Unanswered questions and unclosed requests, with their source links. |
| Progress log | One line per action at the time it occurs, with the operation, observed result and decision reason. Use [verification.md:Sources](verification.md#sources) to record the clock time. |

- Keep a line only if its absence would cause the successor to act wrongly or repeat work.
- Remove done items as soon as their acceptance holds. Keep their completion evidence in the source record.
- Remove context when its open item closes. Promote a durable ruling through [memory.md:Notes](memory.md#notes).
- Keep standing rules in one home. Link that home rather than repeating its text in the handoff.
- Remove a temporary instruction when its end condition holds. Remove its copied text when the instruction's standing home now states it.
- Apply [accounts-and-secrets.md:Secret transfer](accounts-and-secrets.md#secret-transfer) to handoff contents.

## Succession

- Judge whether the remaining context permits continued work. Use the user's succession trigger when they set one.
- Rewrite the handoff from current source readings. Move every open obligation from the progress log into the relevant handoff section.
- Start the successor with that handoff. Transfer control before it acts. Stop the predecessor after the successor accepts control. During the transfer, only the assistant that holds control acts.
- Archive the predecessor's handoff and completed progress log under the retention rule in [accounts-and-secrets.md:Retention](accounts-and-secrets.md#retention). Keep the current open items in the successor's handoff. Start the successor's log empty.
- Keep live state in the current handoff. Never move it into memory.
