# PR Merge Workflow

Verify the merge conditions and merge PR(s).

| Command | Flow |
|---------|------|
| `merge-pr` | List ready PRs, user selects |
| `merge-pr [N]` | Merge a specific PR |
| `merge-pr all` | Merge all ready PRs in sequence |

**Caller context** (via `⤵`): `merge_mode` defaults to `normal`; only `submit-pr.md` § 6.2 sets `admin`, and only on an explicit answer.

## 1. Identify Candidates

```bash
.agents/skills/github/scripts/github.sh pr-list-ready
```

With no argument, present the list and ask which to merge. With `all`, process every ready PR sequentially.

**`merge_mode: admin` goes straight to § 4**, running § 3's per-PR state
resolution on the way and nothing else in § 2 or § 3.

Resolve the decision mode once for every post-PR choice in this workflow. Named stops use [SKILL.md § The Cycle](../SKILL.md#the-cycle).

```bash
.agents/skills/orch/scripts/orch-env ORCH_DECISION_MODE auto-recommended
```

Bind the repository root as `[MAIN_REPO_ROOT]` and create the directory every
stop below renders into, before any stop route can fire. Every stop this
workflow records is written under that root, so none of them depends on
`[WORKTREE_PATH]`, which § 4 binds and most of the stop routes run before:

```bash
.agents/skills/orch/scripts/git-context common-root .
```
```bash
mkdir -p [MAIN_REPO_ROOT]/tmp
```

**Stop routes.** Every `records [STOP_NAME]` branch below records against the
`[STATE_KEY]` § 3 resolved for the PR it is stopping, renders into the one path
this workflow uses, and posts that file on that PR:

```bash
.agents/skills/orch/scripts/workflow-state post-pr-stop record [STATE_KEY] [STOP_NAME] [GATE] "[REMAINING]" [MAIN_REPO_ROOT]/tmp/post-pr-stop-[STATE_KEY].md
```
```bash
env -u GH_REPO -u GITHUB_REPOSITORY .agents/skills/github/scripts/github.sh post-comment [PR_NUMBER] --body-file [MAIN_REPO_ROOT]/tmp/post-pr-stop-[STATE_KEY].md
```

## 2. Cross-Check (batch merges only)

**Skip if** fewer than two PRs are in scope.

This section is the one run-level step, so its stop needs a PR to record
against: run § 3's per-PR state resolution for the FIRST PR in the reported
order, and record and post both stops below against that PR.

```bash
.agents/skills/github/scripts/github.sh pr-cross-check [PR_NUMBERS] --quick --json
```

High-severity findings (conflicts) show the issues, then `auto-recommended` records `batch-cross-check-failed`; `ask` stops with them shown. Otherwise verify:

```bash
.agents/skills/github/scripts/github.sh pr-cross-check [PR_NUMBERS] --verify --json
```

`can_batch_merge: true` → § 3 in the reported `merge_order`. `false` → show the merge, build, and test failures with their suggested remediation; `auto-recommended` records `batch-cross-check-failed`, and `ask` presents `Abort` | `Force anyway`, with `Abort` recommended.

## 3. Check Merge Readiness

**Per-PR state resolution.** This block runs once per PR in scope, never once
per run: on the `merge-pr all` route, resolving once would bind the first PR's
key to every later PR and collide their stops in one state file. Use the
extracted issue as `[STATE_KEY]` when present, otherwise use `pr-[PR_NUMBER]`;
run `init` only when `exists` is false. § 4 reuses the `[ISSUE]` and
`[PR_BRANCH]` this reads.

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

```bash
.agents/skills/github/scripts/github.sh pr-merge [PR_NUMBER] --check
```

### 3.1 Resolve Transient Blockers First

`CHECK.transient == true` → route on the issue prefix before any user prompt, and never loop indefinitely. Continue to § 3.2 once `transient` is `false` or the bounded wait expires.

| Prefix | Wait |
|--------|------|
| `unknown:` (GitHub still computing mergeable status) | `github.sh await-mergeable [PR_NUMBER]`, then re-check. Exit 124 on timeout → `auto-recommended` records `merge-readiness-unresolved`; `ask` surfaces the timeout |
| `ci_pending:` | `.agents/skills/orch/scripts/ci-wait [PR_NUMBER] 15 600`, then re-check. On a non-zero exit or timeout, re-check once for fresh state; if still pending, `auto-recommended` records `merge-ci-pending`, while `ask` surfaces the result. Never another automatic wait |
| `ci_fetch_failed:`, `ci_unconfigured:` | Re-check, at most three checks total, then continue with the latest `CHECK` |

### 3.2 Act On The Result

`CHECK.state` decides first: `MERGED` → set `[ALREADY_MERGED]=true`, run § 4 EXCEPT § 4.1, then enter § 5 step 1, which skips the arm and the wait and goes straight to post-merge work; `CLOSED` → records `pr-closed-unmerged`.

`can_merge: true` → § 4, showing any warnings. `false` → show the issues with their suggested fixes. `auto-recommended` logs `Fix and retry` and takes that route once; the same blocker after the retry records `merge-check-blocked`. `ask` presents `Skip` | `Fix and retry` | `Force merge`, with `Fix and retry` recommended.

Two warnings are merge gates, not advice:

- **`unresolved_threads`** — zero unresolved review threads is required at merge time. Route to `review-pr-comments` to reply and resolve first. `auto-recommended` keeps triaging within `REVIEW_MAX_EXTERNAL_ROUNDS`, then records `review-threads-open`; merge past them only on explicit user override.
- **`not_approved`** — resolve the project's gate mode first with `.agents/skills/orch/scripts/approval-wait --resolve-mode` ([references/gates.md](../references/gates.md)) and route on the printed `GATE_MODE`:
  - `off` — informational only; do not gate on it.
  - `review` — `not_approved` is expected. Poll `approval-wait [PR_NUMBER] 30 --json --mode review` and treat `reviewed` as the met gate.
  - `approval` — a GitHub-native approval verdict is required. Without it, do not auto-merge: poll `approval-wait [PR_NUMBER] 30 --json`; after its budget, `auto-recommended` records `review-gate-unmet`, while `ask` presents the wait or stop choice.

  With `PR_REVIEW_ON_TIMEOUT=proceed`, a deadline reached with zero unresolved threads and no reviewer evidence returns `proceeded` (exit 0) instead of `timeout` in both modes — treat it as a met gate and record it in the § 6 report. An open thread or a `changes_requested` still blocks. The proceed is a LOCAL verdict — orch posts no status.

  Merge past a missing gate verdict only on an explicit user `Force merge`.

Bot-specific signals — emoji reactions, sticky-comment prose, checklist text — are never parsed as merge gates. Only GitHub-native review state and the thread-resolution count count.

## 4. Prepare

```bash
.agents/skills/worktree/scripts/worktree exists "$ISSUE"
.agents/skills/worktree/scripts/worktree path "$ISSUE"
.agents/skills/github/scripts/github.sh bot-token
```

Reuse the `[ISSUE]` and `[PR_BRANCH]` § 3 resolved for this PR, and worktree
commands only with an `[ISSUE]`. When no issue worktree exists, set
`[WORKTREE_PATH]` to `[MAIN_REPO_ROOT]`, the root § 1 bound; there is then no
issue worktree to dispose of in § 5.

`merge_mode: admin` merges as the current user by design, so skip `bot-token`
for it. Otherwise `bot-token` reporting `.configured: false` is an identity
decision, not a budget choice: the merge would land under the human's name.
`auto-recommended` records `bot-auth-missing` rather than taking that decision;
`ask` presents `Merge as current user` | `Abort`, with `Abort` recommended.

### 4.1 Detach Orphaned Children

**Skip if** no `[ISSUE]` was extracted, or `TRACKER=github`.

```bash
.agents/skills/linear/scripts/linear.sh cache issues children [ISSUE] --pending --recursive
```

Partition by `state_type`: `backlog` and `unstarted` are **safe** (`[SAFE_IDS]`); anything else is **active**. Both empty → § 5.

Active children pause the merge and ask the user per orphan — was the work landed in this PR? Yes closes it Done; no appends it to `[SAFE_IDS]`; abort stops § 4.1 entirely.

`[SAFE_IDS]` still empty → § 5. Otherwise rebundle them under a new parent:

```bash
.agents/skills/linear/scripts/linear.sh cache issues get [ISSUE]
```

Read `.title`, `.project.id`, and the joined label names for the new bundle, and take `[BUNDLE_PRIORITY]` as the highest priority across `[SAFE_IDS]` (Linear: `1`=Urgent…`4`=Low, lower wins; default `3`). Build `[BUNDLE_DESC]` per `.agents/skills/project-management/templates/parent-issue-template.md`, with a `## Sub-Issues` list and a `## Context` line naming the detachment. Its `**Reached by**` line is this rebundle run: `this merge-pr rebundle, detaching pending children from [ISSUE] before merge`. A rebundle parent is structural, so the create passes no `--review-born`.

```bash
.agents/skills/linear/scripts/linear.sh issues create --state "Backlog" --title "[PARENT_TITLE] follow-ups" --description "[BUNDLE_DESC]" --project "[PARENT_PROJECT]" --labels "[PARENT_LABELS]" --priority [BUNDLE_PRIORITY] --format=ids
```

A non-zero exit or empty output **aborts the merge**. Otherwise reparent each safe id (one call each), link the bundle back, and comment on the original:

```bash
.agents/skills/linear/scripts/linear.sh issues update [SAFE_ID] --parent [NEW_BUNDLE]
```
```bash
.agents/skills/linear/scripts/linear.sh issues add-relation [NEW_BUNDLE] --related [ISSUE]
```
```bash
.agents/skills/linear/scripts/linear.sh comments create [ISSUE] --body "Pending children rebundled under [NEW_BUNDLE] before merge to avoid cascade-Done."
```

## 5. Execute The Merge

Some harnesses reset cwd per shell call — prefer `-C` and absolute paths over `cd &&` chains.

**Clear `GH_REPO` and `GITHUB_REPOSITORY` on every command in this section
that reaches GitHub, fenced or inline.** `gh` honours them over both cwd and
`-C`, so an inherited value points a read at another repository and a mutation
at that repository's same-numbered PR — a `branch -D` authorized by the wrong
PR, or the queue wait's late-findings guard disarming and dequeuing someone
else's. Reaching GitHub is a property of the script rather than of the
command's spelling: a waiter, the `github.sh` router, `container-close` and
`worktree` all call `gh` inside. Before adding a command here, read the script
it names.

```bash
.agents/skills/orch/scripts/git-context common-root .
```

Use the output as `MAIN_REPO_ROOT`.

1. **Merge**, before any cleanup:

   Resolve the repository, gate mode, and exact head before any merge attempt.
   `[RECOVERY_COUNT]` is `0` initially and one more per recovery cycle taken in
   this run. Nothing persists it: a run resumed after a compaction, or
   relaunched by oversee's `window-gone` rule, starts a fresh budget. Read a run
   that keeps returning to ci-fix as the signal the cap is there for, whatever
   the count says.

   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY gh repo view --json nameWithOwner --jq .nameWithOwner
   ```
   Resolve the gate mode below, except `merge_mode: admin` sets it to `off`:

   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY .agents/skills/orch/scripts/approval-wait --resolve-mode
   ```
   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY gh pr view [PR_NUMBER] --json headRefOid --jq .headRefOid
   ```

   That head is `[PREPARED_HEAD]`. `[ALREADY_MERGED]=true` skips the mutation
   and the wait and continues to step 2. Otherwise attempt only the prepared
   head:

   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY [MAIN_REPO_ROOT]/.agents/skills/github/scripts/github.sh -C [MAIN_REPO_ROOT] pr-merge [PR_NUMBER] [--force|--admin] --expected-head [PREPARED_HEAD]
   ```

   `merge_mode: admin` uses `--admin`; no other path adds it.

   Exit `0` merged the prepared head — continue to step 2.

   Exit `1` from `--admin` records the named stop `merge-blocked` and hands
   back. It never falls through to the classification below and never arms
   `--auto`: the answer that authorized this merge named one head and one
   reason, and neither survives a re-route.

   Exit `1` BLOCKED on any other path → run `env -u GH_REPO -u GITHUB_REPOSITORY [MAIN_REPO_ROOT]/.agents/skills/github/scripts/github.sh -C [MAIN_REPO_ROOT] ci-classify-refusal [PR_NUMBER]` and route on its `cause:` line: `ci_pending` — or `none` when the merge output names a base branch requiring merges through a queue — → re-run the prepared head with `--auto`. Any other cause surfaces the detail and returns to § 3.2.

   The `--auto` re-run arms only that same head:

   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY [MAIN_REPO_ROOT]/.agents/skills/github/scripts/github.sh -C [MAIN_REPO_ROOT] pr-merge [PR_NUMBER] --auto --expected-head [PREPARED_HEAD]
   ```

   Exit `0` merged the prepared head immediately — continue to step 2. Any exit
   but `0` or `75` is an exact-head arm failure: surface it and return to § 3.2.

   Exit `75` means queued or armed. Wait it out here, blocking, and route the
   verdict it prints. The lane does not hand back and come look later: a lane
   sitting at its prompt has no next boundary, so a verdict published behind it
   waits for a human. No lane detaches this wait.

   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/queue-wait [PR_NUMBER] 30 540 --json
   ```

   The budget is spelled out because `queue-wait`'s own default (its `--help`
   § Usage) is longer than any agent harness holds a foreground call open. Size
   it under the harness's shell-tool ceiling and above `QUEUE_WAIT_ARM_GRACE`
   (`--help` § Environment), so a slow enqueue is not read as `not_queued` —
   the way `ci-wait` and `approval-wait` are sized where § 3.1 and the Recovery
   cycle call them. Never leave the default in place here.

   Stay on the call until it returns, and never poll merge state by hand. Three
   endings, and only the first two end the wait:

   - A verdict on stdout — route it on the table below.
   - No result object at all: `queue-wait --help` § Exit codes gives exit `2` to
     a usage error and exit `4` to a repository deleted mid-wait. Hand back
     naming the exit; do not retry.
   - The harness killed the call before it returned, so there is no exit code
     and no output. Run the same command again, but only once no `queue-wait`
     for this PR is still running: a harness that reports a timeout without
     reaping the child leaves two, and a wait is not read-only. Its
     late-findings guard issues `dequeuePullRequest` and its check probe
     delegates to `ci-wait`, which may re-run a workflow, so two waits race one
     dequeue and the loser reports `late_findings_dequeue_failed` for no reason
     but the overlap.

   Successive waits are the designed shape for a long queue, and this step is
   reached only after an exit-`75` arm, which is GitHub reporting the PR queued
   or auto-merge enabled. That holds for every wait in the sequence and no wait
   can lose it, which is what the `not_queued` row below rests on: each wait
   starts with the queue priors of `queue-wait --help` § Verdicts reset, so a
   wait that never itself saw the PR queued says `not_queued` whatever came
   before it — and after an exit-`75` arm that reads as an arm cleared in the
   seam, never as one that was never made.

   Under Codex the blocking call is the only shape the classifier accepts
   ([references/codex-runtime.md](../references/codex-runtime.md)).

   | `verdict` | Route |
   |-----------|-------|
   | `merged` | Step 2 |
   | `conflicting` | The guarded Restack cycle below |
   | `ejected` | Recovery cycle below, using the resolved gate mode and `[RECOVERY_COUNT]` |
   | `disarmed` | Recovery cycle below |
   | `dequeued` | Late-findings triage below; on `cause: late_findings_dequeue_failed` confirm the dequeue or the disarm first |
   | `queued` | Still armed at the deadline. `cause: still_progressing` means the merge is live: run the wait again, and keep repeating until a verdict terminates it. `cause: stalled` takes the Recovery cycle below |
   | `not_queued` | The arm this step made is gone — an ejection or a silent disarm — not a merge that never fired. Take the Recovery cycle below, where `ejected` and `disarmed` already go. Never re-arm here: the head's merge-group run has just failed, and re-arming it into a shared queue can eject the PRs batched with it |
   | `closed` | Hand back with the verdict; no replay |
   | `unknown` | Unrecognized, or `status: error` — a read failed and says nothing about the arm, which after exit `75` is usually still live. Unarm before handing back, in `merge-pr-restack.md` step 1's order: disable auto-merge if `autoMergeRequest` is set, then dequeue via GraphQL if `isInMergeQueue` is still true, then re-read both. Hand back with the `error` and `cause` fields, and never re-arm |

   A `still_progressing` repeat is left unbounded on purpose. It terminates:
   the signal stays true only while a check-run is not completed or the queue
   entry is still moving, and GitHub's own workflow timeout finally fails a run
   whose runner died. Entry movement ends too — a position only falls, so the
   PR reaches the front and merges or leaves the queue. Returning early
   would leave the PR armed with the merge free to fire behind a departed lane,
   and steps 5 and 6 would never run on it — which is the whole reason the lane
   waits here rather than handing back.

   **Recovery cycle** — route the failure back into ci-fix, never fix CI by hand:

   ```bash
   .agents/skills/orch/scripts/workflow-state cap CI_FIX_MAX_CYCLES
   ```

   Max `[MAX_CYCLES]` recovery cycles per merge-pr run. At the cap, report the failing check names, ci-fix's last error summary, and what each cycle attempted — never a bare "persistent failure" — then skip steps 2-6 and hand back. Use rerun-in-place only for flakes; gate or CI behavior changes need a fresh head.

   1. `⤵ workflows/ci-fix.md [PR_NUMBER] § 1-6 → § 5 step 1` with context `worktree`, `lifecycle: "managed"`, `issue_id`. For a queue ejection the failing run is the **merge-group** run (event `merge_group`), not necessarily the PR-head run — locate it via the failing check's run link or `gh run list --event merge_group --limit 10` and point ci-fix at it.
   2. Re-confirm the gate at the head about to be re-armed (skip when `GATE_MODE` is `off`):

      ```bash
      env -u GH_REPO -u GITHUB_REPOSITORY .agents/skills/orch/scripts/approval-wait [PR_NUMBER] 15 300 --json --mode [GATE_MODE]
      ```

   3. Return to step 1's exact-head arm and wait.

   **Restack cycle** — the base, not CI, is the blocker. Follow `workflows/merge-pr-restack.md`,
   then return to step 1's exact-head sequence. Never route a conflict into ci-fix.

   **Late-findings triage** — the findings, not CI, are the blocker:

   1. On `cause: late_findings_dequeue_failed`, first apply the disarm-then-dequeue order and PR-node-id lookup from `merge-pr-restack.md`; the PR must be out of the queue before triage pushes.
   2. `⤵ workflows/review-pr-comments.md [PR_NUMBER] § 1-8 → § 5 step 1` with managed context — every new thread replied to and resolved.
   3. Triage may have pushed a new head. Return to step 1's exact-head arm and wait.

