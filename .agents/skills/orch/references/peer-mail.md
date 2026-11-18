# Peer mail

Read when an overseer writes to another repository's overseer, or handles a `peer-note` event. One repository's overseer writes another repository's overseer mailbox through `lane-mail peer`. `lane-mail --help` holds the protocol and every refusal key.

## Verbs

| Command | What it does |
|---|---|
| `lane-mail peer ask --repo REPO --file PATH [--options a,b]` | Appends one ask to the peer's overseer mailbox and the same ask to this overseer's own record, and prints `id=MESSAGE_ID`. A refused delivery records nothing, so nothing is owed for an ask the peer never received. |
| `lane-mail peer send --repo REPO --re MESSAGE_ID --file PATH` | Answers a peer's ask, releasing the peer's `wait`. After delivery the answer is also appended to this overseer's own record, so compaction can close the inbound ask. |
| `lane-mail peer send --repo REPO --file PATH` | Sends a note that answers no ask. |
| `lane-mail pending --item overseer [--to peer\|owner]` | Lists the asks this overseer sent that nobody answered, then the directives in its own mailbox no reader has taken. `--to peer` or `--to owner` keeps that audience's asks and lists no directive. |
| `lane-mail wait --item overseer --id MESSAGE_ID` | Blocks until a peer answers this overseer's ask. |

Each message reaches the target overseer as one watch event, `peer-note REPOSITORY MESSAGE_ID kind=KIND`, with `re=ASK_ID` on an answer. Reply only to `kind=ask`: an answer to a directive names an id no outbox holds, so nothing clears it from the sender's `pending`.

An overseer running the watch reads a peer's answer as its `kind=answer` event. `wait` is for a caller that runs no watch. Both read the same file, so an overseer that uses both records one answer twice.

## Addressing

Launch only this repository's items. Send a prioritized issue that belongs to another repository with `lane-mail peer send --repo REPO --file PATH`. Where that repository runs no live overseer, ask the live registered Jarvis session, else the owner, recommending that repository's overseer be launched in its repository-named tmux session with `overseer` at the base index.

- `--repo` names another repository's checkout. A value holding `/` is a path; a bare name is a checkout beside this one. It resolves to that repository's main checkout. A path that is no checkout refuses `repo-unresolved`; one that resolves to this checkout refuses `repo-self`. A note to this overseer's own mailbox is `lane-mail send --item overseer --directive --file PATH`.
- For a peer on another host, add `--host`, with `--repo` naming its path on that host. This needs a provider that addresses another repository's checkout. `scripts/lane-host-ssh` serves one repository's lanes by item and refuses an inventory naming a second repository, so it serves no peer; the attempt refuses `host-unreachable`.
- `lane-mail send` writes only mailboxes of the caller's own repository: its lanes' and its own overseer's. A local `--root` that is not a checkout's top-level directory refuses `root-not-checkout`. A checkout of another repository refuses with the first line `lane-mail: lane-foreign=ROOT`. `peer` is the only write across repositories.
- Every message carries its sender: the watch reports an owner's note as an owner message and a peer's as `peer-note REPOSITORY`. The repository is the `[marketplace]` name in the sender's `kendex.toml`, else the last segment of its origin URL, else its checkout's directory name.

## Who reads a note

A note or an ask lands in the target repository's overseer mailbox. Its one reader is the session the target's fleet record names in its `controller` member, by tmux server and pane ([workflow-state.md](../schemas/workflow-state.md)). `orch-runtime register --fleet`, run in a session opened by hand, records that session as the checkout's controller; that is how a checkout that runs no fleet names the session that reads its mail. A registered session is the checkout's controller in every respect the hooks judge, not only its mail reader: its turn end meets the context marks and it is told to hand over, as a fleet overseer is ([oversee.md § Succession](../workflows/oversee.md#succession)). Every other session in the checkout, one the owner opened there for other work included, and every subagent, is handed nothing from the mailbox.

1. A local `peer send`, an answer included, refuses before appending where the target records no controller: `lane-mail: overseer-absent=ROOT` names `orch-runtime register --fleet` in the session that should read that checkout's mail. `peer ask` also requires this overseer's own record. For an overseer on another host, send from that host's checkout.
2. After the receipt or the `id=` line, at exit `0`, `peer send` and `peer ask` say when nobody will read the message. The sender reads the target's controller through `agent-runtime controller status`. A controller that is not live opens stderr with `lane-mail: no-reader=ROOT live=false` and a `fix=` line naming `orch-runtime register --fleet`. A status that cannot be read opens it with `lane-mail: reader-unjudged=ROOT cause=CAUSE`, and a hosted peer with `cause=hosted`. Either way the message landed.
3. An answer, `peer send --re`, has no reader check: the asker's `wait` reads it with no named session.

The sender places the target's record by the one value `ORCH_STATE_DIR` read from the target's settings files as data, and sources no file of the target's.

The named session reads its mailbox through its watch ([watch-delivery.md](watch-delivery.md)). Where no live watch holds the fleet record, the hooks hand that session a peer's note: `lane-mail-check` at its turn end, `lane-mail-deliver` after a tool call, and on Copilot `lane-mail-start` at its session start and `lane-mail-prompt` with its next prompt. A live watch is the `oversee-watch.pid` claim beside the fleet state, naming a process that still runs under the identity it recorded; while one stands the hooks leave the mailbox to it. Where the hook cannot settle whether a watch holds the fleet, it refuses under `fleet-state=` rather than read the mailbox. On Copilot a tool call that no recorded lead session made, a custom subagent's, is handed nothing, and the note waits for the lead's turn end. On a harness that runs no hooks, read the mailbox with `lane-mail inbox --item overseer`.

## Inbound asks

Everything a peer sends, note, ask and answer alike, lands in this overseer's `to-lane.jsonl` and reaches it as one `peer-note` event. `pending --item overseer` lists only the asks this overseer sent and the directives past its cursor, so it never lists an inbound ask.

Once the watch has read a `peer-note`, nothing lists the inbound asks still owed an answer. Answer an inbound ask when its event arrives. An overseer that restarts mid-exchange depends on the peer asking again, and the peer's `wait` runs to its `--timeout` meanwhile.
