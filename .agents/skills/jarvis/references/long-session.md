# Long sessions

## Homes

Each record kind has one home. Write a record to its home, never to the handoff.

| Record kind | Home |
|---|---|
| Standing rule | The skill or reference that owns it. |
| Durable fact, ruling, preference or lesson | A memory note under [memory.md:Notes](memory.md#notes). |
| Work, task or check | The tracker: an item, or a Done-when box on an item. |
| Open exchange | Its mailbox, read live: the user channel and each agent's channel. With orch installed, `lane-mail pending`, peer asks and the [Jarvis mailbox read](../SKILL.md#reachable-repositories). |
| Session state | The handoff. |

- A continuing session requires available tracker access and one user-selected project for its own tasks. Confirm that the tracker can read the workspace queue and retain tasks and checks. If setup or project selection is missing, request it through [Connect Linear](../workflows/setup-linear.md). Keep the current handoff untouched until these prerequisites hold.
- Select a session-task project in a Linear team that no repository's overseer dispatches. Confirm at project selection that no checkout's `LINEAR_TEAM` names that team. If this is unconfirmed, use [Connect Linear](../workflows/setup-linear.md) before continuing. Create each of the session's own tasks in that project through the tracker's existing issue creation command.
- Record a session's check on another item as a Done-when box on that item. The box names the check, its evidence source, its trigger and its deadline. It follows the tracker's Verifying lifecycle: an open box keeps the item in Verifying, and the box closes only on recorded evidence or an explicit disposition. Add no label.
- For a fix sent to another owner, put the Done-when box on a check item in the session's own task project instead. Link the other owner's item. Keep the box and check item open until the session records the check where the problem was seen. The other owner's Done mark closes neither the box nor the check item.
- Select the checks by the tracker's Verifying state across the workspace, and also read every open check item in the session's own task project. Read both selections live and through every page. When a read fails, report the checks unavailable.

## Handoff

Before normal succession, wait for every attached sub-agent this session launched to return in the current turn. Use the harness wait or result tool and collect each result. Record a failed child as failed. Launch an attached child only when the context room holds its return. Otherwise use the orch job runner described in `waiter-launch.md`, Launch, or a separate session. Record its run directory in the handoff. If the session is dead, walled, or cannot read its child state, the emergency handoff names each known unfinished child, its known output location, and any unknown state or location. An output location can be a file path or a harness reply. The successor reads existing child output before repeating the task.

The current handoff is `state/handoff.md` in the [home layout](../README.md#home-layout). Read this contract when writing, reading or checking a handoff or lane result during the [session workflow](../workflows/session.md). Each item has a durable id and a recorded time. The current handoff has these four sections.

| Section | Required content |
|---|---|
| State | The session: where it runs, its holds, its wake registrations and its next report. The user's open questions as ids. Each task and awaited item as a tracker id with one unresolved next action. The checkpoint records when this state was checked and the first and last log ids it covers, or none for an empty log. |
| Sub-agents | Each running lane or attached agent: its identity, task source and result destination. For an attached agent, identify its launch prompt and harness reply by the available agent or message ids. For a lane, record its task file and result file paths. Keep unfinished ids, available output locations and unknown state or locations under the emergency rule above. |
| Instructions in force | Each temporary instruction from the user, its source and the event that ends it. Link the home of a standing rule. |
| Progress log | One decision record per action at the time it occurs, under the record contract below. Use [verification.md:Sources](verification.md#sources) to record the clock time. |

- Update session-only state when it changes: an unfinished operation's next step, a running lane's identity or result path, a temporary instruction or its end event, report coverage, or a hold. Change only the affected lines and append the state-change record in the same write. Advance the checkpoint's covered log range with the update.
- At the scheduled report, refresh changed lines. Commit changed state at each scheduled report unless the user's standing instructions set another commit trigger. Never recompose the whole state for a report.
- Before succession transfers control, reconcile the checkpoint and later log records against live tracker items, the mailbox and relevant memory notes under [Homes](#homes). Record each correction as a state change and advance the checkpoint's covered log range.
- Rebuild state from the checkpoint and replay later state-change records in their recorded order. Compare the checkpoint time with the clock and the user's staleness bound. If the state is stale, its covered range is incomplete, or a source disagrees, widen the reads to the relevant source history and earlier log records. Do not refuse recovery solely because the state is stale. Keep an unread source as an unresolved next action.

- At each wake, list the user's messages since the last such check that no reply, thread reply or progress log entry covers. Answer each one older than a short wait, or log what was done about it in the progress log.
- Keep a line only if its absence would cause the successor to act wrongly or repeat work.
- Remove a tracker id from State when its item closes. Keep the completion evidence on the item.
- Keep standing rules in one home. Link that home rather than repeating its text in the handoff.
- Remove a temporary instruction when its end event occurs. Remove its copied text when the instruction's standing home now states it.
- Apply [accounts-and-secrets.md:Secret transfer](accounts-and-secrets.md#secret-transfer) to handoff contents.

### Progress records

Use named fields for each record. Record values rather than a prose account that the successor must interpret.

| Field | Required content |
|---|---|
| Id and time | The durable record id and the clock time of the action. |
| Operation | The action and the session or tracker id it affects. |
| Observed result and source | The checked outcome and its source reference. Mark unread evidence as unread. |
| Decision | The chosen action and its reason. Link any recorded disposition under [Lane results](#lane-results). |
| State change | Set or remove, the handoff section and durable item id, and the changed field names and values. Use none when the action changes no session state. |

### Lane results

Each lane result opens with an Answer section. Use one decision record per finding with these named fields.

| Field | Required content |
|---|---|
| Id | The durable finding id. |
| Question | The question this finding answers. |
| Observed result and source | What the lane checked and the source that supports the result. |
| Harm and condition | What can go wrong and the condition that permits it. State likelihood only when the source establishes it; otherwise mark it unknown. |
| Instruction | The relevant instruction and its owning source. |
| Proposed disposition | The action the lane proposes for this finding. |
| Uncertainty | Unchecked facts, unread sources or unresolved choices; none when there are none. |

- The parent records each final disposition and its evidence on the owning tracker item. Link that record from the lane result and the progress record that acts on it.
- For a durable ruling, follow [memory.md:Notes](memory.md#notes). Link its tracker item to the affected standing rule. A changed rule states only the resulting current instruction, without the session's disposition history.
- Keep only unresolved next actions in the handoff's State section. Keep completed findings and their disposition evidence in their homes under [Homes](#homes).
- Read the recorded disposition at its home before acting on a finding again.