2. **Sync the tracker and close a finished container** — **Linear only**. Skip the WHOLE step for GitHub work items: resolve the tracker first; an `issue-N` key in any casing is a GitHub item.

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/linear/scripts/linear.sh sync --reconcile
   ```

   The lane owns tracker completion; the overseer does not substitute for it. When `[ISSUE]` was extracted, read it from the synced
   cache. A completed state needs no write. A live state completes now:

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/linear/scripts/linear.sh cache issues get [ISSUE]
   ```
   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/linear/scripts/linear.sh issues complete [ISSUE]
   ```

   A canceled or unreadable issue is a tracker failure, not a completed merge
   record. Carry the diagnostic into § 6 and do not claim tracker completion.

   **The container closes LAST.** If `[ISSUE]` was the final open child of a container parent, complete the container now. Skip when no `[ISSUE]` was extracted.

   a. Read `.parent_id` (`cache issues get [ISSUE]`). Empty → step 3.
   b. Fetch the parent with its bundle. A `(one PR)` title marker keeps it single-PR; without the marker, children or an `agent:multi` label make it a CONTAINER. Not a container → step 3.
   c. Close the container through the serialized helper:

      ```bash
      env -u GH_REPO -u GITHUB_REPOSITORY [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/container-close [MAIN_REPO_ROOT] [PARENT_ID]
      ```

      `closed [PARENT_ID]` → record the closure in § 6 with every stderr diagnostic from the helper. If this container has a container parent, re-run the step-2 sync and repeat a-c for that parent.

      `deferred [CHILD_IDS...]` → record `container [PARENT_ID] stays open (pending: [CHILD_IDS])` in § 6 and continue to step 3. When `[ISSUE]` is among `[CHILD_IDS]`, report `closure for [ISSUE] has not propagated; rerun merge-pr`. A bare `deferred` means the 120-second lock wait expired; report that and continue. On a non-zero exit, carry its diagnostic into § 6, do not climb to another parent, and continue to step 3; the container stays OPEN and the close is safe to repeat once the diagnostic's cause is gone — a failed `gh pr list` among them — so report `container [PARENT_ID] stays open; rerun merge-pr to close it`. Re-running costs nothing when the parent is already complete: the helper short-circuits to `closed`.

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

   **Worktree disposal is by rule, and the rule is one predicate.** It holds
   when the PR's worktree exists, its tree is clean, and its checked-out branch
   is still `[PR_BRANCH]`. The two readable facts:

   ```bash
   git -C [WORKTREE_PATH] status --porcelain
   ```
   ```bash
   git -C [WORKTREE_PATH] branch --show-current
   ```

   Empty output from the first, `[PR_BRANCH]` from the second. Otherwise the
   cause is `dirty tree` or `branch moved`, and a command that exits non-zero
   fails its own fact as `tree unreadable` or `branch unreadable`: the
   predicate answers only where it can prove a fact, never from absent output.

   Step 6 runs this predicate WHOLE immediately before the removal and removes
   only when every part holds. Anything else keeps the worktree and its
   checked-out branch with the cause the predicate named (a worktree kept on
   another branch leaves the merged branch to the standalone delete below), and
   that cause goes in the § 6 `Worktree` row. A fact added to the predicate
   later is covered without step 6 changing.

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

5. **Answer the threads the wait's guard did not catch.** GitHub's merge queue
   never re-checks thread resolution once a PR is admitted. `queue-wait`'s
   late-findings guard does, but on its own probe clock
   (`QUEUE_WAIT_PROBE_INTERVAL`, 120 seconds by default), so a finding landing
   inside that gap, or after the merge itself, rides the merge in. Read the
   merged PR's unresolved threads once and answer each. Resolve the merge
   commit first — the queue merged a head this lane never saw:

   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY gh pr view [PR_NUMBER] --json mergeCommit --jq .mergeCommit.oid
   ```
   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY [MAIN_REPO_ROOT]/.agents/skills/github/scripts/github.sh -C [MAIN_REPO_ROOT] pr-threads [PR_NUMBER] --unresolved
   ```

   That oid is `[MERGE_SHA]`. Each reply is one of the three dispositions
   ([references/finding-disposition.md](../references/finding-disposition.md)):
   `Declined: [reason]`, `Fixed in [MERGE_SHA]`, or `Tracked: [ISSUE_ID]` with
   the issue created first, carrying its `Reached by` line. Reply and resolve
   through `github.sh post-reply` and `github.sh resolve-thread`, under the
   section's clearing rule and `-C [MAIN_REPO_ROOT]` like the read above.
   This read happens once. A thread landing
   after it is unhandled: nothing else reads a merged PR's threads.

6. **Verify the project and remove the worktree.** Run the build, install, and
   verification work the project's own instructions require after a merge; this
   workflow defines no generic command and does not infer one. On failure,
   report the command and its diagnostic in § 6 and keep the worktree.

   On success, re-run step 4's disposal predicate whole. Step 4 read it two
   steps ago, and step 5's replies and this step's build can each dirty the
   tree or move the branch. `worktree remove` runs `git worktree remove
   --force` and then `rm -rf`, so it refuses nothing itself: uncommitted
   content, untracked content and a worktree that has moved to another branch
   all go with the directory, and the predicate is the only thing between them
   and that.

   Every part holding removes it, run from `[MAIN_REPO_ROOT]` so the lane is
   not deleting its own cwd:

   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY [MAIN_REPO_ROOT]/.agents/skills/worktree/scripts/worktree remove [ISSUE]
   ```

   A foreign-lease refusal from the helper keeps the worktree too; carry its
   diagnostic into the § 6 `Worktree` row.

## 6. Present Results

<output_format>

### ✅ MERGED — PR #[N]: [TITLE]

| Field | Value |
|-------|-------|
| Branch | [BRANCH_NAME] (deleted / kept) |
| Worktree | removed / kept — [cause] |
| Issue Tracker | [ISSUE_ID] → Done (completed by the lane after merge) |
| Container | [PARENT_ID] → Done / deferred — [pending ids, restorations, or cause] |
| Base sync | local `[BASE_BRANCH]` → [NEW_SHA] |

</output_format>

The `Container` row appears only when § 5 step 2 found a container parent. The `Base sync` row is never omitted. When § 5 step 3 hit a blocking outcome it carries the warning instead of a sha: `⚠️ local [BASE_BRANCH] STALE at [LOCAL_SHA] (origin/[BASE_BRANCH] at [ORIGIN_SHA]) — [CAUSE]`. The `Worktree` row reports `removed`, or `kept — [cause]` — the cause step 4's disposal predicate named, or `foreign lease` from the helper, or `project verification failed` — when step 6 did not remove it (no worktree existed → omit the row). Add a `Review gate` row only when the merge did not proceed on a plain `approved`/`reviewed` verdict — `⚠️ reviewer-down proceed (no reviewer posted; PR_REVIEW_ON_TIMEOUT=proceed)` or `⚠️ forced (user override)`.

For `merge-pr all`, add the cross-PR analysis and a merge table:

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

The merge is complete once § 5 steps 1-6 have run. A run that handed back at a
non-merged verdict reports that verdict and ends; it does not resume.
