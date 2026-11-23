# Merge attempt

Read when [merge-pr.md § 5](../workflows/merge-pr.md#5-execute-the-merge) step 1 takes the direct attempt, and when it or [submit-pr.md § 2](../workflows/submit-pr.md#2-push-and-submit) step 5 records a merge decision. Section and step numbers below are merge-pr.md's. The attempt keeps that workflow's bindings, among them `[PREPARED_HEAD]`, `[MERGE_REPO_SLUG]`, `[ITEM_DIR]` and the gate mode, and the stop and unarm rules of [merge-contracts.md § Stop routes](merge-contracts.md#stop-routes).

## Direct attempt

Every entry waits on the PR's CI before the attempt. Before the wait, read the PR's merge state:

```bash
env -u GH_REPO -u GITHUB_REPOSITORY [MAIN_REPO_ROOT]/.agents/skills/github/scripts/github.sh -C [MAIN_REPO_ROOT] pr-merge [PR_NUMBER] --check
```

The JSON's `mergeable` routes first:

- `CONFLICTING` ends the attempt before any wait. Write `[PREPARED_HEAD]` and the word `conflict` in `## Merge decision` by § Record the merge decision, with no route line. Then take [merge-contracts.md § Restack cycle](merge-contracts.md#restack-cycle). A conflict never spends the pending bound below.
- `MERGEABLE` and `UNKNOWN` go on to the wait.

The wait is the runtime's `verify-pr` operation over the PR's current head. Run it through [Waiter launch](waiter-launch.md). Repeat it at most once every 180 seconds while `result.status` is `pending` or `unreadable`, within the lane's CI budget `CI_WAIT_MAX_SECS` ([settings.md § Review and CI](settings.md#review-and-ci)). `[OWNER/REPO]` is `[MERGE_REPO_SLUG]`:

```bash
jq -cn --arg repo "[OWNER/REPO]" --argjson pr [PR_NUMBER] \
  '{op: "verify-pr", repo: $repo, pr: $pr, required_only: true}' \
  > "[ITEM_DIR]/verify-pr-request-[STATE_KEY].json"
[MAIN_REPO_ROOT]/.agents/skills/orch/scripts/orch-runtime op --item [STATE_KEY] --request "[ITEM_DIR]/verify-pr-request-[STATE_KEY].json"
```

`[CI_PENDING_COUNT]` and `[MERGE_RETRY_COUNT]` start at `0` for `[PREPARED_HEAD]`. A re-entry on the same head keeps both.

The lane owns this wait on the approved head. Read its completion file:

- `status=complete` with `verdict=pass`: take the attempt below, with no overseer direction.
- A `pr-not-open` refusal: the PR is closed or merged. Stop and report its `state`.
- `status=pending` or `status=unreadable` at the budget: re-read the head with merge-pr.md § 5 step 1's endpoint read.
  - A moved head returns to § 3 for a fresh readiness check and approval.
  - Otherwise add one to `[CI_PENDING_COUNT]`. While it is below `[CI_PENDING_LIMIT]=3`, relaunch through Waiter launch.
  - At the limit, record `merge-ci-pending-limit`, gate `ci`, with the head, the pending checks and the wait logs. Then unarm by merge-contracts.md § Stop routes and hand back.
  - Never attempt the merge on that pending bound.
- `status=complete` with `verdict=fail`: rerun a transient runner failure once per head before the attempt. [publication.md § One rerun per head](publication.md#one-rerun-per-head) reads and records it, with `[ISSUE_ID]` being `[STATE_KEY]`.

**One rerun per head.** Where the item's recorded `ci_rerun.head` is not the verdict's `result.head` (`[HEAD]`), record the rerun, then request it:

```bash
[MAIN_REPO_ROOT]/.agents/skills/orch/scripts/orch-runtime op --item [STATE_KEY] --request-json '{"op":"record-pr-progress","step":"ci-rerun","head":"[HEAD]"}'
```

```bash
env -u GH_REPO -u GITHUB_REPOSITORY [MAIN_REPO_ROOT]/.agents/skills/github/scripts/github.sh -C [MAIN_REPO_ROOT] ci-rerun [PR_NUMBER] --required-only
```

On `rerun run=[RUN_ID]`, record the run. Then relaunch the wait through Waiter launch after the wait's interval between calls, never at once.

```bash
[MAIN_REPO_ROOT]/.agents/skills/orch/scripts/orch-runtime op --item [STATE_KEY] --request-json '{"op":"record-pr-progress","step":"ci-rerun-run","head":"[HEAD]","run":[RUN_ID]}'
```

Every other result takes the attempt, a `no-rerun` line and the command's exit `1` included. `--expected-head` refuses a moved head:

```bash
env -u GH_REPO -u GITHUB_REPOSITORY [MAIN_REPO_ROOT]/.agents/skills/github/scripts/github.sh -C [MAIN_REPO_ROOT] pr-merge [PR_NUMBER] --expected-head [PREPARED_HEAD]
```

## Record the merge decision

Record the decision after each attempt, here or in the arm of submit-pr.md § 2 step 5, before routing its exit.

- Keep the attempt's exit, its `--expected-head` value and its `merge-route: admin|queue cause=...` line.
- A lane ([skill-rules.md § Lane Output](skill-rules.md#lane-output)) stores them in the lane status file under [lane-launch.md § Lane directive](lane-launch.md#lane-directive).
- A session outside a lane keeps the durable record in the PR body alone and reports failures in that section's output mode.

On exit `1`, first apply [merge-pr-restack.md § Unarm at a stop](../workflows/merge-pr-restack.md#unarm-at-a-stop) with `[STATE_KEY]` and `[STOP_DIR]=[WORKTREE_PATH]/tmp`.

- Do this before any read or update of the PR body.
- Confirm that any earlier arm or queue entry is gone before going on.
- An unconfirmed removal ends the run by that section.

Then write the body:

1. Read the current PR body.
2. Keep its other sections and the user's decisions.
3. Put the head and the route line in `## Merge decision`, replacing pending text. Append the section where it is absent.
4. Write the whole body to `[WORKTREE_PATH]/tmp/pr-body-[STATE_KEY]-merge.md` and publish it:

```bash
env -u GH_REPO -u GITHUB_REPOSITORY [MAIN_REPO_ROOT]/.agents/skills/github/scripts/github.sh -C [MAIN_REPO_ROOT] pr-edit-body [PR_NUMBER] --body-file [WORKTREE_PATH]/tmp/pr-body-[STATE_KEY]-merge.md
```

- Report a failed body read or update in the status file, with the exit and the route.
- Publish no partial body.
- Where the attempt returned no route line, keep any earlier record for that head. Otherwise record the route as absent (`pr-merge --help`).

## Exit routing

Exit `0` merged the prepared head: continue to merge-pr.md § 5 step 2.

Exit `75` means GitHub queued or armed the PR: take [merge-contracts.md § Queue wait](merge-contracts.md#queue-wait).

Exit `1` (`BLOCKED`): classify the refusal.

```bash
env -u GH_REPO -u GITHUB_REPOSITORY [MAIN_REPO_ROOT]/.agents/skills/github/scripts/github.sh -C [MAIN_REPO_ROOT] ci-classify-refusal [PR_NUMBER]
```

`ci-classify-refusal --help` states its output and retry contract.

- Where it prints `retry: same-head`, add one to `[MERGE_RETRY_COUNT]`.
  - While it is below `[MERGE_RETRY_LIMIT]=3`, re-enter merge-pr.md § 5 step 1. Its thread read and review call run before each new attempt, and its endpoint read routes a moved head.
  - At the limit, record `merge-refusal-retry-limit`, gate `merge`. Put the last attempt's `BLOCKED` or `pr-merge:` stderr line first, then the head, each attempt's exit and stderr, and each classifier output. Unarm by merge-contracts.md § Stop routes and hand back.
  - Such a refusal never returns to § 3.2.
- Without that line, return to § 3.2 with the cause and its printed detail.
