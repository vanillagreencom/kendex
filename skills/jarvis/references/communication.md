# Communication

Read [communication](../../communication/SKILL.md) once per revision, on the terms of its [§ Reading routes](../../communication/SKILL.md#reading-routes), and apply it before every message to the user.

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

### Presentation

The home's `JARVIS_TECHNICAL` and `JARVIS_STYLE` settings select communication's Technical and Style [presentation choices](../../communication/references/messages.md#reader-modes). The [settings example](../kendex.settings.toml.example) lists their values and defaults. kendex's [settings precedence](https://github.com/vanillagreencom/kendex/blob/main/docs/authoring/settings.md#where-a-value-comes-from) decides which layer a value comes from.

- Read the effective values with `.agents/skills/jarvis/scripts/lib/jarvis-env.sh config .` in the Jarvis home; another reader, such as VGS, passes the home's path in place of `.`. It prints them as JSON beside the watch settings. Read them before the session's first message and after a change, and apply them to every message to the user.
- On Jarvis main, a change to either choice writes the key under `[env]` in the home's `kendex.settings.toml` and lands it through that repository's normal commit and pull-request route. Jarvis and VGS write the same key there.
- A Jarvis satellite, whose `JARVIS_MAIN_HOST` that command reports as set, writes the key in neither `kendex.settings.toml` nor its private env file. Its choices are the values Jarvis main lands, which the satellite reads after it next syncs. A change asked for on a satellite acts on the home repository, so the satellite forwards it to Jarvis main under [Forward](agent-reach.md#forward), as [Satellite](agent-reach.md#satellite) routes such requests.
- After a write, read the value back with the same command. A different value means a higher settings layer holds the key. Report that layer to the user, and do not write there.
- A presentation choice never writes `ORCH_USER_MODE`, and it changes no merge, issue-creation, approval or report-timing setting.

## Delivery

- Apply [verification.md](verification.md#sources) to each claim before sending the message.
- Apply the [account ledger](accounts-and-secrets.md#account-ledger) limits to each message.
- Follow [orch § Thread delivery](../../orch/references/communication-modes.md#thread-delivery) when reading delivered threads.
- Complete new accounts under [Owner setup](../../orch/references/communication-modes.md#owner-setup).
