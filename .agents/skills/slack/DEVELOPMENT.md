# slack development

Maintainer notes. Consumer docs: [README.md](README.md); the agent contract: [SKILL.md](SKILL.md); why the package is shaped this way: kendex decision D008.

## Layout

- `scripts/slack`: the Bash launcher. It loads the checkout's settings through the orch skill's `kendex-env.sh`, checks for Python 3.8 and the orch install, and execs `scripts/lib/main.py`.
- `scripts/lib/main.py`: argv to one verb; `verbs.py` holds setup, post, compact, install and status; `relay.py` the listener.
- `scripts/lib/api.py`: the Slack Web API client, `mailbox.py` the `lane-mail` calls, `store.py` the binding, journal, status record and lock, `secret.py` the secret-value check, `settings.py` the environment, `refusals.py` every keyed line and its explanation.
- `systemd/slack-listen.service`: the unit template `install` fills.
- The orch skill must be installed beside this package: the launcher sources `../orch/scripts/lib/kendex-env.sh`, `secret.py` reads `../orch/references/secret-value.ere`, and each root's `.agents/skills/orch/scripts/lane-mail` is the mailbox.

## Constraints

- The relay keys every inbound delivery `channel:ts` and hands the key to `lane-mail`; it keeps no pre-check of its own. A refused repeat is read back as the envelope that landed, and journaled under that id.
- The journal is replayed into memory at start and appended to as the relay works, one fsync per line. The poll count and the compaction day live in `status.json`, which is rewritten every poll, so the journal grows only with deliveries and positions.
- The bot user id comes from `auth.test` at start; a message from that user or from any bot is never routed.
- `SLACK_API_URL` names another API endpoint. The suites point it at the fake; nothing else sets it.

## Tests

```bash
for t in skills/slack/tests/*.test.sh; do bash "$t"; done
```

Each suite starts `tests/lib/fake_slack.py`, a fake Slack Web API with a control surface under `/_test/`, and builds checkouts that link the real orch scripts, so every mailbox write goes through the real `lane-mail`. The assertion library and the fixture builders are `tests/lib/harness.sh`. A control runs a mutant: `sk_mutant` copies `scripts/` and replaces one pattern exactly once.

| Suite | Proves |
|-------|--------|
| `setup.test.sh` | Owner resolution, create-or-find and `--take`, the binding, the invite, the refusals for a partial configuration, an unknown owner, an unjoined channel and a dead token |
| `listen.test.sh` | Both directions through the real `lane-mail`: the delivery id, the ask closed once, a chat answer and a default in the thread, notices on their ref, the report upload and its thread binding, the non-owner and file-alone replies, catch-up over pages, the crash between append and mark, the second relay refused, the thread-age horizon, the secret refusal, the 429, and owners re-resolved from the setting |
| `post.test.sh` | Text, `--mention`, `--thread`, `--update`, `--file` with the comment, and the secret-value refusals |
| `compact.test.sh` | Old resolved and ignored lines and superseded positions leave; open asks stay; the relay reads the compacted file |
| `status.test.sh` | The doctor row's states and fields, and the budget figure |
| `install.test.sh` | The unit written or printed, the systemctl calls, `setup` restarting the unit, and the refusals |

The suites run on the `rest` shard of `.github/workflows/skill-tests.yml`, on Linux and macOS.
