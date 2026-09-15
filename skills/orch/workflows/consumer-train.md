# Consumer train

Run this workflow from the package repository's base checkout. It refreshes subscribed consumer repositories in the configured order.

## 1. Resolve the train

Bind the package root, its Git remote identity, the fleet state directory, and the consumer list before entering a consumer checkout:

```bash
git rev-parse --show-toplevel
[PACKAGE_ROOT]/.agents/skills/orch/scripts/orch-env ORCH_STATE_DIR tmp
[PACKAGE_ROOT]/.agents/skills/orch/scripts/orch-env ORCH_CONSUMER_REPOS ""
```

Set `PACKAGE_ROOT` to the first result. Require a repository-backed Git remote for that checkout; a local or path-only source cannot supply the required source SHA and stops the train before consumer writes. Normalize the remote as `PACKAGE_SOURCE_REPO`: owner/repo, HTTPS, and SSH GitHub spellings fold to lowercase `github.com/owner/repo`; other remotes drop a trailing slash or `.git` and lowercase only the scheme and host. Set `FLEET_STATE_DIR` to the second command's result. Resolve a relative state directory under `PACKAGE_ROOT` and keep its absolute path. `ORCH_CONSUMER_REPOS` is a space-separated list of absolute base-checkout paths. An empty list ends the workflow. Keep the configured order. Bind `MERGED_RANGE` from the caller: the merge range [oversee.md](oversee.md) § 3 classified as shipped paths. A run given no range cannot name bundle-member changes and records that in § 4.

## 2. Name bundle-member changes

Diff the package manifest's `[bundles.*]` member lists over `MERGED_RANGE` (`git -C [PACKAGE_ROOT] diff [MERGED_RANGE] -- kendex.toml`). For each member added to or removed from a bundle, name the consumers whose manifests enumerate that bundle's members: such a manifest declares the members one by one and names no `[bundles.<name>]` table, so `kendex refresh` reads only what is declared there and never adds the new member or drops the removed one. Each of those consumers needs the added member declared by hand, with the source and harnesses the bundle gives it, and the removed member's declaration deleted. With no added or removed member the train refreshes only.

## 3. Refresh each consumer

For each consumer, read its repository instructions and inspect its checkout before writing. Continue only when the path is its base checkout, its index and worktree are clean, and no turn is running Git or kendex there. A lane blocked in a read-only wait is idle.

Enter the consumer repository's ordinary task branch through its own instructions while the base checkout is clean. Never refresh from a linked worktree. Record the tracked status, untracked paths, ignore rules, and `.kendex-generated.json` after entering the branch and before refresh. Replace `[PACKAGE_ROOT]/tmp/consumer-train-lock-existed` with whether `.kendex-lock.json` exists. When it does, copy its exact bytes to `[PACKAGE_ROOT]/tmp/consumer-train-lock-snapshot`.

Run these commands from the same consumer base checkout:

```bash
kendex refresh --scope project --yes --leave
kendex verify --scope project
```

When refresh or verify fails on a line ending `update-pi must settle it`, run `kendex update-pi --scope global` for a global-scope line or `kendex update-pi --scope project` for a project-scope line in the same checkout, then run refresh and verify again. That second result is the one this workflow records.

After refresh, read the consumer project's `.kendex-lock.json`. Match refreshed shipped-package entries to their `sources` rows by source name. Normalize each source row's `repo` by the same rule as `PACKAGE_SOURCE_REPO`, then keep matching rows. Require exactly one distinct non-empty `commit`, and use it as `PACKAGE_SOURCE_SHA`. If the lock is missing, unreadable, or cannot identify exactly one such commit, record that exact refusal, restore the consumer to its pre-refresh state, and do not commit.

Inspect the complete refresh diff before committing it. If a new ignore rule would hide a tracked path, report the path, restore the consumer to its pre-refresh state, and do not commit that run. If the refresh leaves `.kendex-generated.json` inventory drift owned by another lane, restore the whole consumer to its pre-refresh state and never commit any file from that run.

Every restoration restores the saved `.kendex-lock.json` bytes when the lock existed before refresh. It removes the lock when refresh created it.

Commit the manifest edits § 2 named for this consumer as their own commit beside the refresh commit, and commit nothing else, through the consumer repository's own branch, validation, commit, PR, review, merge, and cleanup path. A refresh or verify failure is not a partial delivery. Preserve its result, restore the consumer to its pre-refresh state, and continue only after that restoration succeeds.

## 4. Record each result

After each consumer, write or replace `[PACKAGE_ROOT]/tmp/consumer-train-record.json` with one record. The `repo` field holds the full absolute consumer path:

```json
{"repo":"[ABSOLUTE_CONSUMER_PATH]","source_sha":"[PACKAGE_SOURCE_SHA]","refresh":"[RESULT]","verify":"[RESULT]","commit_sha":"[SHA_OR_EMPTY]","bundle_members":"[ADDED_AND_REMOVED_DECLARATIONS_OR_EMPTY]","not_committed_reason":"[REASON_OR_EMPTY]"}
```

Use the consumer's merge commit for `commit_sha`. Record in `bundle_members` what § 2 named for this consumer and the commit that carried it, `none` when nothing was named, or `no merged range` when § 1 bound none. Record the exact failure or refusal in `not_committed_reason`. One of those fields is empty. Append the file so result text does not cross the command line:

```bash
[PACKAGE_ROOT]/.agents/skills/orch/scripts/workflow-state --state-dir [FLEET_STATE_DIR] append-file oversee consumer_train [PACKAGE_ROOT]/tmp/consumer-train-record.json
```

Append each record before replacing the file for the next consumer.
