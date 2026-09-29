# Peer mail

The overseer-to-overseer channel: one repository's overseer writes another's mailbox. [oversee.md](../workflows/oversee.md) § 4 loads this on a `peer-note` event, and § 1 names the channel. The lane-side verbs are unchanged; `lane-mail --help` holds the protocol and every refusal key.

## Verbs

| Command | What it writes |
| --- | --- |
| `lane-mail peer ask --repo [NAME_OR_PATH] --file [PATH] [--options a,b]` | one ask, one id, in the peer's mailbox and then in this overseer's own record; prints `id=[MESSAGE_ID]`. A delivery that refuses records nothing, so nothing is owed for a question the peer never received |
| `lane-mail peer send --repo [NAME_OR_PATH] --re [MESSAGE_ID] --file [PATH]` | the answer to a peer's ask, releasing that overseer's `wait` |
| `lane-mail peer send --repo [NAME_OR_PATH] --file [PATH]` | a note that answers no ask |
| `lane-mail pending --item overseer` | the asks this overseer SENT that a peer or the owner has not answered, then the directives in its own mailbox no reader has taken yet; `--to peer` keeps the peer asks alone, `--to owner` the owner's |
| `lane-mail wait --item overseer --id [MESSAGE_ID]` | blocks for a peer's answer to this overseer's own ask |

Every `peer-note` line carries `kind=`, and only `kind=ask` is owed a reply: an answer sent to a directive would name an id that is in no outbox, so nothing would ever clear it from the sender's `pending`.

An overseer running the § 4 watch reads a peer's reply there, as the `kind=answer` line carrying `re=`; `wait --item overseer --id` is for a caller that blocks on one answer and runs no watch. Both read the same file, so an overseer that uses each records one reply twice.

## Addressing

- `--repo` names ANOTHER repository's checkout: a value holding `/` is a path, a bare name is a checkout beside this one. It resolves to that repository's main checkout, so a path inside the peer reaches the same mailbox; a path that is no checkout is refused as `repo-unresolved`, and one resolving to this checkout as `repo-self`, since both sides of an exchange in one mailbox would make this repository its own peer. A note to this overseer is `lane-mail send --item overseer`.
- Add `--host` for a peer on another host, `--repo` naming its path there.
- `lane-mail send` writes a mailbox of the caller's own repository alone, a lane's or its own overseer's. A `--root` under another repository is refused with the first line `lane-mail: lane-foreign=[ROOT]`. `peer` is the only cross-repository write.
- Every message carries its sender, so the watch reports an owner's note as `owner-note` and a peer's as `peer-note [REPOSITORY]`. The repository is the `[marketplace]` name in the sender's `kendex.toml`, else the last segment of its origin URL, else its checkout's directory name.

## Who reads a note

A note or an ask lands in the target repository's overseer mailbox, which has one reader: the session the checkout's oversee workflow state names under `.overseer` by tmux server and pane. The writers of that pair are the ones the [`overseer` row](../schemas/workflow-state.md#oversee-state) names. Among them `oversee register` names a session opened by hand, which is how a checkout that runs no fleet, the owner's dotfiles among them, names the agent that reads its mail. Registering makes that session the checkout's overseer in every respect the hooks judge, not only its mail reader: its turn end is held at the context marks and it is told to run `oversee-succeed` or write the handoff, as a fleet overseer is. Every other session in the checkout, one the owner opened there for other work included, is handed nothing from the mailbox, and a record naming a pane that no longer runs names no reader.

The named session reads it through its watch, as the `peer-note` event above. Where no live watch holds the fleet state, the `lane-mail-check` and `lane-mail-deliver` hooks, and on Copilot the `lane-mail-start` and `lane-mail-prompt` hooks, hand the note to that session at its next turn end and after its next tool call, and on Copilot at its session start and its next prompt, on the harnesses that run those hooks ([hooks/README.md](https://github.com/vanillagreencom/kendex/blob/main/hooks/README.md)); a subagent's turn end is handed nothing. Outside Copilot, a subagent's tool call is handed nothing either. A Copilot tool call names no agent, so there the named session is handed the note after a tool call only where the call's session is a lead session the hook recorded at its session start or at a turn end its own transcript proved, and a custom subagent's call, measured on Copilot CLI 1.0.88 carrying its own session id, which nothing recorded, leaves it unread for the lead's turn end. Whether a built-in task-tool subagent's calls carry their own session id or the lead's is a pending live-lane proof, and one whose calls carry the lead's is read as the lead and handed the note after its calls, which marks it read. A live watch is the `oversee-watch.pid` record the repeat watch writes beside the fleet state and removes on exit, naming a process that still runs; it reads the mailbox itself, so the hooks leave it alone while one stands. A watch run as [single passes](watch-delivery.md#single-passes) writes no watch record, so the named overseer is handed the notes as `lane-mail-check: unread=` lines, and the next pass does not report them. On a harness that runs no hooks, `lane-mail inbox --item overseer` reads the mailbox by hand.

`peer send` and `peer ask` say when nobody will read the note or the ask: where the target's record names no pane on the tmux server its start time binds, or one that no longer runs, stderr opens `lane-mail: no-reader=[ROOT]` with a `fix=` line naming `oversee register`, and where that cannot be judged from the sender's shell, `lane-mail: reader-unjudged=[ROOT]`. Both follow the receipt or the `id=` line at exit 0, since the line landed; `lane-mail --help` names each `cause=`. An answer, `peer send --re`, is not judged: the asker's `lane-mail wait --item overseer --id` reads it with no named session. The target's record is placed by the one value `ORCH_STATE_DIR` read from its settings files as data, with no other `[env]` key set and no file of the target's sourced, so nothing of the target's runs in the sender.

## What an inbound ask leaves

Everything a peer sends, a note, an ask and an answer alike, arrives in this overseer's `to-lane.jsonl` and reaches it as one `peer-note` event. `pending --item overseer` lists the asks this overseer sent from `to-overseer.jsonl`, and from `to-lane.jsonl` only the directives past its cursor, so it never lists an inbound ask.

The limit that leaves: once the watch has read a `peer-note`, nothing enumerates the inbound asks still owed an answer. An overseer that restarts mid-exchange relies on the peer re-asking, and the peer's `wait` runs to its `--timeout` in the meantime.

A second limit applies to `--host` as it ships: reaching a peer on another host needs a provider that addresses another repository's checkout, and `lane-host-ssh` addresses one repository's lanes by item and refuses an inventory naming a second repository, so it serves no peer. The attempt surfaces as `host-unreachable`, which names the failed probe rather than the provider that has no row for it.
