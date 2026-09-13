# Consumer train

Run this workflow from the package repository's base checkout. It refreshes subscribed consumer repositories in the configured order.

## 1. Resolve the train

Bind the package root, fleet state directory, consumer list, and package source commit before entering a consumer checkout:

```bash
git rev-parse --show-toplevel
[PACKAGE_ROOT]/.agents/skills/orch/scripts/orch-env ORCH_STATE_DIR tmp
[PACKAGE_ROOT]/.agents/skills/orch/scripts/orch-env ORCH_CONSUMER_REPOS ""
git -C [PACKAGE_ROOT] rev-parse HEAD
```

Set `PACKAGE_ROOT` to the first result. Set `FLEET_STATE_DIR` to the second result. Resolve a relative state directory under `PACKAGE_ROOT` and keep its absolute path. `ORCH_CONSUMER_REPOS` is a space-separated list of absolute base-checkout paths. An empty list ends the workflow. Keep the configured order.

## 2. Refresh each consumer

For each consumer, read its repository instructions and inspect its checkout before writing. Continue only when the path is its base checkout, its index and worktree are clean, and no turn is running Git or kendex there. A lane blocked in a read-only wait is idle.

Enter the consumer repository's ordinary task branch through its own instructions while the base checkout is clean. Never refresh from a linked worktree. Record the tracked status, untracked paths, ignore rules, and `.kendex-generated.json` after entering the branch and before refresh.

Run these commands from the same consumer base checkout:

```bash
kendex refresh --scope project --yes --leave
kendex verify --scope project
```

Inspect the complete refresh diff before committing it. If a new ignore rule would hide a tracked path, report the path, restore the consumer to its pre-refresh state, and do not commit that run. If the refresh leaves `.kendex-generated.json` inventory drift owned by another lane, restore the whole consumer to its pre-refresh state and never commit any file from that run.

Commit only the refresh through the consumer repository's own branch, validation, commit, PR, review, merge, and cleanup path. A refresh or verify failure is not a partial delivery. Preserve its result, restore the consumer to its pre-refresh state, and continue only after that restoration succeeds.

## 3. Record each result

After each consumer, write or replace `[PACKAGE_ROOT]/tmp/consumer-train-record.json` with one record. The `repo` field holds the full absolute consumer path:

```json
{"repo":"[ABSOLUTE_CONSUMER_PATH]","source_sha":"[PACKAGE_SOURCE_SHA]","refresh":"[RESULT]","verify":"[RESULT]","commit_sha":"[SHA_OR_EMPTY]","not_committed_reason":"[REASON_OR_EMPTY]"}
```

Use the consumer's merge commit for `commit_sha`. Record the exact failure or refusal in `not_committed_reason`. One of those fields is empty. Append the file so result text does not cross the command line:

```bash
[PACKAGE_ROOT]/.agents/skills/orch/scripts/workflow-state --state-dir [FLEET_STATE_DIR] append-file oversee consumer_train [PACKAGE_ROOT]/tmp/consumer-train-record.json
```

Append each record before replacing the file for the next consumer.
