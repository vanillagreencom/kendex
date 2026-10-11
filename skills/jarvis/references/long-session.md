# Long sessions

## Handoff

The current handoff is `state/handoff.md` in the [home layout](../README.md#home-layout). Read this contract when writing, reading or checking a handoff during the [session workflow](../workflows/session.md). Each item has a durable id and a recorded time. Keep these sections in the current handoff.

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
