# Mailbox development

## Tests

```bash
bash skills/orch/tests/run-all.sh --battery skills/mailbox/tests
```

## Writers

Every mailbox writer uses `scripts/lib/file-lock.sh` and `scripts/lib/mailbox-append.sh`.
