# Mailbox development

## Tests

```bash
bash skills/orch/tests/run-all.sh --battery skills/mailbox/tests
```

Each suite sources its assertion and fixture libraries from `skills/orch/tests/lib/` by repository path, so the suites run only from the catalog checkout.
