# harness-ci development

Consumer docs: [README.md](README.md). The wiring rules: [SKILL.md](SKILL.md). The classifier this package wraps is change-scope's. Its invariants are in [change-scope's DEVELOPMENT.md](../change-scope/DEVELOPMENT.md).

## Invariants

- `change-class` is a wrapper. It runs change-scope's `change-scope` over the range it was given, and adds what CI alone needs: the queue-only class, the per-push mode and the lane verdicts.
- `aggregate-needs` reads a lane's verdict out of the classifier job's outputs in the results it was handed. The verdict is never a separate argument a workflow could compute wrongly.
- The judged tree's configuration decides nothing. `change-class` reads the repository's queue list, selector and per-push reason, `HARNESS_CI_QUEUE_PATHS`, `HARNESS_CI_QUEUE_SELECTOR` and `HARNESS_CI_PER_PUSH_REASON`, from the `[env]` tables of the settings files the commit `--base` names holds, through change-scope's `base_settings`. It never reads them from the judged tree or the caller's environment, which the wrapper unsets first. That commit is the pull request's base end [references/wiring.md § The endpoint expressions](references/wiring.md#the-endpoint-expressions) names or a merge group's base, never the merge base, which the author picks by choosing where to fork.
- The queue selector is the one command `change-class` runs out of a repository.
  - It runs the base commit's copy in a private checkout of that commit, made as the render proof's checkout is, never the judged tree's. The branch under judgement can neither name the command nor change what it runs, while a change to the selector itself is judged by the copy it replaces.
  - It is asked only on `pull_request` and `merge_group`, the events whose merge route it decides.
  - It is asked only where every path rule read `queue_only=false`, at the verdict, because the jobs a merge group runs can depend on the class.
- `HARNESS_CI_UNREAD_PATHS` is a base-only key too: `change-class` drops it from its environment and reads it from the `[env]` tables of the commit `--base` names alone.

## Tests

`tests/` runs in kendex CI on every change to this repository.

- Run one suite locally with `bash skills/harness-ci/tests/queue-only.test.sh`.
- The suites source change-scope's `tests/lib/sandbox.sh`, which lays out both packages.
- The classifier's own suites, the real-kendex rows among them, are change-scope's. [Its DEVELOPMENT.md](../change-scope/DEVELOPMENT.md) names them.
- change-scope's `absence` suite holds the refusal at startup when change-scope is absent beside this package.
- `tests/lib/workflow.sh` reads a workflow's job conditions, needs, names and triggers, and plants a defect in a copy. It runs `tests/lib/gh-eval.py`, which evaluates the conditions, through `gh_eval`, which turns a refusal into an answer no row expects. kendex's `tools/tests/ci-aggregate.test.sh` reads its own `skill-tests.yml` with the same two files.
