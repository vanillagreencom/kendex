# slack development

Maintainer notes. Consumer docs: [README.md](README.md); the agent contract: [SKILL.md](SKILL.md); why the package is shaped this way: kendex decision D009.

## Layout

- `scripts/slack`: the Bash launcher. It loads the checkout's settings through the orch skill's `kendex-env.sh`, checks for Python 3.8 and the orch install, names that install in `SLACK_ORCH_DIR`, and execs `scripts/lib/main.py`.
- `scripts/lib/main.py`: argv to one verb; `verbs.py` holds setup, post, compact, install and status; `relay.py` the listener.
- `scripts/lib/api.py`: the Slack Web API client, `mailbox.py` the `lane-mail` calls, `markup.py` Slack's message markup read back as typed, `store.py` the binding, journal, status record and lock, `secret.py` the secret-value check, `settings.py` the environment, `refusals.py` every keyed line and its explanation.
- `systemd/slack-listen.service`: the unit template `install` fills.
- The orch skill must be installed beside this package: the launcher sources `../orch/scripts/lib/kendex-env.sh` and is the one place that spells the location, which `secret.py` reads from `SLACK_ORCH_DIR` for `references/secret-value.ere`. Each root's `.agents/skills/orch/scripts/lane-mail` is that root's mailbox.

## Constraints

- The relay keys every inbound delivery `channel:ts` and hands the key to `lane-mail`. Its journal skips a stamp it already carried; for a stamp the journal lost, the crash between the append and the mark, `lane-mail`'s locked check is the judge, and the refused repeat is read back as the envelope that landed and journaled under that id.
- The journal is replayed into memory at start and appended to as the relay works, one fsync per line. The poll count and the compaction day live in `status.json`, which is rewritten every poll, so the journal grows only with deliveries and positions.
- Outbound idempotency is the journal's `out` lines plus two horizons. First, an envelope older than `SLACK_THREAD_DAYS` is never posted, and `compact` drops an `out` line only once the envelope's `at`, journaled on the line, is past that same horizon; `settings.py::Settings.horizon` is the one place it is computed. Second, a start with no journal writes a `start` line at the mailbox's newest envelope and posts nothing at or before it but open asks. `setup` records `bound_at` in the binding, and that start reads Slack from there. The end of a master hold writes a `resume` line that journals a window, from the second of `SLACK_MASTER_FILE`'s mtime the hold's first poll read to when the hold ended, and no notice inside it posts. Neither end comes from what the relay posted, so a gap in its polls, a refused read or a relay down, can post a notice written between the master's first touch and the one the relay read, and never drops one. A notice outside it posts, a refused one retried like any other; a held answer still posts, so the thread of an ask posted before the hold closes and is no longer read every poll.
- The hold is judged once per poll, after the channel is read and its replies sent, before any envelope is posted, from `SLACK_MASTER_FILE`'s mtime against the injected clock; `hold` and `resume` lines are journaled on the transition alone, and `State.held` carries it across a restart. The end of a hold whose file is gone, the last poll that found it fresh, lives in `status.json` beside the poll count.
- A Slack call fails with one of two network keys, by where urllib raised it; `api.py`'s docstring states the rule. Every envelope post Slack refuses is repeated on the next poll, with two exceptions: a lost response (`slack-response-lost`) is journaled `unknown` and never repeated, and a dead token (`slack-auth-failed`) stops the relay. A repeated post fails the poll: `--once` exits 1 and the status row reads `failing` with the error.
- An owner's file is downloaded before its message is delivered, and every download failure becomes a `file <id> not fetched: <why>` line in the message, so no file holds a message back. Slack answers a download the app lacks `files:read` for with its sign-in page and HTTP 200; `api.py::Slack.download` reads an HTML answer whose length is not the size the message's `files[]` entry gives as that page, so an owner's own HTML file is saved and the sign-in page in its place is not, refuses a body shorter than its Content-Length, which http.client reads as a clean end, and refuses a chunked body cut short, whose `HTTPException` no other Slack call catches.
- A receipt mark is a reaction, never a message, and never fails a poll: a refused mark is printed, and a refused mark or swap, or a `drain --receipts` that `lane-mail` refuses, stays pending for the next poll. Every poll marks :eyes: each delivered directive the journal holds no `mark` line for, so a relay stop between the delivery and its mark leaves no directive unmarked; `compact` keeps the `in` and `mark` lines of a directive not yet marked :white_check_mark: whatever their age, so a directive with no `mark` line is still marked once Slack takes the reaction. Whether the overseer has read a directive is `lane-mail drain --receipts`, the verb that reads `to-lane.cursor`; the relay runs it only while an `eyes` mark waits.
- The bot user id comes from `auth.test` at start; a message from that user or from any bot is never routed.
- `SLACK_API_URL` names another API endpoint. The suites point it at the fake; nothing else sets it.

## Tests

```bash
for t in skills/slack/tests/*.test.sh; do bash "$t"; done
```

Each suite starts `tests/lib/fake_slack.py`, a fake Slack Web API with a control surface under `/_test/`, and builds checkouts that link the real orch scripts, so every mailbox write goes through the real `lane-mail`. The assertion library and the fixture builders are `tests/lib/harness.sh`. A control runs a mutant: `sk_mutant` copies `scripts/` and replaces one pattern exactly once.

