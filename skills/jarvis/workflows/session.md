# Continuing session

Follow this workflow when starting a continuing session, reconciling open work or transferring control.

## Start

- Keep one assistant in control at a time.
- Read `state/handoff.md` first, at the path in the [home layout](../README.md#home-layout). If it is absent and the user has an earlier handoff elsewhere, read that file. Have the user move it once to the current path. Read the [Handoff contract](../references/long-session.md#handoff) before using it. Read its State, Sub-agents and Instructions in force sections. Compare its state time with the clock and the user's staleness bound. Refuse a handoff outside that bound. Ask the user to set the bound if none exists.
- Register with the event source the user selected. Use its supported registration and delivery interface. The source can change without changing this session contract.
- Check the user channel and each agent's channel for unread events. Keep one communication channel per agent. Use the source's delivery order rather than sorting event ids.
- Confirm the session prerequisites under [Homes](../references/long-session.md#homes). If they are missing, take its setup route as the first decision and leave the handoff untouched. Otherwise reconcile the tracker queue, the open asks and the due audits through live reads of their homes. Check what each open item waits for and why. Resume authorized work when the wait no longer applies.
- Read no other record before the first decision.
- Follow [verification.md:Acceptance](../references/verification.md#acceptance) when selecting which references to load.
- Follow [Handoff replacement](#handoff-replacement) before writing the current handoff under the [Handoff contract](../references/long-session.md#handoff) and entering the event loop.

## Event loop

- Read each delivered event and connect it to an open item or create that item.
- Handle user decisions through [decisions.md:Authority](../references/decisions.md#authority). Use [communication.md:Message types](../references/communication.md#message-types) for replies, notices and scheduled reports.
- Update the item's state after each action. Keep an unresolved obligation open until its acceptance check passes.
- Run the verify pass after handling events and before waiting again. Select the checks under [Homes](../references/long-session.md#homes). Check each due box at its evidence source under [verification.md:Sources](../references/verification.md#sources). Record the outcome on the item and take the next action on failure.
- Wait through the selected event source when no authorized work or due check remains.

## Handoff replacement

- After the initial reads and first decision, read every section of the predecessor handoff and its progress log. Include records in Owed and open, Context, Agent contact, Verify and Open requests when those sections exist.
- For every record outside session state, write it to its home under [Homes](../references/long-session.md#homes), or confirm that its home already retains it. Preserve its contents, durable id and recorded time. Read each destination to confirm retention before replacing the handoff or clearing the progress log. A failed destination read or write leaves the predecessor handoff and progress log untouched and stops replacement.
- Archive the predecessor's handoff and progress log under `state/archive/` in the [home layout](../README.md#home-layout) before replacing them. Use the retention rule in [accounts-and-secrets.md:Retention](../references/accounts-and-secrets.md#retention). An archive failure stops replacement.

## Succession

- Judge whether the remaining context permits continued work. Use the user's succession trigger when they set one.
- Follow [Handoff replacement](#handoff-replacement), then rewrite `state/handoff.md` from current source readings under the [Handoff contract](../references/long-session.md#handoff).
- Start the successor with that handoff. Transfer control before it acts. Stop the predecessor after the successor accepts control. During the transfer, only the assistant that holds control acts.
- Start the successor's log empty after replacement succeeds.
- Keep session state in the current handoff. Never move it into memory.
