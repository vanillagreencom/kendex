# PR Merge Workflow

Verify the merge conditions and merge PR(s).

Run every long `approval-wait`, `ci-wait` and `queue-wait` below through [Waiter launch](../references/waiter-launch.md). `approval-wait --resolve-mode` runs directly, not through that launch. Exit `5` with the log line `<waiter>: mail=<count>` or `<waiter>: mail-unreadable=<path>` is no verdict: run `.agents/skills/orch/scripts/lane-mail inbox --item [STATE_KEY]`, act on what it prints, then launch the same waiter again in a fresh run directory; route every other exit as written below.

| Command | Flow |
|---------|------|
| `merge-pr` | List ready PRs, user selects |
| `merge-pr [N]` | Merge a specific PR |
| `merge-pr all` | Merge all ready PRs in sequence |

## 1. Identify Candidates

```bash
.agents/skills/github/scripts/github.sh pr-list-ready
```

With no argument, present the list and ask which to merge. With `all`, process every ready PR sequentially.

Resolve the decision mode once for every post-PR choice in this workflow. Named stops use [SKILL.md § The Cycle](../SKILL.md#the-cycle).

```bash
.agents/skills/orch/scripts/orch-env ORCH_DECISION_MODE auto-recommended
```

Bind the repository root as `[MAIN_REPO_ROOT]` and create the directory every stop below renders into, before any stop route can fire. Every stop this workflow records is written under that root, so none of them depends on `[WORKTREE_PATH]`, which § 4 binds and most of the stop routes run before:

```bash
.agents/skills/orch/scripts/git-context common-root .
```

```bash
mkdir -p [MAIN_REPO_ROOT]/tmp
```

**No hand-back leaves an armed PR.** Every route below that ends this run without a merged PR, each `records [STOP_NAME]` branch, each hand-back, the recovery-cycle cap, an `ask` answer that skips the merge and the `closed` verdict included, first takes [merge-pr-restack.md § Unarm at a stop](merge-pr-restack.md#unarm-at-a-stop) for the PR it is stopping, with `[STOP_DIR]` being `[MAIN_REPO_ROOT]/tmp`. On the batch route that is every PR in scope, since a cross-check stop exists to keep them from landing together.

**Stop routes.** Every `records [STOP_NAME]` branch below records against the `[STATE_KEY]` § 3 resolved for the PR it is stopping, renders into the one path this workflow uses, and posts that file on that PR:

```bash
.agents/skills/orch/scripts/workflow-state post-pr-stop record [STATE_KEY] [STOP_NAME] [GATE] "[REMAINING]" [MAIN_REPO_ROOT]/tmp/post-pr-stop-[STATE_KEY].md
```

```bash
env -u GH_REPO -u GITHUB_REPOSITORY .agents/skills/github/scripts/github.sh post-comment [PR_NUMBER] --body-file [MAIN_REPO_ROOT]/tmp/post-pr-stop-[STATE_KEY].md
```

## 2. Cross-Check (batch merges only)

**Skip if** fewer than two PRs are in scope.

This section is the one run-level step, so its stop needs a PR to record against: run § 3's per-PR state resolution for the FIRST PR in the reported order, and record and post both stops below against that PR.

```bash
.agents/skills/github/scripts/github.sh pr-cross-check [PR_NUMBERS] --quick --json
```

High-severity findings (conflicts) show the issues, then `auto-recommended` records `batch-cross-check-failed`; `ask` stops with them shown. Otherwise verify:

```bash
.agents/skills/github/scripts/github.sh pr-cross-check [PR_NUMBERS] --verify --json
```

`can_batch_merge: true` → § 3 in the reported `merge_order`. `false` → show the merge, build, and test failures with their suggested remediation; `auto-recommended` records `batch-cross-check-failed`, and `ask` presents `Abort` | `Force anyway`, with `Abort` recommended.

## 3. Check Merge Readiness

**Per-PR state resolution.** This block runs once per PR in scope, never once per run: on the `merge-pr all` route, resolving once would bind the first PR's key to every later PR and collide their stops in one state file. Use the extracted issue as `[STATE_KEY]` when present, otherwise use `pr-[PR_NUMBER]`; run `init` only when `exists` is false. § 4 reuses the `[ISSUE]` and `[PR_BRANCH]` this reads.

```bash
.agents/skills/github/scripts/github.sh pr-issue [PR_NUMBER] --format=text
```

```bash
env -u GH_REPO -u GITHUB_REPOSITORY gh pr view [PR_NUMBER] --json headRefName --jq .headRefName
```

```bash
.agents/skills/orch/scripts/workflow-state exists --json [STATE_KEY]
```

```bash
.agents/skills/orch/scripts/workflow-state init [STATE_KEY] --branch [PR_BRANCH]
```

```bash
.agents/skills/orch/scripts/workflow-state update [STATE_KEY] '.post_pr_stop = null'
```

Read `[CHECK_HEAD]` before each readiness check:

```bash
env -u GH_REPO -u GITHUB_REPOSITORY gh pr view [PR_NUMBER] --json headRefOid --jq .headRefOid
```

```bash
.agents/skills/github/scripts/github.sh pr-merge [PR_NUMBER] --check
```

### 3.1 Resolve Transient Blockers First

`CHECK.transient == true` → route on the issue prefix before any user prompt, then continue to § 3.2. Each re-check repeats § 3's head read.

| Prefix | Wait |
|--------|------|
| `unknown:` (`cause=computing` or `cause=read-failed` for the mergeability read) | No wait of its own. Re-check once, then continue to § 3.2 with the latest `CHECK` |
| `ci_pending:` | No wait here. Continue to § 3.2's gates, then § 5 step 1's owned CI wait and `CI_PENDING_LIMIT` |
| `ci_fetch_failed:`, `ci_unconfigured:` | Re-check, at most three checks total, then continue with the latest `CHECK` |

### 3.2 Act On The Result

`CHECK.state` decides first: `MERGED` → set `[ALREADY_MERGED]=true`, run § 4 EXCEPT § 4.1, then enter § 5 step 1, which skips the thread read, the arm and the wait and goes straight to post-merge work; `CLOSED` → records `pr-closed-unmerged`.

`can_merge: true` → § 4 once the gates below are met, showing any warnings. `can_merge: false` with `transient: true` takes that route after § 3.1 only when all remaining issues are `ci_pending:`, or `unknown:` is the only issue. Pending CI takes § 5 step 1's direct-attempt wait; unknown takes its explicit queue arm and refusal handler. Any other `false`, including `ci_fetch_failed:`, → show the issues and suggested fixes. `auto-recommended` takes `Fix and retry` once; the same blocker then records `merge-check-blocked`. `ask` presents `Skip` | `Fix and retry`, recommending the latter.

The following conditions are merge gates, not advice:

- **Open review threads** — not a `CHECK` field: run § 3.3 before the `not_approved` wait.
- **`not_approved`** — resolve the gate mode the pull request's base sets ([references/gates.md](../references/gates.md)). A non-zero exit is no mode: report it and stop.

  ```bash
  env -u GH_REPO -u GITHUB_REPOSITORY .agents/skills/orch/scripts/approval-wait [PR_NUMBER] --resolve-mode --base-checkout [REVIEW_BASE_CHECKOUT]
  ```

  Route on the printed `GATE_MODE`:

  - `off` — informational; never gate or wait.
  - `approval` — a GitHub-native approval verdict is required. Without it, do not auto-merge: poll `env -u GH_REPO -u GITHUB_REPOSITORY .agents/skills/orch/scripts/approval-wait [PR_NUMBER] 30 --json --mode approval --item [STATE_KEY] --base-checkout [REVIEW_BASE_CHECKOUT]`; after its budget, `auto-recommended` records `review-gate-unmet`, while `ask` presents the wait or stop choice.

  A `copilot-error` answer routes as [Copilot requests](../references/gates.md#copilot-requests) says, then re-runs this wait. It is never a met approval gate.

  A `comments` answer (exit 1) is an open thread: run § 3.3, then this wait again.

  With `PR_REVIEW_ON_TIMEOUT=proceed`, a deadline reached with zero unresolved threads and no reviewer evidence returns `proceeded` (exit 0) instead of `timeout` — treat it as a met gate and record it in the § 6 report. An open thread answers `comments` instead; a `changes_requested` blocked earlier, at § 3.2's readiness check. The proceed is a LOCAL verdict — orch posts no status.

  An `unreviewable` status is never a met gate: no automatic reviewer targets this PR's base, so the silence is structural. Follow [references/gates.md](../references/gates.md) § Stacked pull requests, then re-run the wait. If it repeats, `auto-recommended` records `review-gate-unreviewable`, while `ask` presents the wait or stop choice.

  Stop waiting for a missing gate verdict while workflow state carries `pr_approval.forced`, which `submit-pr.md` § 4's `Force merge` sets for the item and no push clears; the prepared head then takes § 5's `--auto` arm.

Bot-specific signals — emoji reactions, sticky-comment prose, checklist text — are never parsed as merge gates, with one exception: the findings section a review body lists under `Suppressed comments (N)` or `Previously missed (N)`, which the reply check `pr-merge` runs (`review_replies:`) reads. Only GitHub-native review state, the thread-resolution count and that reply check count.

### 3.3 Thread Read

Read the open review threads by [references/thread-read.md](../references/thread-read.md), which owns the read, its triage route, its return points and the list of what else reads a thread.

## 4. Prepare

```bash
.agents/skills/worktree/scripts/worktree exists "$ISSUE"
.agents/skills/worktree/scripts/worktree path "$ISSUE"
.agents/skills/github/scripts/github.sh bot-token
```

Reuse the `[ISSUE]` and `[PR_BRANCH]` § 3 resolved for this PR, and worktree commands only with an `[ISSUE]`. A [micro.md](micro.md) § 4 entry starts here instead, binding those two, `[STATE_KEY]` and § 1's own run-level bindings itself, so nothing waits on CI or on a reviewer before § 5 arms the merge; that entry escapes on a § 5 step 1 return to § 3.2, whose `CHECK` object § 3 never produced for it. When no issue worktree exists, set `[WORKTREE_PATH]` to `[MAIN_REPO_ROOT]`, the root § 1 bound; there is then no issue worktree to dispose of in § 5.

`bot-token` reporting `.configured: false` is an identity decision, not a budget choice: the merge would land under the human's name. `auto-recommended` records `bot-auth-missing` rather than taking that decision; `ask` presents `Merge as current user` | `Abort`, with `Abort` recommended.

### 4.1 Detach Orphaned Children

**Skip if** no `[ISSUE]` was extracted, `TRACKER=github`, or workflow state for `[STATE_KEY]` records `children_detached`: [submit-pr.md](submit-pr.md) § 2 step 5 already ran this detach, before its arm.

```bash
.agents/skills/linear/scripts/linear.sh issues children [ISSUE] --pending --recursive
```

Partition by `state_type`: `backlog` and `unstarted` are **safe** (`[SAFE_IDS]`); anything else is **active**. Both empty → § 5.

Active children pause the merge and ask the user per orphan — was the work landed in this PR? Yes closes it Done; no appends it to `[SAFE_IDS]`; abort stops § 4.1 entirely.

`[SAFE_IDS]` still empty → § 5. Otherwise apply [skill-rules.md § Coordination](../references/skill-rules.md#coordination) before rebundling them under a new parent:

```bash
.agents/skills/linear/scripts/linear.sh issues get [ISSUE]
```

Read `.title`, `.project.id` and the label names, and split the names, joined by commas, by the taxonomy the create refuses against with `linear.sh labels declared "[NAMES]"`: `.kept`, joined the same way, is `[PARENT_LABELS]`, and `.dropped`, printed in this step's output, is `[DROPPED_LABELS]` (`none` when empty). A non-zero exit **aborts the merge**. Take `[BUNDLE_PRIORITY]` as the highest priority across `[SAFE_IDS]` (Linear: `1`=Urgent…`4`=Low, lower wins; default `3`). Build `[BUNDLE_DESC]` per `.agents/skills/project-management/templates/parent-issue-template.md`, with a `## Sub-Issues` list and a `## Context` line naming the detachment. Its `**Reached by**` line is this rebundle run: `this merge-pr rebundle, detaching pending children from [ISSUE] before merge`. A rebundle parent is structural, so the create passes no `--review-born`.

Write `[BUNDLE_DESC]` with the harness file-write tool to `tmp/rebundle-description-[ISSUE].md` and bind that path as `[BODY_FILE]`.

```bash
.agents/skills/linear/scripts/linear.sh issues create --state "Backlog" --title "[PARENT_TITLE] follow-ups" --description-file [BODY_FILE] --project "[PARENT_PROJECT]" --labels "[PARENT_LABELS]" --priority [BUNDLE_PRIORITY] --format=ids
```

A non-zero exit or empty output **aborts the merge**. Otherwise reparent each safe id (one call each), link the bundle back, and comment on the original:

```bash
.agents/skills/linear/scripts/linear.sh issues update [SAFE_ID] --parent [NEW_BUNDLE]
```

```bash
.agents/skills/linear/scripts/linear.sh issues add-relation [NEW_BUNDLE] --related [ISSUE]
```

Write the comment body with the harness file-write tool to `tmp/rebundle-comment-[ISSUE].md` and bind that path as `[BODY_FILE]`:

```markdown
Pending children rebundled under [NEW_BUNDLE] before merge to avoid cascade-Done. Labels the taxonomy does not declare, left off the bundle: [DROPPED_LABELS].
```

```bash
.agents/skills/linear/scripts/linear.sh comments create [ISSUE] --body-file [BODY_FILE]
```

## 5. Execute The Merge

Some harnesses reset cwd per shell call — prefer `-C` and absolute paths over `cd &&` chains.

**Clear `GH_REPO` and `GITHUB_REPOSITORY` on every command in this section that reaches GitHub, fenced or inline.** `gh pr view`, `gh api` and the rest honour them over both cwd and `-C`, while `gh repo view` ignores them and answers for the working directory. So an inherited value splits this section across two repositories: a read and a mutation land on that repository's same-numbered PR while the `gh repo view` below still names this checkout — a `branch -D` authorized by the wrong PR, or the queue wait's late-findings guard disarming and dequeuing someone else's. Clearing them puts every command here back on one repository. Reaching GitHub is a property of the script rather than of the command's spelling: a waiter, the `github.sh` router, `container-close` and `worktree` all call `gh` inside. Before adding a command here, read the script it names.

```bash
.agents/skills/orch/scripts/git-context common-root .
```

Use the output as `MAIN_REPO_ROOT`.

1. **Merge**, before any cleanup:

   Resolve the repository and exact head before any merge attempt. `[RECOVERY_COUNT]` is `0` initially and one more per recovery cycle in this run. Nothing persists it: a run resumed after a compaction, or relaunched by oversee's `window-gone` rule, starts a fresh budget. Read a run that keeps returning to ci-fix as the signal the cap is there for, whatever the count says.

   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY gh repo view --json nameWithOwner --jq .nameWithOwner
   ```

   `[ALREADY_MERGED]=true` keeps the recorded merge decision in status and the PR body, then skips to step 2 before every read below. A merged head may be unavailable; cleanup needs no fresh attempt or route.

   **Thread read.** Run § 3.3 first, on every entry to this step and every return from the cycles below. Then read the endpoints:

   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY gh pr view [PR_NUMBER] --json baseRefOid,headRefOid --jq '[.baseRefOid,.headRefOid]|@tsv'
   ```

   That head is `[PREPARED_HEAD]` and that base is `[PREPARED_BASE]`. Except on `[MICRO_ENTRY]`, require `[PREPARED_HEAD]=[CHECK_HEAD]`; a mismatch returns to § 3 for fresh readiness and approval. A `[MICRO_ENTRY]` run classifies them, fetching both first so a base tip newer than the worktree's last fetch is still measured:

   ```bash
   git -C [WORKTREE_PATH] fetch --quiet --no-tags --no-write-fetch-head origin [PREPARED_BASE] [PREPARED_HEAD]
   ```

   ```bash
   .agents/skills/orch/scripts/item-tier --base [PREPARED_BASE] --head [PREPARED_HEAD] --repo [WORKTREE_PATH]
   ```

   Bind `[REVIEW_BASE_CHECKOUT]` to that consumer base, per [Gate-mode routing](../references/gates.md#gate-mode-routing), and resolve its mode:

   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY .agents/skills/orch/scripts/approval-wait [PR_NUMBER] --resolve-mode --base-checkout [REVIEW_BASE_CHECKOUT]
   ```

   A `[MICRO_ENTRY]` run continues only where the `item-tier` answer is `tier=micro`, the gate mode is `approval`, AND `[MICRO_HEAD]` equals `[PREPARED_HEAD]`: a retarget can change the class or the base's approval rule without moving the head, so the fresh answers carry the micro tier and the head says it is the same run. Any other answer arms nothing and escapes by micro.md condition 8.

   **Merge route.** `pr-merge` picks the route, and no step here judges it: it merges past the queue with `--admin` bound to the prepared head and exits `0`, or takes the queue and exits `75`, naming the cause on its `merge-route:` line (`pr-merge --help` § Merge route). Take the direct attempt below first. [submit-pr.md](submit-pr.md) § 2 step 5 arms at creation only a PR this route takes through the queue; where GitHub has already queued a PR, the attempt answers exit `75`. An item whose workflow state carries `pr_approval.forced`, and a PR on § 3.2's `unknown:` path, whose direct attempt would refuse on that issue, take the explicit `--auto --queue` arm below instead, which never passes `--admin`.

   **Who acts.** The lane merges its own PR under the token the `github.sh` router selects, the lanes app's installation token in a lane sandbox. The emergency merge of [review-gate SKILL.md § 4. Operations](../../review-gate/SKILL.md#4-operations) is the overseer's GitHub App's alone.

   **The direct attempt.** Follow [merge-attempt.md](../references/merge-attempt.md#direct-attempt) for the approved-head CI wait, its pending bound, the exact-head attempt and exit routing. Its exit `75` enters the queue-wait block below.

   **Record the merge decision.** After each attempt here or in [submit-pr.md](submit-pr.md) § 2 step 5, apply [merge-attempt.md § Record the merge decision](../references/merge-attempt.md#record-the-merge-decision) before routing its exit.

   **The `--auto` arm** takes only that same head:

   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY [MAIN_REPO_ROOT]/.agents/skills/github/scripts/github.sh -C [MAIN_REPO_ROOT] pr-merge [PR_NUMBER] --auto --queue --expected-head [PREPARED_HEAD]
   ```

   Exit `0` merged the prepared head immediately — continue to step 2. Exit `1` with a diagnostic line starting `arm: no-merge-gate=<condition>`, including after a `merge-route:` line, means the arm armed nothing and names why: on § 3.2's `unknown:` path record `merge-readiness-unresolved`; otherwise take the direct attempt above, whose exit `75` routes a base that still queues the PR, and never fall back to a raw `gh pr merge --auto`. Any other exit but `0` or `75` is an exact-head arm failure: surface it and return to § 3.2.

   Exit `75` means queued or armed. Run the command below through [Waiter launch](../references/waiter-launch.md), under every gate mode. Keep the lane active while polling the completion file, then route the recorded exit and result. A changes-requested review blocked at § 3.2's readiness check, before this arm; past it no mode reads review state. The wait's late-findings guard reads the review threads while the PR is queued or armed, an armed PR GitHub holds before any queue entry included, and its `dequeued` verdict routes an open thread to Late-findings triage: a thread posted after this step's thread read.

   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/queue-wait [PR_NUMBER] 180 540 --json --item [STATE_KEY]
   ```

   Keep the budget above `QUEUE_WAIT_ARM_GRACE` (`queue-wait --help` § Environment), so a slow enqueue is not read as `not_queued`. The detached process does not depend on the harness's foreground timeout.

   Route a completed log's verdict through the table below. If the completion file records an exit other than `5` without a result object, report the exit and stop: `queue-wait --help` § Exit codes defines those failures. Follow [Waiter launch](../references/waiter-launch.md) § Completion when no exit is recorded.

   Every wait in this sequence follows an exit `75`: GitHub reported the PR queued or armed. Each new wait resets its queue history (`queue-wait --help` § Verdicts). A later `not_queued` therefore means that arm cleared between waits, not that no arm occurred.

   Under Codex, run the saved launch script as one simple command ([references/codex-runtime.md](../references/codex-runtime.md)).

   | `verdict` | Route |
   |-----------|-------|
   | `merged` | Step 2 |
   | `conflicting` | The guarded Restack cycle below |
   | `ejected` | Recovery cycle below, using the resolved gate mode and `[RECOVERY_COUNT]` |
   | `disarmed` | Recovery cycle below |
   | `armed_blocked` | Armed, never enqueued, and GitHub will not enqueue it. `cause: check_failed` takes the Recovery cycle below. `cause: not_mergeable` means every check passed, so ci-fix has no failure to work: return to § 3 for a fresh readiness check, which names what keeps the PR out of the queue, spending no recovery cycle; a second `not_mergeable` on the same head hands back with that check's result |
   | `dequeued` | Late-findings triage below; on `cause: late_findings_dequeue_failed` confirm the dequeue or the disarm first |
   | `queued` | Unconfirmed at the deadline. With an entry (every cause but `exit_unconfirmed`) the PR is still armed: `cause: still_progressing` means the merge is live: run the wait again, and keep repeating until a verdict terminates it. `cause: progress_unobservable` means the queue entry's head could not be read, which is not evidence of an idle queue: run the wait again on the same head under the bound below, rather than straight into the Recovery cycle. `cause: stalled` takes the Recovery cycle below. `cause: exit_unconfirmed` is not armed: the last poll saw the PR out of the queue and unarmed, short of the confirmation count (`unconfirmed_verdict` names which), so do not wait for it to merge; run the wait once more, which reads the arm afresh, and route its verdict |
   | `armed_awaiting_checks` | Armed, not yet enqueued, no check failed: GitHub enqueues the PR when its required checks pass. Run the wait again on the same head, spending no recovery cycle, under the wall-clock budget below |
   | `not_queued` | The arm this step made is gone — an ejection or a silent disarm — not a merge that never fired. Take the Recovery cycle below, where `ejected` and `disarmed` already go. Never re-arm here: the head's merge-group run has just failed, and re-arming it into a shared queue can eject the PRs batched with it |
   | `closed` | Hand back with the verdict; no replay |
   | `unknown` | Unrecognized, or `status: error` — a read failed and says nothing about the arm, which after exit `75` is usually still live. Unarm before handing back, by § 1's no-armed-hand-back rule. Hand back with the `error` and `cause` fields, and never re-arm |

   A `still_progressing` repeat has no limit. Keep the lane active until a terminal verdict; after a merge, run steps 2-6.

   For `armed_awaiting_checks`, record the time of the first such result on this head and read the budget once:

   ```bash
   .agents/skills/orch/scripts/orch-env QUEUE_WAIT_ARMED_MINUTES 90
   ```

   Repeat the wait while that many minutes have not passed since the recorded time; a new head, or any other verdict, clears the record. Past the budget, hand back with the last result's `pending_checks` (under `cause: checks_unread` there are none: say the check rollup was never read) and the minutes waited, skipping steps 2-6: the budget, not `CI_FIX_MAX_CYCLES`, bounds a wait on checks that have not failed.

   For `progress_unobservable`, repeat once on the same head. A second consecutive `progress_unobservable` takes the Recovery cycle, as `stalled` does. Keep the lane active for steps 2-6. The progress counts in `queue-wait --help` report what the wait could read; neither gates the route.

   **Recovery cycle** — route the failure back into ci-fix, never fix CI by hand:

   ```bash
   .agents/skills/orch/scripts/workflow-state cap CI_FIX_MAX_CYCLES
   ```

   Max `[MAX_CYCLES]` recovery cycles per merge-pr run. At the cap, report the failing check names, ci-fix's last error summary, and what each cycle attempted — never a bare "persistent failure" — then skip steps 2-6 and hand back. Use rerun-in-place only for flakes; gate or CI behavior changes need a fresh head.

   1. `⤵ workflows/ci-fix.md [PR_NUMBER] § 1-6 → § 5 step 1` with context `worktree`, `lifecycle: "managed"`, `issue_id`. For a queue ejection the failing run is the **merge-group** run (event `merge_group`), not necessarily the PR-head run — locate it via the failing check's run link or `gh run list --event merge_group --limit 10` and point ci-fix at it.
   2. Re-confirm the gate at the head about to be re-armed, under the `GATE_MODE` ci-fix returned (skip under `off`):

      ```bash
      env -u GH_REPO -u GITHUB_REPOSITORY .agents/skills/orch/scripts/approval-wait [PR_NUMBER] 15 300 --json --mode [GATE_MODE] --item [STATE_KEY] --base-checkout [REVIEW_BASE_CHECKOUT]
      ```

      A `copilot-error` answer takes [Copilot requests](../references/gates.md#copilot-requests), then re-runs this wait before re-arming.

      A `comments` answer takes § 3.3, then this wait again.

   3. Return to step 1 and wait.

   **Restack cycle** — the base, not CI, is the blocker. Follow `workflows/merge-pr-restack.md`, then return to step 1. Never route a conflict into ci-fix.

   **Late-findings triage** — the findings, not CI, are the blocker:

   1. On `cause: late_findings_dequeue_failed`, first apply the disarm-then-dequeue order and PR-node-id lookup from `merge-pr-restack.md`; the PR must be out of the queue before triage pushes.
   2. Run § 3.3. With the head unmoved, return to step 1 and wait.

2. **Complete the issue and close a finished container** — **Linear only**. Skip the WHOLE step for GitHub work items: resolve the tracker first; an `issue-N` key in any casing is a GitHub item.

   The lane owns completion after merge. The overseer owns the remaining post-merge checks on the same item.

   Give every development remainder from a cut its own issue or bundle before completion. Prove every branch-provable Done-when box before merge. Keep post-merge boxes on `[ISSUE]` in the form the project-management skill's SKILL.md § Disposition states. Each box names its reading, location, why the branch cannot prove it, and a UTC deadline no later than three days after merge.

   Linear's GitHub integration can set `[ISSUE]` Done when the PR merges. Read the item live and use the completion command below. It sets Done when no post-merge box remains open, and Verifying otherwise, including when the integration already set Done. The merge lane never writes In Review or In Progress. The overseer records evidence and ticks each verified box. For a failed post-merge check, follow [oversee-events.md § Verification](../references/oversee-events.md).

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/linear/scripts/linear.sh issues get [ISSUE]
   ```

   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY gh pr view [PR_NUMBER] --json mergedAt --jq .mergedAt
   ```

   Use that live UTC timestamp as `[MERGED_AT]`. An absent or unreadable timestamp is a tracker-completion failure.

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/linear/scripts/linear.sh issues complete [ISSUE] --post-merge-at [MERGED_AT] --done-when-met [MET_BOXES]
   ```

   A rate-limited completion is held under the linear skill's `patterns/workflow-actions.md` § Quota Holds, never recorded as a failed step.

   `[MET_BOXES]` names only boxes with recorded proof. Use `all` only when every box has proof. Otherwise use their numbers in section order from 1, comma-separated. When no new box has proof, omit `--done-when-met`. The command refuses an open branch-provable box or invalid post-merge metadata before any write. A section with plain bullets and no checkbox takes `all`, which ticks nothing and sets Done.

   A canceled or unreadable issue is a tracker failure, not a completed merge record. Carry the diagnostic into § 6 and do not claim tracker completion.

   **The container closes LAST.** If `[ISSUE]` was the final open child of a container parent, complete the container now. Skip when no `[ISSUE]` was extracted.

   a. Read `.parent_id` (`issues get [ISSUE]`). Empty → step 3. b. Fetch the parent with its bundle. A `(one PR)` title marker keeps it single-PR; without the marker, children or an `agent:multi` label make it a CONTAINER. Not a container → step 3. c. Close the container through the serialized helper:

      ```bash
      env -u GH_REPO -u GITHUB_REPOSITORY [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/container-close [MAIN_REPO_ROOT] [PARENT_ID]
      ```

      `closed [PARENT_ID]` → record the closure in § 6 with every stderr diagnostic from the helper. If this container has a container parent, repeat a-c for that parent.

      `deferred [CHILD_IDS...]` → record `container [PARENT_ID] stays open (pending: [CHILD_IDS])` in § 6 and continue to step 3. When `[ISSUE]` is among `[CHILD_IDS]`, read its state live. Verifying → report `container [PARENT_ID] awaits verification of [ISSUE]`; the overseer closes the container after verification sets the child Done, under [oversee-events.md § Event kinds](../references/oversee-events.md#event-kinds). Any other open state → report `closure for [ISSUE] has not propagated; rerun merge-pr`. A failed state read remains a tracker failure. A bare `deferred` means the 120-second lock wait expired; report that and continue.

      `held [PARENT_ID] [REQUESTS_RESET]` → Linear rate-limited the completion. Hold this helper command under the linear skill's `patterns/workflow-actions.md` § Quota Holds; the helper keeps the bundle summary it built, which its next run posts only where the parent still has none. The rerun's output routes through this list. When the hold returns the command instead, record `container [PARENT_ID] held until [REQUESTS_RESET]; rerun merge-pr after it` in § 6, or `container [PARENT_ID] held; Linear gave no reset time` where `[REQUESTS_RESET]` is `unavailable`, with the helper's stderr diagnostics, do not climb to another parent, and continue to step 3.

      On a non-zero exit, carry its diagnostic into § 6, do not climb to another parent, and continue to step 3; the container stays OPEN and the close is safe to repeat once the diagnostic's cause is gone — a failed `gh pr list` among them — so report `container [PARENT_ID] stays open; rerun merge-pr to close it`. Re-running costs nothing when the parent is already complete: the helper short-circuits to `closed`.

3. **Sync the main repo** — always runs after a merge.

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/sync-base [MAIN_REPO_ROOT]
   ```

   Its stdout is `[BASE_BRANCH]`. On success, read `refs/heads/[BASE_BRANCH]` for `[NEW_SHA]` and report it in § 6. On a non-zero exit, the base remains unsynchronized. Carry the helper's diagnostic into the § 6 warning, resolve `[BASE_BRANCH]` with `resolve-base-branch`, then collect the warning SHAs before cleanup:

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/resolve-base-branch [MAIN_REPO_ROOT]
   git -C [MAIN_REPO_ROOT] rev-parse "refs/heads/[BASE_BRANCH]"
   git -C [MAIN_REPO_ROOT] rev-parse "refs/remotes/origin/[BASE_BRANCH]"
   ```

   The outputs are `[LOCAL_SHA]` and `[ORIGIN_SHA]`. A failed ref read stays in the warning as its cause. Never record the sync as done.

4. **Prepare branch and worktree cleanup**, scoped to this PR by default — never enumerate unrelated branches or sibling worktrees.

   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY gh pr view [PR_NUMBER] --json headRefName --jq .headRefName
   ```

   **Worktree disposal is by rule, and the rule is one predicate.** It holds when the PR's worktree exists, its tree is clean, and its checked-out branch is still `[PR_BRANCH]`. The two readable facts:

   ```bash
   git -C [WORKTREE_PATH] status --porcelain
   ```

   ```bash
   git -C [WORKTREE_PATH] branch --show-current
   ```

   Empty output from the first, `[PR_BRANCH]` from the second. Otherwise the cause is `dirty tree` or `branch moved`, and a command that exits non-zero fails its own fact as `tree unreadable` or `branch unreadable`: the predicate answers only where it can prove a fact, never from absent output.

   Step 6 runs this predicate WHOLE immediately before the removal and removes only when every part holds. Anything else keeps the worktree and its checked-out branch with the cause the predicate named (a worktree kept on another branch leaves the merged branch to the standalone delete below), and that cause goes on § 6's worktree line. A fact added to the predicate later is covered without step 6 changing.

   **The merged predicate is `worktree cleanup`'s**: ancestry into the repository's default branch, or, when ancestry fails, a pull request merged into that same default branch whose head commit is the local branch's tip. A squash merge leaves no ancestry, so the second proof is the one that applies to every PR landing through the queue, and it is the commit that proves it — a branch carrying commits past its merged PR is unmerged work. `worktree remove` applies the predicate itself when deleting the branch: a nonzero exit after the tree is gone means the branch survived, and the diagnostic names the answer the lookup gave; carry that as `kept` in the § 6 `Branch` row.

   With no qualifying worktree, delete the local `[PR_BRANCH]` only when no worktree owns it. Confirm first:

   ```bash
   git -C [MAIN_REPO_ROOT] worktree list --porcelain
   ```

   A `branch refs/heads/[PR_BRANCH]` line means a worktree still has it checked out: do not delete, and note it in § 6. No such line, and the branch exists locally and is not current → apply the predicate before deleting, never worktree ownership alone:

   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY gh pr view [PR_NUMBER] --json headRefOid --jq .headRefOid
   ```

   ```bash
   git -C [MAIN_REPO_ROOT] rev-parse "refs/heads/[PR_BRANCH]"
   ```

   Equal → `git -C [MAIN_REPO_ROOT] branch -D "[PR_BRANCH]"`. Different → the branch carries commits the merge did not take: keep it and report it `kept` in the § 6 `Branch` row. Never `git branch -d` here — it proves merge against the branch's configured upstream, which `worktree push` sets, so it passes for any pushed branch however far it is from `[BASE_BRANCH]`.

   For `merge-pr all` or an explicit user request, also sweep the project. Check each local branch with `env -u GH_REPO -u GITHUB_REPOSITORY gh pr list --head [BRANCH] --base [BASE_BRANCH] --state all --json number,state,headRefOid,isCrossRepository`, and auto-delete only a branch with no worktree whose tip equals the `headRefOid` of one of its **merged**, non-cross-repository PRs — the predicate `worktree cleanup` applies. Neither state nor a merge into another base is the test: a closed PR merged nothing, a PR merged into a release or other side branch left its commit out of `[BASE_BRANCH]` with this ref possibly the last ordinary one holding it, and a merged PR whose head differs from the tip left the extra commits reachable from this ref alone. Leave every other branch alone, and ask before removing a stale worktree or a branch with no PR. Compare `ls [TREES_DIR]/` against `worktree list --porcelain` for orphan directories, asking before removing any.

5. **Answer the threads the wait's guard did not catch.** GitHub's merge queue never re-checks thread resolution once a PR is admitted. `queue-wait`'s late-findings guard does, but on its own probe clock (`QUEUE_WAIT_PROBE_INTERVAL`, 120 seconds by default), so a finding landing inside that gap, or after the merge itself, rides the merge in. A PR [submit-pr.md](submit-pr.md) § 2 step 5 armed at creation has a wider gap, accepted: GitHub can enqueue it while the lane is still in submit-pr § 3-§ 6, and a thread posted between that enqueue and the guard step 1's queue wait starts rides the merge in the same way. Read the merged PR's unresolved threads once and answer each. Resolve the merge commit first — the queue merged a head this lane never saw:

   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY gh pr view [PR_NUMBER] --json mergeCommit --jq .mergeCommit.oid
   ```

   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY [MAIN_REPO_ROOT]/.agents/skills/github/scripts/github.sh -C [MAIN_REPO_ROOT] pr-threads [PR_NUMBER] --unresolved
   ```

   That oid is `[MERGE_SHA]`. Each reply is one of the three dispositions ([references/finding-disposition.md](../references/finding-disposition.md)): `Declined: [reason]`, `Fixed in [MERGE_SHA]`, or `Tracked: [ISSUE_ID]` with the issue created first under [skill-rules.md § Coordination](../references/skill-rules.md#coordination). Reply and resolve through `github.sh post-reply` and `github.sh resolve-thread`, under the section's clearing rule and `-C [MAIN_REPO_ROOT]` like the read above. This read happens once. A thread landing after it is unhandled: nothing else reads a merged PR's threads.

6. **Verify the project and remove the worktree.** Run the build, install, and verification work the project's own instructions require after a merge; this workflow defines no generic command and does not infer one. A project's install record (`.kendex-lock.json`) is recorded by the route its own instructions name, never re-recorded by the lane after a merge or a restack. On failure, report the command and its diagnostic in § 6 and keep the worktree. Once it passes, close the item out under the main checkout's state directory, `tmp/` under `[MAIN_REPO_ROOT]` by default, before worktree removal. Where § 4 found an issue worktree, name its `tmp/` for the close-out's archive; otherwise drop the `--archive` pair:

   ```bash
   .agents/skills/orch/scripts/workflow-state remove [STATE_KEY] --archive [WORKTREE_PATH]/tmp
   ```

   What it takes, archives and keeps is [schemas/workflow-state.md § Item close-out](../schemas/workflow-state.md#item-close-out). Its `removed kept=` line names the archive holding the item's state and the worktree's `tmp/` records, and goes on § 6's `tmp/ close-out` line. A refusal keeps the worktree, since the worktree's records may be in no archive: the refusal's first line goes on that line instead, and the worktree line reads `standing — close-out refused`.

   With the project verification passed and the close-out done, re-run step 4's disposal predicate whole. Step 4 read it two steps ago, and step 5's replies and this step's build can each dirty the tree or move the branch. `worktree remove` runs `git worktree remove --force` and then `rm -rf`, so it refuses nothing itself: uncommitted content, untracked content and a worktree that has moved to another branch all go with the directory, and the predicate is the only thing between them and that.

   Every part holding removes it, run from `[MAIN_REPO_ROOT]` so the lane is not deleting its own cwd:

   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY [MAIN_REPO_ROOT]/.agents/skills/worktree/scripts/worktree remove [ISSUE]
   ```

   For any close-out notice, follow [skill-rules.md § Lane mail](../references/skill-rules.md#coordination): send it after removal returns, from `[MAIN_REPO_ROOT]`.

   A foreign-lease refusal from the helper keeps the worktree too; carry its diagnostic onto § 6's worktree line. Where § 4 found an issue worktree, read its path last, whichever way the removal went:

   ```bash
   ls -d -- "[WORKTREE_PATH]"
   ```

   A `No such file or directory` is the removal; a listed path is a worktree still standing. § 6 is written after this step, never before.

## 6. Present Results

Output: [Lane Output](../references/skill-rules.md#lane-output).

<output_format>

### ✅ MERGED — PR #[N]: [TITLE]

| Field | Value |
|-------|-------|
| Branch | [BRANCH_NAME] (deleted / kept) |
| Issue Tracker | [ISSUE_ID] → Done / still open — [tracker result or cause from § 5 step 2] |
| Container | [PARENT_ID] → Done / deferred — [pending ids, restorations, or cause] |
| Base sync | local `[BASE_BRANCH]` → [NEW_SHA] |

tmp/ close-out: [KEPT_LINE_OR_FIRST_REFUSAL_LINE]

Worktree `[WORKTREE_PATH]` gone / standing — [cause]

</output_format>

The `Container` row appears only when § 5 step 2 found a container parent. When § 5 step 3 hit a blocking outcome it carries the warning instead of a sha: `⚠️ local [BASE_BRANCH] STALE at [LOCAL_SHA] (origin/[BASE_BRANCH] at [ORIGIN_SHA]) — [CAUSE]`. The worktree line closes the block with step 6's read: `gone`, or `standing — [cause]` — the cause step 4's disposal predicate named, or `foreign lease` from the helper, or `project verification failed`, or `close-out refused`. Omit it only where § 4 found no issue worktree. The `tmp/ close-out` line carries step 6's `removed kept=` line from `workflow-state remove`, or the first line of its refusal, and is omitted where that command never ran. Add a `Review gate` row only when the merge did not proceed on a plain `approved` verdict — `⚠️ reviewer-down proceed (no reviewer posted; PR_REVIEW_ON_TIMEOUT=proceed)` or `⚠️ forced (user override)`.

For `merge-pr all`, add the cross-PR analysis and a merge table:

Output: [Lane Output](../references/skill-rules.md#lane-output).

<output_format>

### 📋 MERGE SUMMARY

| Status | PR | Issue | Note |
|--------|-----|-------|------|
| ✅ | #[N] | [ISSUE_ID] - [TITLE] | Merged |
| ⏭️ | #[P] | [ISSUE_ID] - [TITLE] | Review threads |
| ❌ | #[Q] | [ISSUE_ID] - [TITLE] | Merge conflicts |

Total: [N] PRs merged | Base sync: local `[BASE_BRANCH]` → [NEW_SHA]

Legend: ✅ merged  ⏭️ skipped (user)  ❌ skipped (error)

</output_format>

## 7. Return

The merge is complete once § 5 steps 1-6 have run. A lane at its prompt whose issue worktree still stands, with no cause on § 6's worktree line, has not finished. A run that handed back at a non-merged verdict reports that verdict and ends; it does not resume.
