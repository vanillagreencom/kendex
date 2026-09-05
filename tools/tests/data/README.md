# Bash compatibility fixtures

The [compatibility test](../bash32-lint.test.sh) reads these text files to check [bash32-lint](../../bash32-lint). It does not execute their contents.

| File | Purpose |
|---|---|
| [bash32-probes.txt](bash32-probes.txt) | Bash constructs the checker must reject. Include each spelling the pattern accepts. |
| [bash32-controls.txt](bash32-controls.txt) | Valid Bash source the checker must accept. |
| [bash32-uncatchable.txt](bash32-uncatchable.txt) | Unsupported constructs the text patterns cannot detect. |
| [bash32-overflagged.txt](bash32-overflagged.txt) | Valid source the text patterns reject. |

The test checks the accepted limitations as well as the rejection cases. Update the applicable fixtures when a pattern changes.
