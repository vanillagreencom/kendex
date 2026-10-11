# Continuing session

Follow this workflow when starting a continuing session, reconciling open work or transferring control.

## Start

- Keep one assistant in control at a time.
- Read `state/handoff.md` first, at the path in the [home layout](../README.md#home-layout). If it is absent and the user has an earlier handoff elsewhere, read that file. Have the user move it once to the current path. Read the [Handoff contract](../references/long-session.md#handoff) before using it. Compare its state time with the clock and the user's staleness bound. Refuse a handoff outside that bound. Ask the user to set the bound if none exists.
- Register with the event source the user selected. Use its supported registration and delivery interface. The source can change without changing this session contract.
- Check the user channel and each agent's channel for unread events. Keep one communication channel per agent. Use the source's delivery order rather than sorting event ids.
- Reconcile each open item with its current source. Check what it waits for and why. Resume authorized work when the wait no longer applies.
- Follow [verification.md:Acceptance](../references/verification.md#acceptance) when selecting which references to load.
- Write the current handoff under the [Handoff contract](../references/long-session.md#handoff) before entering the event loop.

## Event loop

- Read each delivered event and connect it to an open item or create that item.
- Handle user decisions through [decisions.md:Authority](../references/decisions.md#authority). Use [communication.md:Message types](../references/communication.md#message-types) for replies, notices and scheduled reports.
- Update the item's state after each action. Keep an unresolved obligation open until its acceptance check passes.
- Run the verify pass after handling events and before waiting again. Check the due entries in the verify list at their sources under [verification.md:Sources](../references/verification.md#sources). Record the outcome and take the named next action on failure.
- Wait through the selected event source when no authorized work or due check remains.

## Succession

- Judge whether the remaining context permits continued work. Use the user's succession trigger when they set one.
- Rewrite `state/handoff.md` from current source readings under the [Handoff contract](../references/long-session.md#handoff). Move every open obligation from the progress log into the relevant handoff section.
- Start the successor with that handoff. Transfer control before it acts. Stop the predecessor after the successor accepts control. During the transfer, only the assistant that holds control acts.
- Archive the predecessor's handoff and completed progress log under `state/archive/` in the [home layout](../README.md#home-layout), using the retention rule in [accounts-and-secrets.md:Retention](../references/accounts-and-secrets.md#retention). Keep the current open items in the successor's handoff. Start the successor's log empty.
- Keep live state in the current handoff. Never move it into memory.
