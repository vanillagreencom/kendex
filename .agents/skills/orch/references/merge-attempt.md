# Merge attempt

Load from [merge-pr.md § 5 step 1](../workflows/merge-pr.md#5-execute-the-merge). Section and step numbers below refer to that workflow. Keep its prepared head, endpoint command, gate mode and stop rules.

## Direct attempt

**The direct attempt** follows a CI wait on the PR, on every entry to it, since the immediate merge refuses a pending check. Read the pull request's merge state before the wait, since a conflicting pull request registers no check:

```bash
env -u GH_REPO -u GITHUB_REPOSITORY [MAIN_REPO_ROOT]/.agents/skills/github/scripts/github.sh -C [MAIN_REPO_ROOT] pr-merge [PR_NUMBER] --check
```

Its JSON's `mergeable` routes first. `CONFLICTING` ends the attempt before any wait: put `[PREPARED_HEAD]` and the word `conflict` in `## Merge decision` by § Record the merge decision, with no route line, then take merge-pr.md § 5 step 1's Restack cycle; a conflict never takes the pending budget below and never ci-fix. `MERGEABLE` and `UNKNOWN`, which GitHub answers while it still computes mergeability, go on to the wait.

The wait is the runtime's `verify-pr` operation over the pull request's current head, run through [Waiter launch](waiter-launch.md) and repeated no more often than every 180 seconds while `result.status` is `pending` or `unreadable`, within the lane's CI budget `CI_WAIT_MAX_SECS`; `[OWNER/REPO]` is the repository as merge-pr.md § 5 step 1's `gh repo view --json nameWithOwner` answers it:

```bash
jq -cn --arg repo "[OWNER/REPO]" --argjson pr [PR_NUMBER] \
  '{op: "verify-pr", repo: $repo, pr: $pr, required_only: true}' \
  > "[MAIN_REPO_ROOT]/tmp/verify-pr-request-[STATE_KEY].json"
[MAIN_REPO_ROOT]/.agents/skills/orch/scripts/orch-runtime op --item [STATE_KEY] --request "[MAIN_REPO_ROOT]/tmp/verify-pr-request-[STATE_KEY].json"
```

The lane owns this approved-head wait. Read its completion file. `status=complete` with `verdict=pass` takes the direct attempt without overseer direction. A `pr-not-open` refusal says the pull request is closed or merged: stop and report its `state`.

Start `[CI_PENDING_COUNT]=0` and `[MERGE_RETRY_COUNT]=0` for `[PREPARED_HEAD]`; a re-entry on that same head keeps both counts. On `status=pending` or `status=unreadable` at the budget, re-read the head with merge-pr.md § 5 step 1's endpoint command. A moved head returns to § 3 for fresh readiness and approval. Otherwise increase `[CI_PENDING_COUNT]` and relaunch through Waiter launch while below `[CI_PENDING_LIMIT]=3`. At the limit, record `merge-ci-pending-limit`, gate `ci`, with the head, pending checks and wait logs. Unarm by § 1 before handing back. Never attempt the merge on that pending budget.

On `status=complete` with `verdict=fail`, a transient runner failure is rerun once per head before the attempt, as [submit-pr.md § 5.1](../workflows/submit-pr.md#51-ci-failure-recovery) One rerun per head reads and records it, with `[STATE_KEY]` as the key: where the recorded `ci_rerun.head` is not the verdict's `result.head`, record the rerun, then ask for it, and on `rerun run=[RUN_ID]` record the run and relaunch the wait through Waiter launch after the interval the wait keeps between calls, never at once, since GitHub registers the new attempt after the verb answers:

```bash
[MAIN_REPO_ROOT]/.agents/skills/orch/scripts/orch-runtime state set --item [STATE_KEY] /ci_rerun '{"head": "[HEAD]", "run": null, "at": "[NOW]"}'
env -u GH_REPO -u GITHUB_REPOSITORY [MAIN_REPO_ROOT]/.agents/skills/github/scripts/github.sh -C [MAIN_REPO_ROOT] ci-rerun [PR_NUMBER] --required-only
```

Every other result, a `no-rerun` line and the verb's exit `1` included, takes the attempt. `--expected-head` refuses a moved head.

```bash
env -u GH_REPO -u GITHUB_REPOSITORY [MAIN_REPO_ROOT]/.agents/skills/github/scripts/github.sh -C [MAIN_REPO_ROOT] pr-merge [PR_NUMBER] --expected-head [PREPARED_HEAD]
```

## Record the merge decision

Status writes in this section apply only to a managed lane as defined by [skill-rules.md § Lane Output](skill-rules.md#lane-output). A standalone session keeps the durable attempt record in the PR body and reports failures through that section's output mode.

Record the merge decision after each attempt here or in [submit-pr.md](../workflows/submit-pr.md) § 2 step 5, before routing its exit. Keep the attempt's exit, `--expected-head` value and returned `merge-route: admin|queue cause=...` line locally. Store them in the launch brief's lane status file under [oversee.md § 3 Lane directive](../workflows/oversee.md#lane-directive). On exit `1`, apply [merge-pr-restack.md § Unarm at a stop](../workflows/merge-pr-restack.md#unarm-at-a-stop) with `[STATE_KEY]` and `[STOP_DIR]=[WORKTREE_PATH]/tmp` before any remote PR-body read or update. Confirm removal of any prior arm or queue entry before continuing; an unconfirmed removal ends the run by that section. Then read the current PR body. Preserve other sections and user decisions. Put that head and line in `## Merge decision`, replacing pending text or appending the section if absent. Write the full body to `[WORKTREE_PATH]/tmp/pr-body-[STATE_KEY]-merge.md` and publish it:

```bash
env -u GH_REPO -u GITHUB_REPOSITORY [MAIN_REPO_ROOT]/.agents/skills/github/scripts/github.sh -C [MAIN_REPO_ROOT] pr-edit-body [PR_NUMBER] --body-file [WORKTREE_PATH]/tmp/pr-body-[STATE_KEY]-merge.md
```

Report body read or update failures in status with the exit and route. Publish no partial body. Without a returned route, preserve any prior record for that head; otherwise record the route as absent (`pr-merge --help`).

## Exit routing

Exit `0` merged the prepared head: continue to step 2.

Exit `75` means GitHub queued or armed the PR: take merge-pr.md § 5 step 1's `queue-watch` block below the `--auto` arm.

Exit `1` BLOCKED → classify the refusal:

```bash
env -u GH_REPO -u GITHUB_REPOSITORY [MAIN_REPO_ROOT]/.agents/skills/github/scripts/github.sh -C [MAIN_REPO_ROOT] ci-classify-refusal [PR_NUMBER]
```

Read `ci-classify-refusal --help` for its output and retry contract. If it prints `retry: same-head`, increase `[MERGE_RETRY_COUNT]` and, while below `[MERGE_RETRY_LIMIT]=3`, re-enter merge-pr.md § 5 step 1: its thread read runs before each re-attempt, and its endpoint read routes a moved head. At the limit, record `merge-refusal-retry-limit`, gate `merge`, putting the last attempt's `BLOCKED` or `pr-merge:` stderr line first, then the head, each attempt's exit and stderr and each classifier output. Unarm by § 1 before handing back. Such a refusal never returns to § 3.2.

Without that line, return to § 3.2 with the cause and its printed detail.
