# Consumer train

Run this workflow from the package repository's base checkout. On a hosted fleet it does not run: the train is item work under [SKILL.md](../SKILL.md) § The Cycle, Item work stays in lanes, and the `merged` event in [oversee-events.md § Event kinds](../references/oversee-events.md#event-kinds) says what the overseer does instead. It refreshes every subscribed repository that `ORCH_CONSUMER_REPOS` or `kendex project list` names.

## 1. Resolve the train

Every command this workflow runs must exit 0, unless a section states how it reads that command's failure; § 3 does so for refresh, verify, the writer re-adoption and `kendex check --quiet`, and no other section does. Any other non-zero exit, and any command that does not run, stops the train before consumer writes. Record the command and its output in § 4's record under `not_committed_reason` for a consumer step, or report it from the run for a § 1 step.

Bind the package root, its Git remote identity, the fleet state directory, and the candidate paths before entering a consumer checkout:

```bash
git rev-parse --show-toplevel
[PACKAGE_ROOT]/.agents/skills/orch/scripts/orch-env ORCH_STATE_DIR tmp
[PACKAGE_ROOT]/.agents/skills/orch/scripts/orch-env ORCH_CONSUMER_REPOS ""
kendex project list
```

Set `PACKAGE_ROOT` to the first result. Require a repository-backed Git remote for that checkout; a local or path-only source cannot supply the required source SHA and stops the train before consumer writes. Normalize the remote as `PACKAGE_SOURCE_REPO`: owner/repo, HTTPS, and SSH GitHub spellings fold to lowercase `github.com/owner/repo`; other remotes drop a trailing slash or `.git` and lowercase only the scheme and host. Set `FLEET_STATE_DIR` to the second command's result. Resolve a relative state directory under `PACKAGE_ROOT` and keep its absolute path. Bind `MERGED_RANGE` from the caller: the merge range [oversee-events.md § Event kinds](../references/oversee-events.md#event-kinds) classified as shipped paths and hands to this workflow. A run given no range cannot name bundle-member changes and records that in § 4.

### 1.1 Select the consumers

`ORCH_CONSUMER_REPOS` is a space-separated list of absolute base-checkout paths. It fixes the refresh order, not the membership: a repository it omits still rides the train. Take the candidate paths from that list and from every `kendex project list` row whose path carries no parenthesised note. Drop `PACKAGE_ROOT`. Drop a path whose `git -C [PATH] rev-parse --git-dir` and `git -C [PATH] rev-parse --git-common-dir` disagree, which is a linked worktree and never a base checkout. Drop repeats.

Run `kendex source list --scope project` in each surviving candidate. Keep the candidate when one row that carries no `(switched off)` note holds a reference that normalizes to `PACKAGE_SOURCE_REPO` under the rule above; that repository subscribes to this package. Refresh the kept repositories in `ORCH_CONSUMER_REPOS` order first, then the rest in the order `kendex project list` printed them. An empty kept set ends the workflow.

A subscribed repository in neither enumeration is outside the train. `kendex project add [PATH]` puts it in.

## 2. Name bundle-member changes

Diff the package manifest's `[bundles.*]` member lists over `MERGED_RANGE` (`git -C [PACKAGE_ROOT] diff [MERGED_RANGE] -- kendex.toml`). For each member added to or removed from a bundle, name the consumers whose manifests enumerate that bundle's members as it listed them at the start of `MERGED_RANGE`: such a manifest declares the members one by one and names no `[bundles.<name>]` table, so `kendex refresh` reads only what is declared there and never adds the new member or drops the removed one. Each of those consumers needs the added member declared by hand, with the source and harnesses the bundle gives it, and the removed member's declaration deleted. Name a removed member for deletion only when no other bundle whose members that consumer enumerates still lists it at the range's end. With no added or removed member the train refreshes only.

## 3. Refresh each consumer

For each consumer, read its repository instructions and inspect its checkout before writing. Continue only when the path is its base checkout, its index and worktree are clean, and no turn is running Git or kendex there. A lane blocked in a read-only wait is idle.

Enter the consumer repository's ordinary task branch through its own instructions while the base checkout is clean. Never refresh from a linked worktree. Record the tracked status, untracked paths, ignore rules, and `.kendex-generated.json` after entering the branch and before refresh. Replace `[PACKAGE_ROOT]/tmp/consumer-train-lock-existed` with whether `.kendex-lock.json` exists. When it does, copy its exact bytes to `[PACKAGE_ROOT]/tmp/consumer-train-lock-snapshot`.

After that record, apply the § 2 manifest edits for this consumer, so refresh renders the added member and drops the removed one and verify covers the edited manifest.

Run these commands from the same consumer base checkout:

```bash
kendex refresh --scope project --yes --leave
kendex verify --scope project
```

