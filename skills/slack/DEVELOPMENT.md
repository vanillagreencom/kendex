# slack development

Maintainer notes. Consumer docs: [README.md](README.md); the agent contract: [SKILL.md](SKILL.md); why the package is shaped this way: kendex decisions D009, D014 and D032.

## Layout

- `scripts/slack`: the Bash launcher. It loads the checkout's settings through the orch skill's `kendex-env.sh`, checks for Python 3.8 and the orch install, names that install in `SLACK_ORCH_DIR`, and execs `scripts/lib/main.py`.
- `scripts/lib/main.py`: argv to one verb.
- `verbs.py` holds setup, post, read, thread, compact, install and status.
- `relay.py` holds the listener and its selected inbound loop.
- `inbound.py` holds the local queue transport.
- `scripts/lib/api.py`: the Slack Web API client.
- `websocket.py`: the RFC 6455 client the Socket Mode connection runs on.
- `mailbox.py`: the mailbox store reader and `lane-mail` writes.
- `markup.py`: the outbound tracker-link judge, a file comment's standard Markdown converted to mrkdwn, and Slack markup read back as typed.
- `store.py`: the binding, journal, status record, relay and hold locks, and the files owners sent.
- `secret.py`: the secret-value check.
- `settings.py`: the environment.
- `refusals.py`: every keyed line and its explanation.
- `systemd/slack-listen.service`: the unit template `install` fills.
- The orch skill must be installed beside this package: the launcher sources `../orch/scripts/lib/kendex-env.sh` and is the one place that spells the location, which `secret.py` reads from `SLACK_ORCH_DIR` for `references/secret-value.ere`.
- The sibling mailbox package supplies the in-process reader, shared jq definitions and common-root helper. Each root supplies mailbox data and its `.agents/skills/mailbox/scripts/lane-mail` write command.
- The installed common-root helper resolves overseer mail to the main checkout. Slack records stay at the bound checkout.
- The launcher names the optional sibling Linear install in `SLACK_LINEAR_DIR`. `markup.py::outbound` runs once at `RootRelay._send` and `verbs.post`, before caller secret checks.
- Tracker discovery calls the sibling Linear skill's `linear.sh teams keys` in each root. It uses workspace keys without `LINEAR_TEAM`. GitHub reference discovery calls `gh repo view` in that root.
- These child processes inherit the Slack process environment. The Linear launcher reads the target root's project configuration.

## Constraints

- The relay serves every install route and hosts without systemd. It owns reload and worker progress without a separate watcher process, path unit or kendex hook.
- The stall bound includes API and socket name resolution, which Python's socket timeout does not limit.
- A hard stall exit skips the download's normal cleanup and can leave its `.part-*` temporary file in `tmp/slack/files`.
- The receipts rows list directives alone, and they alone judge a directive from a producer whose events carry no `line`. The relay reads receipts only while an `eyes` mark waits.
- The bot user id comes from `auth.test` at start; a message from that user or from any bot is never routed. Slack sends the relay's own posts as events too; this rule drops them.
- The existing `RootRelay.on_message` owns owner checks, mailbox writes and bot-upload binding for both inbound sources.

## Tests

```bash
for t in skills/slack/tests/*.test.sh; do bash "$t"; done
```

- `markup.test.sh` tests the markup module directly in fixture checkouts, without Slack or mailbox writes.
- `websocket.test.sh` drives the client over a socket pair.
- The other suites start `tests/lib/fake_slack.py`, a fake Slack Web API and Socket Mode WebSocket with a control surface under `/_test/`.
- They build checkouts that link the real orch scripts, so every mailbox write goes through the real `lane-mail`.
- `SLACK_API_URL` names another API endpoint. The suites point it at the fake, whose `apps.connections.open` answers a `ws://` URL on the same port; nothing else sets it.
- The assertion library and the fixture builders are `tests/lib/harness.sh`.
- A control runs a mutant: `sk_mutant` copies `scripts/` and replaces one pattern exactly once. `sk_copy` makes the copy alone, which a row edits as an update does.

