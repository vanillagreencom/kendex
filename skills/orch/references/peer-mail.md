# Peer mail

Read when an overseer writes to another repository's overseer, or handles a `peer-note` event. The write goes through `lane-mail peer`. `lane-mail --help` holds the protocol and every refusal key.

## Verbs

| Command | What it does |
|---|---|
| `lane-mail peer ask --repo REPO --file PATH [--options a,b]` | Appends one ask to the peer's overseer mailbox and to this overseer's own record, and prints `id=MESSAGE_ID`. |
| `lane-mail peer send --repo REPO --re MESSAGE_ID --file PATH` | Answers a peer's ask and releases the peer's `wait`. |
| `lane-mail peer send --repo REPO --file PATH` | Sends a note that answers no ask. |
| `lane-mail pending --item overseer [--to peer\|owner]` | Lists this overseer's unanswered asks, then the untaken directives in its own mailbox. |
| `lane-mail wait --item overseer --id MESSAGE_ID` | Blocks until a peer answers this overseer's ask. |

- A refused `peer ask` delivery records nothing and owes nothing.
- `pending --to peer` or `--to owner` keeps that audience's asks and lists no directive.

The target overseer gets each message as one watch event, `peer-note REPOSITORY MESSAGE_ID kind=KIND`, with `re=ASK_ID` on an answer. Reply only to `kind=ask`.

An overseer that runs the watch reads a peer's answer as its `kind=answer` event. A caller that runs no watch uses `wait`. Both read the same file, so an overseer that uses both records one answer twice.

## Addressing

1. Send another repository's prioritized issue with `lane-mail peer send --repo REPO --file PATH`.
2. If that repository runs no live overseer:
   - Ask the live registered Jarvis session, else the owner.
   - Recommend launching that overseer in its repository-named tmux session, with `overseer` at the base index.

- `--repo` names another repository's checkout; `lane-mail --help` states how it resolves and refuses.
- A note to this overseer's own mailbox is `lane-mail send --item overseer --directive --file PATH`.
- For a peer on another host, use `peer send` or `peer ask` with `--host --repo PATH`. `PATH` is the absolute path to the peer's main checkout on that host. Set `ORCH_LANE_HOST` to the provider for that host. Static SSH declares `peer-mail=verb` for `peer-append` and requires an `overseer` inventory row for the receiving checkout. Reply through the same route with the original sender's checkout as `--repo`. See [Static SSH provider](../schemas/lane-host.md#static-ssh-provider).
- `lane-mail send` writes only the caller's own repository's mailboxes: its lanes' and its overseer's. `peer` is the only write across repositories.
- Every message carries its sender.
- The watch reports an owner's note as an owner message and a peer's as `peer-note REPOSITORY`; `lane-mail --help` states how the repository is named.

## Who reads a note

- A note or an ask lands in the target repository's overseer mailbox.
- Its one reader is the session that the target's fleet record names in `controller`, by tmux server and pane ([workflow-state.md](../schemas/workflow-state.md)).
- In a checkout that runs no fleet, `orch-runtime register --fleet` run in a hand-opened session makes that session the controller. The hooks then treat it as the controller in every respect: its turn end meets the context marks, and it is told to hand over like a fleet overseer ([oversee.md § Succession](../workflows/oversee.md#succession)).
- The mailbox hands nothing to any other session in the checkout, the owner's included, or to any subagent.

The sender checks that reader as `lane-mail --help` states under `peer send`:

1. A local or static SSH `peer send`, an answer included, refuses `overseer-absent=ROOT` before appending where the target records no controller.
   - Run `orch-runtime register --fleet` in the session that should read that checkout's mail.
   - `peer ask` also needs this overseer's own record.
2. After the receipt or the `id=` line, at exit `0`, stderr opens with `no-reader=ROOT live=false` and a `fix=` line naming `orch-runtime register --fleet` where the controller is not live, or with `reader-unjudged=ROOT` where its status cannot be read. The message landed either way.

The named session reads its mailbox as follows:

- With a live watch, through that watch ([watch-delivery.md](watch-delivery.md)).
- Where no live watch holds the fleet record, its hooks hand it a peer's note at its turn end and after a tool call. On Copilot, a custom subagent's tool call gets nothing.
- On a harness with no hooks, read the mailbox with `lane-mail inbox --item overseer`.

## Inbound asks

`pending --item overseer` lists only this overseer's own asks and the directives past its cursor, never an inbound ask.

Once the watch reads a `peer-note`, nothing lists the inbound asks still owed an answer. Answer an inbound ask when its event arrives. After a restart mid-exchange, the overseer depends on the peer asking again, and the peer's `wait` runs to its `--timeout`.
