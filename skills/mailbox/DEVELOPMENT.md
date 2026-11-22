# Mailbox development

## Tests

Run these from the repository root:

1. Build the runtimes with `skills/orch/scripts/setup`.
2. Export `AGENT_RUNTIME_CACHE` at the cache that setup built: `export AGENT_RUNTIME_CACHE="$(bash -c '. "$1"; agent_runtime_cache' _ skills/agent-runtime/scripts/lib/key.sh)"`.
3. Run the suites:

   ```bash
   bash skills/orch/tests/run-all.sh --battery skills/mailbox/tests
   ```

## Writers

Every mailbox writer uses `scripts/lib/file-lock.sh` and `scripts/lib/mailbox-append.sh`.
