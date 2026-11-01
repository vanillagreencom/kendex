# Test fixtures

## Bash compatibility

The [compatibility test](../bash32-lint.test.sh) reads these text files to check [bash32-lint](../../bash32-lint). It does not execute their contents.

| File | Purpose |
|---|---|
| [bash32-probes.txt](bash32-probes.txt) | Bash constructs the checker must reject. Include each spelling the pattern accepts. |
| [bash32-controls.txt](bash32-controls.txt) | Valid Bash source the checker must accept. |
| [bash32-uncatchable.txt](bash32-uncatchable.txt) | Unsupported constructs the text patterns cannot detect. |
| [bash32-overflagged.txt](bash32-overflagged.txt) | Valid source the text patterns reject. |

The test checks the accepted limitations as well as the rejection cases. Update the applicable fixtures when a pattern changes.

## Main-push proof

The [CI event selection test](../ci-class-job-set-events.test.sh) serves two recorded GitHub responses to `tools/ci-job-set`'s push route through a `gh` stub, as trimmed copies of the real responses:

| File | Purpose |
|---|---|
| [main-proof-runs.json](main-proof-runs.json) | The merge-group run list for head `43b6b58b`, run 41306604685. |
| [main-proof-jobs.json](main-proof-jobs.json) | That run's latest jobs, every shard leg among them. |
