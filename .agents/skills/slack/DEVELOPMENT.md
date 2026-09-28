# slack development

Maintainer notes. Consumer docs: [README.md](README.md); the agent contract: [SKILL.md](SKILL.md); why the package is shaped this way: kendex decision D009.

## Layout

- `scripts/slack`: the Bash launcher. It loads the checkout's settings through the orch skill's `kendex-env.sh`, checks for Python 3.8 and the orch install, names that install in `SLACK_ORCH_DIR`, and execs `scripts/lib/main.py`.
- `scripts/lib/main.py`: argv to one verb; `verbs.py` holds setup, post, compact, install and status; `relay.py` the listener.
- `scripts/lib/api.py`: the Slack Web API client, `mailbox.py` the `lane-mail` calls, `store.py` the binding, journal, status record and lock, `secret.py` the secret-value check, `settings.py` the environment, `refusals.py` every keyed line and its explanation.
- `systemd/slack-listen.service`: the unit template `install` fills.
- The orch skill must be installed beside this package: the launcher sources `../orch/scripts/lib/kendex-env.sh` and is the one place that spells the location, which `secret.py` reads from `SLACK_ORCH_DIR` for `references/secret-value.ere`. Each root's `.agents/skills/orch/scripts/lane-mail` is that root's mailbox.

## Constraints

- The relay keys every inbound delivery `channel:ts` and hands the key to `lane-mail`. Its journal skips a stamp it already carried; for a stamp the journal lost, the crash between the append and the mark, `lane-mail`'s locked check is the judge, and the refused repeat is read back as the envelope that landed and journaled under that id.
- The journal is replayed into memory at start and appended to as the relay works, one fsync per line. The poll count and the compaction day live in `status.json`, which is rewritten every poll, so the journal grows only with deliveries and positions.
- Outbound idempotency is the journal's `out` lines plus two horizons. First, an envelope older than `SLACK_THREAD_DAYS` is never posted, and `compact` drops an `out` line only once the envelope's `at`, journaled on the line, is past that same horizon; `settings.py::Settings.horizon` is the one place it is computed. Second, a start with no journal writes a `start` line at the mailbox's newest envelope and posts nothing at or before it but open asks. `setup` records `bound_at` in the binding, and that start reads Slack from there.
- A Slack call fails with one of two network keys, by where urllib raised it; `api.py`'s docstring states the rule. Every envelope post Slack refuses is repeated on the next poll, with two exceptions: a lost response (`slack-response-lost`) is journaled `unknown` and never repeated, and a dead token (`slack-auth-failed`) stops the relay. A repeated post fails the poll: `--once` exits 1 and the status row reads `failing` with the error.
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
| `listen.test.sh` | Both directions through the real `lane-mail`: the delivery id, the ask closed once, a chat answer and a default in the thread, notices on their ref, a notice on an owner's reply in a thread, the report upload and its thread binding, the non-owner and file-alone replies, catch-up over pages, the crash between append and mark, the second relay refused, two roots on one channel refused, the thread-age horizon, the secret refusal of a text and of a report's file, an unreadable report file, the 429, a refused and a dropped post, a refused history read, the first start's two seeds, the envelope horizon across compaction, a notice under an owner message past the horizon posted once across compaction, a journal reset, and owners re-resolved from the setting |
| `post.test.sh` | Text, `--mention`, `--thread`, `--update`, `--file` with the comment, and the secret-value refusals |
| `compact.test.sh` | Old resolved and ignored lines, old report uploads and superseded positions leave; open asks stay; the relay reads the compacted file; a running relay's lock refuses the verb |
| `status.test.sh` | The doctor row's states and fields, and the budget figure |
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
| A forced stall posts one @mention alert to the overseer's channel and the alert channel | `slack post --mention --text "..."` and `slack post --channel <ALERTS> --mention --text "..."` | pending |
| The crash between the mailbox append and the journal mark delivers each note once | kill the relay after a delivery, remove that delivery's `in` line from `tmp/slack/journal.jsonl`, write again, restart; `lane-mail events --item overseer` | pending |
| A second relay on the same checkout is refused | `slack listen --root <checkout> --once` beside the running unit | pending |
| A reply in a thread older than `SLACK_THREAD_DAYS` is not routed | reply under a week-old message; `lane-mail events --item overseer` | pending |
| One answer in chat and one in Slack; a second answer to either is refused and delivered as a directive | `lane-mail resolve ...` then reply in the thread, and the reverse | pending |
| The relay's resident memory under the user slice with three bound checkouts | `systemctl --user status slack-listen.service` after an hour | pending |
| The same on a workstation with a local overseer, token from the private env file | the Setup steps above with `--name kendex-<name>-local` | pending |
| The same for a Codex and a Pi overseer | the Setup steps above in each checkout | pending |
