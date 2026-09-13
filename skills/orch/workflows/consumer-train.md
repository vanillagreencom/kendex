# Consumer train

Run this workflow from the package repository's base checkout. It refreshes subscribed consumer repositories in the configured order.

## 1. Resolve the train

Read the consumer list and the package source commit:

```bash
.agents/skills/orch/scripts/orch-env ORCH_CONSUMER_REPOS ""
git rev-parse HEAD
```

`ORCH_CONSUMER_REPOS` is a space-separated list of absolute base-checkout paths. An empty list ends the workflow. Keep the configured order.

## 2. Refresh each consumer

For each consumer, read its repository instructions and inspect its checkout before writing. Continue only when the path is its base checkout, existing edits can be preserved, and no turn is running Git or kendex there. A lane blocked in a read-only wait is idle.

Record the tracked status, untracked paths, ignore rules, and `.kendex-generated.json` before refresh. Do not overwrite an existing edit.

Run these commands from the consumer checkout:

```bash
kendex refresh --scope project --yes --leave
kendex verify --scope project
```

Inspect the complete refresh diff before committing it. If a new ignore rule would hide a tracked path, report the path, restore the consumer to its pre-refresh state, and do not commit that run. If the refresh leaves `.kendex-generated.json` inventory drift owned by another lane, restore the whole consumer to its pre-refresh state and never commit any file from that run.

Commit only the refresh through the consumer repository's own branch, validation, commit, PR, review, merge, and cleanup path. A refresh or verify failure is not a partial delivery. Preserve its result, restore the consumer to its pre-refresh state, and continue only after that restoration succeeds.

## 3. Record each result

After each consumer, write one JSON record to `tmp/consumer-train-[REPO].json`:

```json
{"repo":"[REPO]","source_sha":"[PACKAGE_SOURCE_SHA]","refresh":"[RESULT]","verify":"[RESULT]","commit_sha":"[SHA_OR_EMPTY]","not_committed_reason":"[REASON_OR_EMPTY]"}
```

Use the consumer's merge commit for `commit_sha`. Record the exact failure or refusal in `not_committed_reason`. One of those fields is empty. Append the file so result text does not cross the command line:

```bash
.agents/skills/orch/scripts/workflow-state append-file oversee consumer_train tmp/consumer-train-[REPO].json
```