| Suite | Proves |
|-------|--------|
| `setup.test.sh` | Owner resolution, create-or-find and `--take`, the binding, the invite, the refusals for a partial configuration, an unknown owner, a public channel, an unjoined channel, a dead token, a refused invite and a rebind over a standing journal |
| `listen.test.sh` | Both directions through the real `lane-mail`: the delivery id, the ask closed once, a chat answer and a default in the thread, notices on their ref, a notice on an owner's reply in a thread, the report upload and its thread binding, the non-owner and empty-message replies, an owner's files saved and named, an HTML file saved, a long name cut, a refused download, the sign-in page in place of a PNG and of an HTML file, a file with no download url, a body cut short under its Content-Length or inside a chunk, a whole chunked body saved, the eyes mark swapped for a check once read, a refused mark made on the next poll, a relay stop after the delivery or after its mark, a refused swap, each Slack answer the swap counts as settled and a receipts read `lane-mail` refuses, each form of Slack's markup `markup.py::_token` reads back as typed, catch-up over pages, the crash between append and mark, the second relay refused, two roots on one channel refused, the thread-age horizon, the secret refusal of a text and of a report's file, an unreadable report file, the 429, a refused and a dropped post, a refused history read, the first start's two seeds, the envelope horizon across compaction, a notice under an owner message past the horizon posted once across compaction, a journal reset, and owners re-resolved from the setting |
| `post.test.sh` | Text, `--mention`, `--thread`, `--update`, `--file` with the comment, and the secret-value refusals |
| `compact.test.sh` | Old resolved and ignored lines, old report uploads, an old read directive's receipt marks and superseded positions leave; open asks, an old unread directive and an old directive Slack refused to mark stay, the unmarked one is marked on the next poll, and both swap once read; the relay reads the compacted file; a running relay's lock refuses the verb |
| `status.test.sh` | The doctor row's states and fields, and the budget figure |
| `hold.test.sh` | A fresh `SLACK_MASTER_FILE` holding a notice and an ask while owner messages still land, the hold journaled once and shown as `held-by=master`, the resume posting the open ask and the notices from before and after the hold but none from during it, its line naming the asks that landed and never one Slack refused, whether the file went stale or was removed, a notice written before the touch posting though the relay first saw the hold a poll later or its channel read failed in between, `SLACK_MASTER_MAX_AGE` bounding the hold, an unreadable file refusing the post step alone, an absent file or empty setting posting as before, and compaction of hold and resume lines |
| `install.test.sh` | The unit written or printed, the systemctl calls, a reinstall restarting the running unit on its new roots, `setup` restarting the unit, and the refusals |

The suites run on the `rest` shard of `.github/workflows/skill-tests.yml`, on Linux and macOS.

## Live proof

The rows the fake cannot prove. Each needs the owner's Slack app and channel; a host with no `SLACK_BOT_TOKEN` cannot run them, so each stands pending with the command that proves it.

| Row | Command | State |
|-----|---------|-------|
| The owner writes in the channel and the overseer's notice lands in that thread within a minute | Write top-level; the overseer answers with `lane-mail notice --item overseer --to owner --ref <ID>`; read the thread | pending |
| An ask with an @mention, the reply as the answer, a second reply as a directive | `lane-mail ask --item overseer --to owner --options a,b --recommend a --file q.txt`; reply twice in the thread; `lane-mail events --item overseer` | pending |
| A second ask answered in the chat shows in the thread | `lane-mail resolve --item overseer --id <ASK> --text a.txt`; read the thread | pending |
| A third ask left unanswered proceeds at the deadline with a notice in the thread | `lane-mail ask ... --wait 1`; wait for the watch; read the thread | pending |
| A report lands with its file | `oversee-report write`; read the channel | pending |
| An owner's screenshot lands as a readable path in the directive | Send an image in the channel; `lane-mail events --item overseer`; open the path | pending |
| A directive shows :eyes: within one poll and :white_check_mark: once read, with no bot message | Write top-level; watch the reaction; `lane-mail inbox --item overseer`; watch it swap | pending |
| A forced stall posts one @mention alert to the overseer's channel and the alert channel | `slack post --mention --text "..."` and `slack post --channel <ALERTS> --mention --text "..."` | pending |
| The crash between the mailbox append and the journal mark delivers each note once | kill the relay after a delivery, remove that delivery's `in` line from `tmp/slack/journal.jsonl`, write again, restart; `lane-mail events --item overseer` | pending |
| A second relay on the same checkout is refused | `slack listen --root <checkout> --once` beside the running unit | pending |
| A reply in a thread older than `SLACK_THREAD_DAYS` is not routed | reply under a week-old message; `lane-mail events --item overseer` | pending |
| One answer in chat and one in Slack; a second answer to either is refused and delivered as a directive | `lane-mail resolve ...` then reply in the thread, and the reverse | pending |
| The relay's resident memory under the user slice with three bound checkouts | `systemctl --user status slack-listen.service` after an hour | pending |
| The same on a workstation with a local overseer, token from the private env file | the Setup steps above with `--name kendex-<name>-local` | pending |
| The same for a Codex and a Pi overseer | the Setup steps above in each checkout | pending |
