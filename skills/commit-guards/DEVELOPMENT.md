# commit-guards development

Check contracts: [CHECKS.md](CHECKS.md). Consumer setup: [README.md](README.md). Hook order, settings and refusal boundaries: [hooks and settings](references/hooks-and-settings.md).

## Test

Run a suite directly with Bash, for example:

```bash
bash skills/commit-guards/tests/install-git-hooks-check.test.sh
bash skills/commit-guards/tests/terminal-paths.test.sh
```

New suites source `tests/lib/harness.bash` immediately after their shell options. It isolates Git configuration and scratch files so the invoking repository's hooks, templates and identity do not decide fixture results. Installer fixtures use `tests/lib/install-hooks.bash`.

## Git hook install contract

Before diagnosing an installation, read `scripts/install-git-hooks --help`. It owns install, repair, removal and read-only check results, including `core.hooksPath` and linked-worktree limits. Run installation cases in fixture repositories, not against the developer's own hooks.

When changing the installer, use `tests/install-git-hooks-check.test.sh` for the status predicate and `tests/lib/install-hooks.bash` for shared fixtures. Inspect `scripts/lib/helper-body.sh` and `scripts/lib/hook-check.sh` together: the installed helper's bytes and the checker that accepts them must agree. Keep the helper's stamp check and byte check distinct; a current stamp alone does not prove the helper matches.

## The pre-push lane

Before investigating a push refusal, read [Pre-push scope](references/hooks-and-settings.md#pre-push-scope). It states which refs and scopes are judged and the limits of local tracking-ref evidence. `scripts/pre-push` owns ref collection; `scripts/commit-guards` owns check selection. Inspect those owners instead of inferring push coverage from a successful commit.

## Markdown checks

When changing Markdown parsing, inspect the shared block and shape parsers in `scripts/lib/md-blocks.awk` and `scripts/lib/md-shapes.awk` before changing an individual lane. Their callers run POSIX awk under `LC_ALL=C`. Keep portability checks against that dialect.

Use `tests/md-type.test.sh` to check the shipped docs-writing route contract, `tests/md-refs.test.sh` for reference resolution and `tests/md-reflow.test.sh` for reflow and fixed-point checks. These suites exercise different guarantees; a passing reflow check does not establish that references resolve.

## Probing a terminal-only code path

A headless test cannot prove a branch reached only at a terminal. For example, a replacement of a write-denied file can prompt there. Use `gg_pty_run CAP SCRIPT_FILE` from `tests/lib/pty.bash`; `tests/terminal-paths.test.sh` is the worked example. Source the shared harness first.

- Assert the effect of the operation as well as `GG_PTY_STATE=ok`, which establishes that the probe ran. The helper's state and result fields are documented beside `gg_pty_run`.
- Print and require a marker before the call so a negative result proves the code was entered.
- Check the permission premise inside the session: mode `0444` does not restrict euid 0.
- Keep stdin at `/dev/null`, so a prompt receives EOF rather than waiting for a person.
- Keep both caller and session deadlines. A suite that stops must not leave its session running.
- Use the helper's environment values for its paths. Quote any path embedded in the Bash session body with `%q`, and set `LC_ALL=C` there.

An unavailable terminal spawner leaves the probe unperformed. Preserve its diagnostic instead of treating the result as a skip or a clean measurement.