## Live proof

The rows the fake cannot prove. Each needs the owner's Slack app and channel; a host with no `SLACK_BOT_TOKEN` cannot run them, so each stands pending with the command that proves it.

| Row | Command | State |
|-----|---------|-------|
| An owner message in the channel lands in the mailbox in under 3 seconds; record the measured figure on KEN-2082 | Write top-level; compare the message's ts with the envelope's `at` in `lane-mail events --item overseer` | pending |
| A relay restart and a dropped network each lose no owner message | stop the relay, write, start it; drop the host's network, write, restore it; `lane-mail events --item overseer` | pending |
| The owner writes in the channel and the overseer's notice lands in that thread within a minute | Write top-level; the overseer answers with `lane-mail notice --item overseer --to owner --ref <ID>`; read the thread | pending |
| An ask with an @mention receives repeated answers with eyes and no relay text; explicit close clears relay status | `lane-mail ask --item overseer --to owner --options a,b --recommend a --effect none --file q.txt`; reply twice; inspect `lane-mail events --item overseer` and reactions; `lane-mail resolve --item overseer --id <ASK>`; inspect `slack listen --status` | pending |
| A second ask answered in the chat shows in the thread | `lane-mail resolve --item overseer --id <ASK> --text a.txt`; read the thread | pending |
| A third ask left unanswered proceeds at the deadline with a notice in the thread | `lane-mail ask ... --wait 1`; wait for the watch; read the thread | pending |
| A report lands with its file | `orch-runtime report write`; read the channel | pending |
| An owner's screenshot lands as a readable path in the directive | Send an image in the channel; `lane-mail events --item overseer`; open the path | pending |
| A directive shows :eyes: as it lands and :white_check_mark: once read, with no bot message | Write top-level; watch the reaction; `lane-mail inbox --item overseer`; watch it swap | pending |
| A post of `**bold**`, a list and a code block renders formatted, its @mention notifies, and an ask's deadline shows in the owner's time zone | `slack post --mention --text` with that body; an ask with `--wait`; read both on a phone | pending |
| A forced stall posts one @mention alert to the overseer's channel and the alert channel | `slack post --mention --text "..."` and `slack post --channel <ALERTS> --mention --text "..."` | pending |
| The crash between the mailbox append and the journal mark delivers each note once | kill the relay after a delivery, remove that delivery's `in` line from `tmp/slack/journal.jsonl`, write again, restart; `lane-mail events --item overseer` | pending |
| A second relay on the same checkout is refused | `slack listen --root <checkout> --once` beside the running unit | pending |
| A connected relay delivers a live owner reply in a thread older than `SLACK_THREAD_DAYS`, with its thread pointer and parent context; reconnect lookback stays bounded | With the relay connected, reply under a message older than `SLACK_THREAD_DAYS`; check `thread_ts` and `parent` in `lane-mail events --item overseer` | pending |
| Chat and Slack answers both remain answers until explicit close; a later reply is a directive | `lane-mail send --item overseer --re <ASK> --file a.txt`; reply in Slack; `lane-mail resolve --item overseer --id <ASK>`; reply again; inspect `lane-mail events --item overseer` | pending |
| An apply that changes the package reloads the unit's relay | `kendex apply` with a changed `relay.py`; `slack listen --status` shows the new `code=` and `systemctl --user show -p MainPID slack-listen.service` the same pid | pending |
| The relay's resident memory under the user slice with three bound checkouts | `systemctl --user status slack-listen.service` after an hour | pending |
| Every row above, on a workstation with a local overseer, token from the private env file | the [README § Setup](README.md#setup) steps with `--name kendex-<name>-local` | pending |
| Every row above, for a Codex and a Pi overseer | the [README § Setup](README.md#setup) steps in each checkout | pending |