When refresh or verify fails on a line ending `update-pi must settle it`, run `kendex update-pi --scope global` for a global-scope line or `kendex update-pi --scope project` for a project-scope line in the same checkout, then run refresh and verify again. That second result is the one this workflow records.

When `git -C [PACKAGE_ROOT] diff --name-only [MERGED_RANGE] -- skills/review-gate/templates/` names a path, or § 1 bound no range, and the refreshed consumer has an executable `.agents/skills/review-gate/scripts/validate-workflow.sh`, re-adopt the review-gate writer template from the same checkout:

```bash
.agents/skills/review-gate/scripts/validate-workflow.sh --adopt
```

It re-installs the new template over the consumer's writer workflow when that copy equals an earlier shipped version, so the render pull request carries both and the consumer's review-gate validate check stays green. Its write is part of the refresh diff and commits with it. Exit 0 continues. Exit 2, and exit 1 with a `FAIL check=workflow-edited` line, fail this consumer as a refresh failure does: that line names a copy a person edited, which a person in the consumer re-copies by hand. Exit 1 without that line reports the consumer's own standing findings, a consumer with no adopted writer among them, and continues.

After refresh, read the consumer project's `.kendex-lock.json`. Match refreshed shipped-package entries to their `sources` rows by source name. Normalize each source row's `repo` by the same rule as `PACKAGE_SOURCE_REPO`, then keep matching rows. Require exactly one distinct non-empty `commit`, and use it as `PACKAGE_SOURCE_SHA`. If the lock is missing, unreadable, or cannot identify exactly one such commit, record that exact refusal, restore the consumer to its pre-refresh state, and do not commit.

Inspect the complete refresh diff before committing it. If a new ignore rule would hide a tracked path, report the path, restore the consumer to its pre-refresh state, and do not commit that run. If the refresh leaves `.kendex-generated.json` inventory drift owned by another lane, restore the whole consumer to its pre-refresh state and never commit any file from that run.

Every restoration reverts the § 2 manifest edits and restores the saved `.kendex-lock.json` bytes when the lock existed before refresh. It removes the lock when refresh created it.

When § 2 named manifest edits for this consumer, commit them first as their own commit and the refresh second; otherwise commit only the refresh. Commit nothing else, and commit through the consumer repository's own branch, validation, commit, PR, review, merge, and cleanup path. A refresh or verify failure is not a partial delivery. Preserve its result, restore the consumer to its pre-refresh state, and continue only after that restoration succeeds.

Once that path has settled, whether it committed or restored, run `kendex check --quiet` in the consumer base checkout:

```bash
kendex check --quiet
```

Read that command's exit status before its report. A command that failed to execute at all, and an exit status of 2, both fail the train outright: the first prints no report and the second says the check could not evaluate at least one line, so neither establishes the consumer's state. Exit 0 is clean. Only on exit 1 read the report: the consumer is clean when it names no line under its `stale:` section and none under its `blocked by files already there:` section. Any line under either one fails the train, and so does a `… report truncated` line, which drops whole sections from the end and can hide either. A line under another exit-1 section, `not yet evaluated:` among them, does not fail the train. On a failure, record the result in § 4 and stop the train before the next consumer.

## 4. Record each result

After each consumer, write or replace `[PACKAGE_ROOT]/tmp/consumer-train-record.json` with one record. The `repo` field holds the full absolute consumer path:

```json
{"repo":"[ABSOLUTE_CONSUMER_PATH]","source_sha":"[PACKAGE_SOURCE_SHA]","refresh":"[RESULT]","verify":"[RESULT]","check":"[CLEAN_OR_FAILING_LINES]","commit_sha":"[SHA_OR_EMPTY]","bundle_members":"[NAMED_DECLARATIONS_WITH_COMMIT|NAMED_DECLARATIONS_NOT_COMMITTED|none|no merged range]","not_committed_reason":"[REASON_OR_EMPTY]"}
```

`check` holds `clean` when § 3's `kendex check --quiet` exited 0, or exited 1 with no failing line under the sections § 3 selects. Otherwise it holds the text that failed the train: the failing lines with the section titles they sat under, or the `could not check:` lines on exit 2, or the execution error text when the command did not run. Use the consumer's merge commit for `commit_sha`, or record the exact failure or refusal in `not_committed_reason`; exactly one of those two fields is empty. `bundle_members` is never empty and holds one of: the declarations § 2 named for this consumer with the commit that carried them; those declarations marked `not committed` when no commit carried them, the cause staying in `not_committed_reason`; `none` when § 2 named nothing for this consumer; or `no merged range` when § 1 bound none. Append the file so result text does not cross the command line:

```bash
[PACKAGE_ROOT]/.agents/skills/orch/scripts/workflow-state --state-dir [FLEET_STATE_DIR] append-file oversee consumer_train [PACKAGE_ROOT]/tmp/consumer-train-record.json
```

Append each record before replacing the file for the next consumer.
