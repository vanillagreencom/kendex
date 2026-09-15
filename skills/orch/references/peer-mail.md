# Peer mail

The overseer-to-overseer channel: one repository's overseer writes another's mailbox. [oversee.md](../workflows/oversee.md) § 4 loads this on a `peer-note` event, and § 1 names the channel. The lane-side verbs are unchanged; `lane-mail --help` holds the protocol and every refusal key.

## Verbs

| Command | What it writes |
| --- | --- |
| `lane-mail peer ask --repo [NAME_OR_PATH] --file [PATH] [--options a,b]` | one ask, one id, in this overseer's own record and in the peer's mailbox; prints `id=[MESSAGE_ID]` |
| `lane-mail peer send --repo [NAME_OR_PATH] --re [MESSAGE_ID] --file [PATH]` | the answer to a peer's ask, releasing that overseer's `wait` |
| `lane-mail peer send --repo [NAME_OR_PATH] --file [PATH]` | a note that answers no ask |
| `lane-mail pending --item overseer` | every peer ask this overseer still owes an answer |
| `lane-mail wait --item overseer --id [MESSAGE_ID]` | blocks for a peer's answer to this overseer's own ask |

## Addressing

- `--repo` is the peer's main checkout: a value holding `/` is a path, a bare name is a checkout beside this one.
- Add `--host` for a peer on another host, `--repo` naming its path there.
- `lane-mail send --item [ISSUE_ID]` refuses a lane another repository owns, with the first line `lane-mail: lane-foreign=[ROOT]`. `peer` is the only cross-repository write.
- Every message carries its sender, so the watch reports an owner's note as `owner-note` and a peer's as `peer-note [REPOSITORY]`. The repository is the `[marketplace]` name in the sender's `kendex.toml`, else the last segment of its origin URL, else its checkout's directory name.
