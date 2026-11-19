# Mailbox development

Consumer docs: [README.md](README.md). The agent contract: [SKILL.md](SKILL.md).

## Tests

```bash
bash skills/orch/tests/run-all.sh --battery skills/mailbox/tests
```

The `tests/lane-mail*.sh` suites test the `lane-mail` program. `tests/file-lock-messages.sh` tests its lock library. Each suite sources its assertion and fixture libraries from `skills/orch/tests/lib/` by repository path. The mailbox's own test libraries are under `tests/lib/`, and its fixtures under `tests/fixtures/`.
