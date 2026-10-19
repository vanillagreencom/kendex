# Communication

Read [communication](../../communication/SKILL.md) before a message to the user.

## Message types

Use the shared message types in [orch § Routing](../../orch/references/communication-modes.md#routing) for where to send and whether to mention the person. Jarvis adds the types below. Send messages only for these types. A consumer may add types.

| Type | Wording or local requirement |
|---|---|
| Decision request | [Questions](../../communication/references/questions.md) under [decisions.md](decisions.md#authority) |
| Critical notice | [Message purpose](../../communication/references/messages.md#message-purpose) |
| Progress report | [Reports](../../communication/references/reports.md), through the [progress checkpoint](../workflows/session.md#progress-checkpoint). Before a session handoff only when the user set no rule for it |
| Reply | [Messages](../../communication/references/messages.md) |
| Input-device notice | Before taking control, name the mouse or keyboard action and when, under [action requests](../../communication/references/questions.md#action-requests); wait for the user's agreement |
| Phone sign-in | When a sign-in waits on the person's phone, send the digits to enter at once |

## Delivery

- Apply [verification.md](verification.md#sources) to each claim before sending the message.
- Apply the [account ledger](accounts-and-secrets.md#account-ledger) limits to each message.
- Follow [orch § Thread delivery](../../orch/references/communication-modes.md#thread-delivery) when reading delivered threads.
- Complete new accounts under [Owner setup](../../orch/references/communication-modes.md#owner-setup).
