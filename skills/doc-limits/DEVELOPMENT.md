# doc-limits development

## Tests

From the package root, run a suite with Bash:

```bash
bash tests/staged-scope.test.sh
```

Run the other suites under `tests/` the same way. The repository's skill-test CI job discovers the package's suites.

## Debug

Read [references/policy.md](references/policy.md) when debugging class selection or exclusions. `scripts/doc-limits` owns collection and measurement. `scripts/lib/settings.sh` owns settings and staged-policy resolution. The shared inventory reader is the commit-guards package's `scripts/lib/generated-paths.sh`.
