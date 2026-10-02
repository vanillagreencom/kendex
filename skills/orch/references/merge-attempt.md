# Merge attempt

Load from [merge-pr.md § 5 step 1](../workflows/merge-pr.md#5-execute-the-merge). Section and step numbers below refer to that workflow. Keep its prepared head, endpoint command, gate mode and stop rules.

## Direct attempt

**The direct attempt** follows a CI wait on the PR, on every entry to it, since the immediate merge refuses a pending check. Wait through [Waiter launch](waiter-launch.md):

```bash
env -u GH_REPO -u GITHUB_REPOSITORY [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/ci-wait [PR_NUMBER] 180 600 --json --item [STATE_KEY]
```

The lane owns this approved-head wait. Read its completion file. `status=complete verdict=pass` takes the direct attempt without overseer direction, on the first green poll after pending CI (`ci-wait --help`).

Start `[CI_PENDING_COUNT]=0` for `[PREPARED_HEAD]`. On `status=timeout verdict=pending`, re-read the head with merge-pr.md § 5 step 1's endpoint command. A moved head returns to § 3 for fresh readiness and approval. Otherwise increase the count and relaunch through Waiter launch while below `[CI_PENDING_LIMIT]=3`. At the limit, record `merge-ci-pending-limit`, gate `ci`, with the head, pending checks and wait logs. Unarm by § 1 before handing back. Never attempt the merge on that pending timeout. Exit `5` follows the mail route without consuming this count.

Other results take the attempt: the wait counts every red check, the attempt only required checks. `--expected-head` refuses a moved head.

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

Exit `75` means GitHub queued or armed the PR: take merge-pr.md § 5 step 1's queue-wait block below the `--auto` arm.

Exit `1` BLOCKED → run `env -u GH_REPO -u GITHUB_REPOSITORY [MAIN_REPO_ROOT]/.agents/skills/github/scripts/github.sh -C [MAIN_REPO_ROOT] ci-classify-refusal [PR_NUMBER]` and return to § 3.2 with its cause and detail.
