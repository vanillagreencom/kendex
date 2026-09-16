# Peer mail

The overseer-to-overseer channel: one repository's overseer writes another's mailbox. [oversee.md](../workflows/oversee.md) § 4 loads this on a `peer-note` event, and § 1 names the channel. The lane-side verbs are unchanged; `lane-mail --help` holds the protocol and every refusal key.

## Verbs

| Command | What it writes |
| --- | --- |
| `lane-mail peer ask --repo [NAME_OR_PATH] --file [PATH] [--options a,b]` | one ask, one id, in the peer's mailbox and then in this overseer's own record; prints `id=[MESSAGE_ID]`. A delivery that refuses records nothing, so nothing is owed for a question the peer never received |
| `lane-mail peer send --repo [NAME_OR_PATH] --re [MESSAGE_ID] --file [PATH]` | the answer to a peer's ask, releasing that overseer's `wait` |
| `lane-mail peer send --repo [NAME_OR_PATH] --file [PATH]` | a note that answers no ask |
| `lane-mail pending --item overseer` | the asks this overseer SENT that a peer has not answered |
| `lane-mail wait --item overseer --id [MESSAGE_ID]` | blocks for a peer's answer to this overseer's own ask |

Every `peer-note` line carries `kind=`, and only `kind=ask` is owed a reply: an answer sent to a directive would name an id that is in no outbox, so nothing would ever clear it from the sender's `pending`.

An overseer running the § 4 watch reads a peer's reply there, as the `kind=answer` line carrying `re=`; `wait --item overseer --id` is for a caller that blocks on one answer and runs no watch. Both read the same file, so an overseer that uses each records one reply twice.

## Addressing

- `--repo` names ANOTHER repository's checkout: a value holding `/` is a path, a bare name is a checkout beside this one. It resolves to that repository's main checkout, so a path inside the peer reaches the same mailbox; a path that is no checkout is refused as `repo-unresolved`, and one resolving to this checkout as `repo-self`, since both sides of an exchange in one mailbox would make this repository its own peer. A note to this overseer is `lane-mail send --item overseer`.
- Add `--host` for a peer on another host, `--repo` naming its path there.
- `lane-mail send` writes a mailbox of the caller's own repository alone, a lane's or its own overseer's. A `--root` under another repository is refused with the first line `lane-mail: lane-foreign=[ROOT]`. `peer` is the only cross-repository write.
- Every message carries its sender, so the watch reports an owner's note as `owner-note` and a peer's as `peer-note [REPOSITORY]`. The repository is the `[marketplace]` name in the sender's `kendex.toml`, else the last segment of its origin URL, else its checkout's directory name.

## What an inbound ask leaves

Everything a peer sends, a note, an ask and an answer alike, arrives in this overseer's `to-lane.jsonl` and reaches it as one `peer-note` event. `pending --item overseer` reads `to-overseer.jsonl`, so it never lists an inbound ask; it lists the asks this overseer sent.

The limit that leaves: once the watch has read a `peer-note`, nothing enumerates the inbound asks still owed an answer. An overseer that restarts mid-exchange relies on the peer re-asking, and the peer's `wait` runs to its `--timeout` in the meantime.

A second limit applies to `--host` as it ships: reaching a peer on another host needs a provider that addresses another repository's checkout, and `lane-host-ssh` addresses one repository's lanes by item and refuses an inventory naming a second repository, so it serves no peer. The attempt surfaces as `host-unreachable`, which names the failed probe rather than the provider that has no row for it.
