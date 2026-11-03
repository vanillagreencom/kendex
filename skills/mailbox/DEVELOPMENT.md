# Mailbox development

Maintainer notes. Consumer docs: [README.md](README.md); the agent contract: [SKILL.md](SKILL.md).

## Tests

```bash
bash skills/orch/tests/run-all.sh --battery skills/mailbox/tests
```

The six `tests/lane-mail*.sh` suites and `tests/file-lock-messages.sh` test the `lane-mail` program and its lock library from here. Every suite sources its assertion and fixture libraries from `skills/orch/tests/lib/` by repository path; the mailbox's own test libraries and fixtures are under `tests/lib/` and `tests/fixtures/`.
