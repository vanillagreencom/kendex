# Merge contracts

The contracts that [merge-pr.md](../workflows/merge-pr.md) applies and other workflows cite: the stop routes, the queue wait with the cycles its verdicts take, and the worktree disposal predicate. Each section says when to read it.

- A bare § names a section of this file.
- A section of merge-pr.md is named with its file name. A bare step number is a step of merge-pr.md § 5.
- Every contract keeps merge-pr.md's bindings, among them `[STATE_KEY]`, `[ITEM_DIR]`, `[MAIN_REPO_ROOT]`, `[PREPARED_HEAD]`, `[MERGE_REPO_SLUG]`, `[RECOVERY_COUNT]` and the gate mode.
- Every command here that reaches GitHub clears `GH_REPO` and `GITHUB_REPOSITORY`, by merge-pr.md § 5's rule.

## Stop routes

Read when a merge-pr.md run ends without a merged PR, or when a step says it records a stop.

Before the run ends without a merged PR, unarm that PR. Take [merge-pr-restack.md § Unarm at a stop](../workflows/merge-pr-restack.md#unarm-at-a-stop) for it, with `[STOP_DIR]` being the PR's `[ITEM_DIR]`.

The unarm comes first on each of these routes:

- a `records [STOP_NAME]` route;
- a hand-back;
- the cap of § Recovery cycle;
- an `ask` answer that skips the merge;
- the `closed` verdict.

On the `merge-pr all` route, the unarm covers every PR in scope.

A `records [STOP_NAME]` route records the stop against the PR's `[STATE_KEY]`. The record renders the stop's comment into the PR's `[ITEM_DIR]`:

```bash
.agents/skills/orch/scripts/orch-runtime state post-pr-stop record --item [STATE_KEY] --name [STOP_NAME] --gate [GATE] --remaining "[REMAINING]" --comment-file [ITEM_DIR]/post-pr-stop-[STATE_KEY].md
```

Then post that comment on the PR:

```bash
env -u GH_REPO -u GITHUB_REPOSITORY .agents/skills/github/scripts/github.sh post-comment [PR_NUMBER] --body-file [ITEM_DIR]/post-pr-stop-[STATE_KEY].md
```

## Queue wait

Read when a merge call exits `75`: the direct attempt of [merge-attempt.md](merge-attempt.md) or the `--auto` arm of step 1. Read it too when a caller of `pr-merge --auto` routes the outcome of its arm.

An exit `75` means GitHub queued or armed the PR. Run the wait through [Waiter launch](waiter-launch.md), under every gate mode:

```bash
[MAIN_REPO_ROOT]/.agents/skills/orch/scripts/orch-runtime queue-watch --item [STATE_KEY] --repo [MERGE_REPO_SLUG] --pr [PR_NUMBER] --poll 180 --max-wait 540
```

- Keep the `--max-wait` budget above `QUEUE_WAIT_ARM_GRACE` ([settings.md § Review and CI](settings.md#review-and-ci)).
- Keep the lane active while you poll the completion file.
- An exit other than `0` is a refusal with its keyed line. Report it and stop.
- Where the completion file records no exit, follow Waiter launch § Completion.
- Route a completed log's `result.verdict` by the table, then its `result.cause` or `reach` by the list under the table.

| `verdict` | Route |
|---|---|
| `merged` | Step 2 |
| `conflicting` | § Restack cycle |
| `ejected` | By `reach` |
| `disarmed` | By `cause` |
| `armed_blocked` | By `cause` |
| `dequeued` | § Late-findings triage |
| `queued` | By `cause` |
| `armed_awaiting_checks` | The wait again |
| `not_queued` | By `cause` |
| `closed` | Hand back |
| `unknown` | Unarm and hand back |

- `ejected`:
  - `reach: within` and `reach: unread` take § Recovery cycle, with the resolved gate mode and `[RECOVERY_COUNT]`.
  - `reach: outside` means the consumer's reach command placed every failed check outside the change's paths. Send the failure to the overseer, then re-arm the same head once under § Re-queue rule.
    1. Write `[ITEM_DIR]/queue-reach-[STATE_KEY].md` with the harness file tool. Name the head, and each entry of `failed_checks` with its `reach` and its `url`.
    2. Send it with `.agents/skills/mailbox/scripts/lane-mail notice --item [STATE_KEY] --file [ITEM_DIR]/queue-reach-[STATE_KEY].md`. The overseer files it by [oversee-events.md § File one item alone](oversee-events.md#file-one-item-alone).
  - A second `outside` ejection at the same head hands back, naming both runs.
- `disarmed`:
  - `cause: merge_hold`: a person, `disarmed_by`, turned the automatic merge off on purpose, and the wait opened the item's merge hold. The merge waits on that person.
    1. Take no Recovery cycle, and never re-arm.
    2. Ask the person through the run's question route. In a lane, that is `lane-mail ask` ([skill-rules.md § Lane mail](skill-rules.md#lane-mail)).
    3. When the answer arrives, close the hold first: `.agents/skills/orch/scripts/orch-runtime op --item [STATE_KEY] --request-json '{"op":"record-pr-progress","step":"merge-answered"}'`.
    4. Then follow the answer. A merge returns to merge-pr.md § 5 step 1. Any other answer hands back.
  - Any other cause takes § Recovery cycle.
- `armed_blocked`: the PR was armed and not in the queue when the wait ended.
  - `cause: check_failed` takes § Recovery cycle.
  - `cause: not_mergeable` is the wait's last check reading before its deadline, not a check verdict ([gates.md § Which waiter answers which state](gates.md#which-waiter-answers-which-state)). Read the head's CI again with the `verify-pr` call of [merge-attempt.md § Direct attempt](merge-attempt.md#direct-attempt):
    - `fail` takes § Recovery cycle.
    - `pending` waits again, as `armed_awaiting_checks` does.
    - `pass` or `none` returns to merge-pr.md § 3 for a fresh readiness check, and spends no recovery cycle. That check names what keeps the PR out of the queue.
    - A readiness check that passes on the same head arms and waits again, under § Armed budget.
    - A readiness check that names a blocker routes it by merge-pr.md § 3.2.
- `dequeued`: on `cause: late_findings_dequeue_failed`, first confirm the dequeue or the disarm.
- `queued`: the wait did not confirm the outcome by its deadline. Where an entry stands, the PR is still armed under every cause but `exit_unconfirmed`.
  - `cause: still_progressing`: the merge is live. Run the wait again, with no limit, and keep the lane active until a verdict ends it. After a merge, run steps 2-6.
  - `cause: progress_unobservable`: the wait could not read the entry's head. That is no evidence of an idle queue. Run the wait again on the same head once. A second `progress_unobservable` in a row takes § Recovery cycle, as `stalled` does. The reply's progress counts route nothing.
  - `cause: blocked_by_entry_ahead`: take § Entry-ahead wait. It spends no recovery cycle.
  - `cause: stalled`: take § Recovery cycle.
  - `cause: exit_unconfirmed`: the PR is not armed. The last poll saw it out of the queue and unarmed, short of the confirmation count. Do not wait for it to merge. Run the wait once more, which reads the arm again, and route its verdict.
- `armed_awaiting_checks`: the PR is armed and not yet in the queue, and no check failed. Run the wait again on the same head, under § Armed budget. It spends no recovery cycle.
- `not_queued` with `cause: never_armed`: no poll saw an arm or an entry on this head within `QUEUE_WAIT_ARM_GRACE`, though exit `75` reported one. Take § Recovery cycle. Never re-arm here.
- `closed`: hand back with the verdict. Replay nothing.
- `unknown`: the verdict is unrecognized, or `status: error` means a read failed. Neither says anything about the arm. Unarm by § Stop routes, then hand back with the `error` and `cause` fields. Never re-arm.

### Armed budget

Read when the wait answers `armed_awaiting_checks`, or `armed_blocked` with `cause: not_mergeable`.

Record the time of the first such result on this head. Read the budget once:

```bash
.agents/skills/orch/scripts/orch-env QUEUE_WAIT_ARMED_MINUTES 90
```

- Repeat the wait until that many minutes have passed since the recorded time.
- A new head clears the record. So does any verdict but those two.
- This budget bounds a wait on checks that have not failed. `CI_FIX_MAX_CYCLES` does not.
- Past the budget, skip steps 2-6. Hand back with the last result's `pending_checks` and the minutes waited.
  - Under `cause: checks_unread`, there are no pending checks. Say the checks were never read within the wait's budget.
  - Under `cause: not_mergeable`, there are none either. Say the last check reading settled as `pass` or `none`, with no entry.
- No wait past the budget starts until the overseer has appended one `ruling` row for the item through `orch-runtime state log append --fleet [RULING_FILE]`. The overseer judges with the minutes waited ([oversee-events.md § Judgement rules](oversee-events.md#judgement-rules)).

### Entry-ahead wait

Read when the wait answers `queued` with `cause: blocked_by_entry_ahead`, or when a workflow reads a PR's merge-queue entry.

1. Save `queue_ahead_pr` as `[AHEAD_PR]`.
2. Repeat the same `queue-watch` command through Waiter launch.
3. Route `merged`, `closed`, `dequeued` and `status: error` by the table at once.
4. For any other result, read whether the saved entry is still in the queue:

   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY gh api graphql -f query='query($owner: String!, $repo: String!, $number: Int!) { repository(owner: $owner, name: $repo) { pullRequest(number: $number) { mergeQueueEntry { position } } } }' -F owner=[MERGE_REPO_OWNER] -F repo=[MERGE_REPO_NAME] -F number=[AHEAD_PR]
   ```

   - A failed or unreadable response proves no departure. Unarm by § Stop routes, then hand back with that read failure.
   - While `mergeQueueEntry` is non-null, repeat the wait and this read. Route none of these results to § Recovery cycle.
5. Once `mergeQueueEntry` reads null, the saved entry has left. Read this PR:

   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY gh pr view [PR_NUMBER] --repo [MERGE_REPO_SLUG] --json state,mergeable
   ```

6. Route `state` first:
   - `MERGED` continues to merge-pr.md § 5 step 2.
   - `CLOSED` hands back.
   - On an open PR, `mergeable: CONFLICTING` takes § Restack cycle.
   - Any other value repeats the original wait, and its fresh verdict routes by the table.

This cause never enters § Recovery cycle.

## Recovery cycle

Read when a queue verdict routes here, and before a re-arm after a red merge-group run.

The cycle routes the failure back into ci-fix. Never fix CI by hand. Read the cap:

```bash
.agents/skills/orch/scripts/orch-runtime state cap CI_FIX_MAX_CYCLES
```

- The reply's `limit` is `[MAX_CYCLES]`: the recovery cycles one merge-pr run may spend. `[RECOVERY_COUNT]` counts them (merge-pr.md § 5 step 1).
- At the cap, report the failing check names, ci-fix's last error summary and what each cycle attempted. Never report a bare "persistent failure". Then skip steps 2-6 and hand back.
- No cycle starts past the cap until the overseer has appended one `ruling` row for the item through `orch-runtime state log append --fleet [RULING_FILE]`. The overseer judges with `[RECOVERY_COUNT]` and that `limit`.
- A change to a gate or to CI behaviour needs a fresh head.

### Re-queue rule

Read when a head is about to re-enter the merge queue after a red merge-group run. Every workflow that re-arms after a red run points here.

- After a merge-group run concludes `failure` or `timed_out`, re-arm only a new head: the fix ci-fix pushes.
- A cancelled merge-group run, or one the infrastructure lost, may re-arm the same head once.
- A red run whose `queue-watch` ejection reads `reach: outside` may re-arm the same head once.
- A second such red at the same head hands back, naming both runs.
- No other unchanged head re-enters the queue after a red run.

### Steps

1. Run `⤵ workflows/ci-fix.md [PR_NUMBER] § 1-6 → merge-pr.md § 5 step 1` with context `worktree`, `lifecycle: "managed"` and `issue_id`.
   - For a queue ejection, the failing run is the merge-group run (event `merge_group`), not necessarily the PR-head run.
   - Find it through the ejection's `failed_checks[].url`, which names each failed check's run, or through `gh run list --event merge_group --limit 10`.
   - Point ci-fix at that run.
2. Re-confirm the gate at the head about to be re-armed, under the gate mode ci-fix returned. Skip this step under the `off` gate mode.
   - Write the request of merge-pr.md § 3's review call.
   - Run it as the review wait, with the shorter period:

   ```bash
   env PR_REVIEW_WAIT_SECS=300 .agents/skills/orch/scripts/orch-runtime op --item [STATE_KEY] --request "[ITEM_DIR]/verify-review-request-[STATE_KEY].json"
   ```

   Route its answer:

   - `copilot-error` takes [gates.md § Copilot requests](gates.md#copilot-requests), then this wait again before the re-arm.
   - `comments` takes merge-pr.md § 3.3, then this wait again.
   - `blocked` takes merge-pr.md § 3.2's `blocked` route.
   - `approved`, `proceeded` and `timeout` go on to step 3 below, where merge-pr.md § 5 step 1's review call routes the head.
   - `changes_requested` returns to merge-pr.md § 3.
   - `unreadable` runs the call once more. A second `unreadable` records `review-gate-read-failed`.
3. Return to merge-pr.md § 5 step 1 and wait.

## Restack cycle

Read when the wait answers `conflicting`, or when a step routes a conflicting PR here.

The base, not CI, blocks the merge. Follow [merge-pr-restack.md](../workflows/merge-pr-restack.md), then return to step 1.

## Late-findings triage

Read when the wait answers `dequeued`.

The findings, not CI, block the merge.

1. On `cause: late_findings_dequeue_failed`, first run [merge-pr-restack.md](../workflows/merge-pr-restack.md) step 1's node id read, disarm and dequeue. The PR is out of the queue before the triage pushes anything.
2. Run merge-pr.md § 3.3. Where the head has not moved, return to merge-pr.md § 5 step 1 and wait.

## Disposal predicate

Read at step 4, before any branch or worktree cleanup, and at step 6, just before a worktree removal.

The predicate holds where the PR's worktree exists, its tree is clean, and its checked-out branch is still `[PR_BRANCH]`. Read the two facts:

```bash
git -C [WORKTREE_PATH] status --porcelain
```

```bash
git -C [WORKTREE_PATH] branch --show-current
```

- It holds on empty output from the first command and `[PR_BRANCH]` from the second.
- Otherwise its cause is `dirty tree` or `branch moved`.
- A command that exits non-zero fails its fact, as `tree unreadable` or `branch unreadable`.
- The predicate answers only from a fact it proves, never from absent output.
- Step 6 runs it again, whole, just before the removal, and removes only where every part holds.
- Where it does not hold, keep the worktree and its branch. The cause goes on merge-pr.md § 6's worktree line.
