# PR Merge Workflow

Check the merge conditions of one or more pull requests, merge them, and close out their items.

| Command | Flow |
|---------|------|
| `merge-pr` | List ready PRs, user selects |
| `merge-pr [N]` | Merge a specific PR |
| `merge-pr all` | Merge all ready PRs in sequence |

- A step that differs for a lane ([skill-rules.md § Lane Output](../references/skill-rules.md#lane-output)) says so.
- A confined lane runs with `AGENT_RUNTIME_CONFINED=1` in its environment.
- [merge-contracts.md](../references/merge-contracts.md) holds the contracts this workflow applies at a stop, after an exit `75` and at worktree cleanup. A step names the section it takes.

## 1. Identify Candidates

```bash
.agents/skills/github/scripts/github.sh pr-list-ready
```

- With no argument, present the list and ask which PR to merge.
- With `all`, take every ready PR in turn.

Read the decision mode once. It governs every choice below, and an unset key reads `ask`:

```bash
.agents/skills/orch/scripts/orch-env ORCH_DECISION_MODE ask
```

Named stops follow [SKILL.md § The Cycle](../SKILL.md#the-cycle).

Bind the main checkout's root as `[MAIN_REPO_ROOT]`:

```bash
.agents/skills/orch/scripts/git-context common-root .
```

Every route below that ends the run without a merged PR, and every route that `records [STOP_NAME]`, takes [merge-contracts.md § Stop routes](../references/merge-contracts.md#stop-routes). That section unarms the PR first.

## 2. Cross-Check (batch merges only)

**Skip if** fewer than two PRs are in scope.

A stop here records against one PR:

1. Run § 3's per-PR state for the first PR in the reported order.
2. Record and post both stops below against that PR.

```bash
.agents/skills/github/scripts/github.sh pr-cross-check [PR_NUMBERS] --quick --json
```

Show any high-severity finding, which is a conflict. On one:

- `auto-recommended` records `batch-cross-check-failed`.
- `ask` stops.

With no such finding, verify:

```bash
.agents/skills/github/scripts/github.sh pr-cross-check [PR_NUMBERS] --verify --json
```

- `can_batch_merge: true` goes to § 3, in the reported `merge_order`.
- `can_batch_merge: false`: show the merge, build and test failures with their suggested remediation. Then:
  - `auto-recommended` records `batch-cross-check-failed`.
  - `ask` presents `Abort` | `Force anyway`, recommending `Abort`.

## 3. Check Merge Readiness

**Per-PR state.** Run this block once for each PR in scope, never once per run. Read the PR's issue, then its branch:

```bash
.agents/skills/github/scripts/github.sh pr-issue [PR_NUMBER] --format=text
```

```bash
env -u GH_REPO -u GITHUB_REPOSITORY gh pr view [PR_NUMBER] --json headRefName --jq .headRefName
```

- `[STATE_KEY]` is the extracted issue. With no issue, it is `pr-[PR_NUMBER]`.
- § 4 reuses this `[ISSUE]` and `[PR_BRANCH]`.

Read whether the item has state:

```bash
.agents/skills/orch/scripts/orch-runtime state exists --item [STATE_KEY]
```

Run `init` only where `exists` reads `false`:

```bash
.agents/skills/orch/scripts/orch-runtime state init --item [STATE_KEY] --branch [PR_BRANCH]
```

Then clear any earlier stop:

```bash
.agents/skills/orch/scripts/orch-runtime state post-pr-stop clear --item [STATE_KEY]
```

Bind `[ITEM_DIR]` to the folder that holds the record path this command prints as `result.path`:

```bash
.agents/skills/orch/scripts/orch-runtime state path --item [STATE_KEY]
```

Write every stop comment, review request and notice of this workflow in `[ITEM_DIR]`.

**The merge's review call.** Every review call in this workflow is [the review call](../references/gates.md#the-review-call).

- Bind `[REVIEW_BASE_CHECKOUT]` by [gates.md § Gate-mode routing](../references/gates.md#gate-mode-routing).
- Run the call from `[MAIN_REPO_ROOT]`, with `[MARK_READY]` `false`, and its request file in `[ITEM_DIR]`.
- `[OWNER/REPO]` is the answer of `env -u GH_REPO -u GITHUB_REPOSITORY gh repo view --json nameWithOwner --jq .nameWithOwner` there.
- gates.md owns the reply's fields, verdicts and refusals.

```bash
jq -cn --arg repo "[OWNER/REPO]" --argjson pr [PR_NUMBER] --arg base "[REVIEW_BASE_CHECKOUT]" --argjson ready false \
  '{op: "verify-review", repo: $repo, pr: $pr, base_checkout: $base, mark_ready: $ready}' \
  > "[ITEM_DIR]/verify-review-request-[STATE_KEY].json"
.agents/skills/orch/scripts/orch-runtime op --item [STATE_KEY] --request "[ITEM_DIR]/verify-review-request-[STATE_KEY].json"
```

**Ready-head review call.** Before each readiness check, run the merge's review call once on an open ready head. This covers a cloud PR whose lane requested no review.

- Under `approval`, the call settles the head's Copilot request ([gates.md § Copilot requests](../references/gates.md#copilot-requests)).
- Never close and reopen a PR to request review.

Read whether the PR is open and ready:

```bash
if ! MERGE_PR_OPEN_READY="$(env -u GH_REPO -u GITHUB_REPOSITORY gh pr view [PR_NUMBER] --json state,isDraft --jq '.state == "OPEN" and .isDraft == false')"; then
  exit 1
fi
```

- Run the call only where `MERGE_PR_OPEN_READY` reads `true`. Never run it on a draft, closed or merged PR.
- Route the reply's `request` by Copilot requests before any review wait.

**The Copilot hold.** Bind the time of the readiness check's first call as `[HOLD_START]`. Read the bound once:

```bash
.agents/skills/orch/scripts/orch-env ORCH_COPILOT_HOLD_SECS 600
```

1. Repeat the call on a `pending` reply whose `reason` opens `copilot-pending`.
2. Repeat it on an `approved`, `proceeded` or `off` verdict whose `copilot.state` is `expired`.
3. Run each repeat through [Waiter launch](../references/waiter-launch.md), at most once every 30 seconds.
4. Stop repeating when the call answers anything else, or once that many seconds have passed since `[HOLD_START]`.
5. Route the last answer as any other:
   - Any other `pending` reply goes on to the readiness check.
   - A refusal or an `unreadable` reply stops this pass.
   - A `blocked` verdict is never a met gate, under either gate mode. Record `review-regression-open`, gate `review`, naming the location its `reason` reads, and hand back.

Read the head the readiness check judges as `[CHECK_HEAD]`:

```bash
env -u GH_REPO -u GITHUB_REPOSITORY gh pr view [PR_NUMBER] --json headRefOid --jq .headRefOid
```

Run the check. Its JSON is `CHECK`:

```bash
.agents/skills/github/scripts/github.sh pr-merge [PR_NUMBER] --check
```

### 3.1 Resolve Transient Blockers First

Where `CHECK.transient` is `true`, route each issue by its prefix before any user prompt, then continue to § 3.2. Each re-check repeats § 3's head read.

- `unknown:` has no wait of its own. Re-check once, then continue to § 3.2 with the latest `CHECK`.
- `ci_pending:` waits nowhere here. Continue to § 3.2's gates, then to the CI wait of § 5 step 1 and its pending bound.
- `ci_fetch_failed:` and `ci_unconfigured:` re-check, at most three checks in all. Then continue with the latest `CHECK`.

### 3.2 Act On The Result

`CHECK.state` routes first:

- `MERGED`: set `[ALREADY_MERGED]=true`. Run § 4 without § 4.1, then § 5 step 1, which goes straight to step 2.
- `CLOSED` records `pr-closed-unmerged`.

`can_merge` routes next:

- `can_merge: true` goes to § 4 once the gates below are met. Show any warnings.
- `can_merge: false` with `transient: true` takes the same route, after § 3.1, in two cases only:
  - Every remaining issue is `ci_pending:`. Pending CI takes the direct attempt of § 5 step 1 and its CI wait.
  - `unknown:` is the only issue. It takes the explicit queue arm of § 5 step 1.
- Any other `false`, `ci_fetch_failed:` included: show the issues and their suggested fixes. Then:
  - `auto-recommended` takes `Fix and retry` once. The same blocker a second time records `merge-check-blocked`.
  - `ask` presents `Skip` | `Fix and retry`, recommending `Fix and retry`.

The merge gates:

- **Open review threads.** No `CHECK` field reports them. Run § 3.3 before the `not_approved` wait.
- **`not_approved`.** Read the gate mode through the merge's review call. Its `mode` is the item's recorded one ([gates.md § Gate-mode routing](../references/gates.md#gate-mode-routing)).
  - A refusal, or an `unreadable` reply with no `mode`, reads no mode. Report it and stop.
  - `mode` `off`: no approval wait. Go on to § 4. A `pending copilot-pending` answer goes on too, and the call of § 5 step 1 holds the merge call on it.
  - `mode` `approval`: a GitHub-native approval is required. Wait through the review wait ([gates.md § The review call](../references/gates.md#the-review-call)), and repeat the call while it answers `pending`.
    - At a `timeout`, `auto-recommended` records `review-gate-unmet`, and `ask` offers to wait again or stop.

Route the review wait's answers:

- `copilot-error` is never a met gate. Route it by [gates.md § Copilot requests](../references/gates.md#copilot-requests), then run the wait again.
- `comments` is an open thread. Run § 3.3, then the wait again.
- `changes_requested` returns to § 3's readiness check, whose `pr-merge --check` refuses it.
- `proceeded` is a met gate and a local verdict. Orch posts no status. Record it in the § 6 report.
- `blocked` means a regression-against-main blocker stands open on the item, under either mode ([gates.md § Which waiter answers which state](../references/gates.md#which-waiter-answers-which-state)). Record `review-regression-open`, gate `review`, naming the location its `reason` reads, and hand back.
- `unreadable`: run the call once more. A second `unreadable` records `review-gate-read-failed`.

While the item's state carries `pr_approval.forced`, stop waiting for a missing verdict.

- The `Force merge` choice of [submit-pr.md § 4. Review Gate](submit-pr.md#4-review-gate) sets it for the item.
- No push clears it.
- The prepared head takes the `--auto --queue` arm of § 5 step 1.

Bot-specific signals are never merge gates: emoji reactions, sticky-comment prose and checklist text.

- The one exception is a review body's findings section under `Suppressed comments (N)` or `Previously missed (N)`. The reply check that `pr-merge` runs (`review_replies:`) reads it.
- Only GitHub-native review state, the open-thread count and that reply check count.

### 3.3 Thread Read

Read the open review threads by [references/thread-read.md](../references/thread-read.md). That reference owns the read, its triage route, its return points and the list of every other reader of a thread.

## 4. Prepare

Reuse the `[ISSUE]` and `[PR_BRANCH]` that § 3 read for this PR. Run the worktree commands only with an `[ISSUE]`:

```bash
.agents/skills/worktree/scripts/worktree exists [ISSUE]
```

```bash
.agents/skills/worktree/scripts/worktree path [ISSUE]
```

- Bind the printed path as `[WORKTREE_PATH]`.
- Where no issue worktree exists, `[WORKTREE_PATH]` is `[MAIN_REPO_ROOT]`, and § 5 has no issue worktree to remove.

A [micro.md](micro.md) § 4 entry starts here.

- The entry itself binds `[ISSUE]`, `[PR_BRANCH]`, `[STATE_KEY]`, § 1's run-level bindings and the `[ITEM_DIR]` read of § 3.
- A return from § 5 step 1 to § 3.2 makes that entry escape, since § 3 produced no `CHECK` for it.

Read the identity the merge lands under:

```bash
.agents/skills/github/scripts/github.sh bot-token
```

`.configured: false` is an identity decision: the merge would land under the human's name. Then:

- `auto-recommended` records `bot-auth-missing`.
- `ask` presents `Merge as current user` | `Abort`, recommending `Abort`.

### 4.1 Detach Orphaned Children

**Skip if** any of these holds:

- No `[ISSUE]` was extracted.
- `TRACKER` is `github` or `none`.
- The item's state records `children_detached`: [submit-pr.md](submit-pr.md) § 2 step 5 ran this detach before its arm.

```bash
.agents/skills/linear/scripts/linear.sh issues get [ISSUE]
```

For the review audit's in-PR bundle, first run `issues validate-completion [ISSUE] --include-children-of [ISSUE]`.

- A started child whose result has `ok: true` stays attached for this PR's post-merge completion. Leave it out of the orphan split.
- An unreadable validation result or tracker read stops the merge.
- A container child stays a separate PR unit.

Split the remaining `.children` rows by `state_type`:

- `backlog` and `unstarted` are **safe**, `[SAFE_IDS]`.
- Every other state is **active**.
- Both sets empty: go to § 5.

An active child pauses the merge. Ask the user, per child, whether this PR landed its work:

- Yes closes the child Done.
- No appends it to `[SAFE_IDS]`.
- Abort stops § 4.1.

With `[SAFE_IDS]` still empty, go to § 5. Otherwise detach each safe child, so the merge does not cascade it to Done.

- A detached child keeps its project and takes no new parent. The project-management skill's references/filing.md groups related items by project or label, never by parent.
- Run one detach pair per safe id:

```bash
.agents/skills/linear/scripts/linear.sh issues update [SAFE_ID] --remove-parent && .agents/skills/linear/scripts/linear.sh issues add-relation [SAFE_ID] --related [ISSUE]
```

A non-zero exit **aborts the merge**.

Write this comment with the harness file-write tool to `tmp/detach-comment-[ISSUE].md`, and bind that path as `[BODY_FILE]`:

```markdown
Pending children detached before merge to avoid cascade-Done; each keeps its project and a related relation to this item: [SAFE_IDS].
```

Post it on the original item:

```bash
.agents/skills/linear/scripts/linear.sh comments create [ISSUE] --body-file [BODY_FILE]
```

## 5. Execute The Merge

Use `-C` and absolute paths, never `cd &&` chains.

**Clear `GH_REPO` and `GITHUB_REPOSITORY` on every command in this section that reaches GitHub, fenced or inline.**

- The `github.sh` router and `worktree` call `gh` inside, so they reach GitHub too.
- The orch runtime's verbs name the repository on every call, and `container-close` clears both variables for the `gh` it starts. Their fences carry no `env -u`.
- Before you add a command here, read the script it names.

1. **Merge**, before any cleanup.

   `[RECOVERY_COUNT]` starts at `0`. It grows by one per recovery cycle in this run ([merge-contracts.md § Recovery cycle](../references/merge-contracts.md#recovery-cycle)).

   - Nothing persists it. A run resumed after a compaction, or relaunched by the overseer, starts a fresh count.
   - Whatever the count says, a run that keeps returning to ci-fix is the signal the cap exists for.

   Read the repository:

   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY gh repo view --json nameWithOwner --jq .nameWithOwner
   ```

   Save it as `[MERGE_REPO_SLUG]`. Split it at `/` into `[MERGE_REPO_OWNER]` and `[MERGE_REPO_NAME]`.

   `[ALREADY_MERGED]=true` skips to step 2. It keeps the recorded merge decision in the status file and the PR body.

   **Thread read.** Run § 3.3 on every entry to this step, and on every return from the cycles of [merge-contracts.md](../references/merge-contracts.md). Then read the endpoints:

   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY gh pr view [PR_NUMBER] --json baseRefOid,headRefOid --jq '[.baseRefOid,.headRefOid]|@tsv'
   ```

   - The head is `[PREPARED_HEAD]`, and the base is `[PREPARED_BASE]`.
   - Except on a `[MICRO_ENTRY]` run, require `[PREPARED_HEAD]` to equal `[CHECK_HEAD]`. A mismatch returns to § 3 for a fresh readiness check and approval.
   - `[PREPARED_BASE]` is the recorded base, which can trail the base branch's tip (the harness-ci skill's `wiring.md` reference, § The endpoint expressions).

   A `[MICRO_ENTRY]` run fetches both commits, then classifies the range:

   ```bash
   git -C [WORKTREE_PATH] fetch --quiet --no-tags --no-write-fetch-head origin [PREPARED_BASE] [PREPARED_HEAD]
   ```

   ```bash
   .agents/skills/orch/scripts/orch-runtime tier --base [PREPARED_BASE] --head [PREPARED_HEAD] --repo [WORKTREE_PATH]
   ```

   **The review call before a merge call.**

   - Bind `[REVIEW_BASE_CHECKOUT]` to the consumer base by Gate-mode routing.
   - Run the merge's review call (§ 3). Under `approval`, it also settles the Copilot request of `[PREPARED_HEAD]`.
   - Every merge call re-enters this step, the direct attempt's and the `--auto` arm's alike, so this call runs before each of them.
   - Hold as § 3's Copilot hold does. `[HOLD_START]` is the time of the first call before this merge call.
   - This hold is the one before a merge call. It is never the triage's `orch-runtime copilot-wait`.

   Route the call's last answer:

   - `blocked`, under either mode, takes § 3.2's `blocked` route.
   - `comments` takes § 3.3, then this step again.
   - `unreadable`: run the call once more. A second `unreadable` records `review-gate-read-failed`.
   - `approved` and `proceeded` go on through this step.
   - `off`: run § 3.3 once more, then go on with no further call.
   - `copilot-error`: route it by [gates.md § Copilot requests](../references/gates.md#copilot-requests), then as the next row.
   - Any other `pending`, a `timeout` or a `changes_requested`:
     - A `[MICRO_ENTRY]` run goes on through this step.
     - So does an item whose state carries `pr_approval.forced`.
     - Any other run returns to § 3 for a fresh readiness check and approval.

   A `[MICRO_ENTRY]` run goes on only where all three hold. Any other answer arms nothing and escapes by micro.md condition 8.

   - The `tier` line reads `tier=micro`.
   - The reply's `mode` is `approval`.
   - `[MICRO_HEAD]` equals `[PREPARED_HEAD]`.

   **Restack proof.** Before either merge route, run the proof block of [merge-pr-restack.md step 3](merge-pr-restack.md#merge-pr-restack-cycle) with this step's `[WORKTREE_PATH]`, `[STATE_KEY]` and `[PREPARED_HEAD]`.

   - Keep its reply as that step says.
   - A nonzero exit records `validation-proof-missing` by [merge-contracts.md § Stop routes](../references/merge-contracts.md#stop-routes).

   **Merge route.** `pr-merge` picks the route, and no step here judges it.

   - It either merges past the queue with `--admin`, bound to the prepared head, and exits `0`, or takes the queue and exits `75`.
   - Its `merge-route:` line names the cause (`pr-merge --help` § Merge route).
   - Take the direct attempt below first.
   - [submit-pr.md](submit-pr.md) § 2 step 5 arms at creation only a PR that this route takes through the queue. Where GitHub has already queued a PR, the attempt exits `75`.
   - Two cases take the explicit `--auto --queue` arm below instead, which never passes `--admin`: an item whose state carries `pr_approval.forced`, and a PR on the `unknown:` route of § 3.2.

   **Who acts.** The lane merges its own PR under the token the `github.sh` router selects (`github.sh --help` names the order).

   - An emergency merge exists only in a consumer whose ruleset lists the consumer's own overseer GitHub App as a bypass actor. Only that app makes it.
   - A merge group that cannot pass because a CI input read from the default branch broke takes the recovery route in the review-gate skill's `SKILL.md` § 4. Operations.

   **The direct attempt.** Follow [merge-attempt.md § Direct attempt](../references/merge-attempt.md#direct-attempt) for the CI wait on the approved head, its pending bound, the exact-head attempt and its exit routing. Its exit `75` takes [merge-contracts.md § Queue wait](../references/merge-contracts.md#queue-wait).

   **Record the merge decision.** After each attempt here or in the arm of [submit-pr.md](submit-pr.md) § 2 step 5, apply [merge-attempt.md § Record the merge decision](../references/merge-attempt.md#record-the-merge-decision) before you route its exit.

   **The `--auto` arm** takes only that same head:

   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY [MAIN_REPO_ROOT]/.agents/skills/github/scripts/github.sh -C [MAIN_REPO_ROOT] pr-merge [PR_NUMBER] --auto --queue --expected-head [PREPARED_HEAD]
   ```

   Route its exit:

   - Exit `0` merged the prepared head. Continue to step 2.
   - Exit `1` with a line starting `arm: no-merge-gate=<condition>` armed nothing and names why, with or without a `merge-route:` line before it.
     - On the `unknown:` route of § 3.2, record `merge-readiness-unresolved`.
     - Otherwise take the direct attempt above. Its exit `75` routes a base that still queues the PR.
     - Never fall back to a raw `gh pr merge --auto`.
   - Exit `75` means queued or armed. Take [merge-contracts.md § Queue wait](../references/merge-contracts.md#queue-wait), and route its verdict there.
   - Any other exit is an exact-head arm failure. Report it and return to § 3.2.

2. **Post the merge comment, complete the issue and close a finished container.** **Skip if** `TRACKER=none`, as for a directed change ([SKILL.md § Tracker Resolution](../SKILL.md#tracker-resolution)), which has no tracker item to post to or complete.

   Before tracker completion or worktree cleanup, post the merge summary through [post-summary.md § 1](post-summary.md#1-post-the-summary), with this PR's and item's caller context.

   - A direct delivery ([base-publication.md](base-publication.md)) passes no `pr_number`, so the summary goes on the Linear item alone. A direct delivery of a GitHub-tracked item posts no summary.
   - Include the Validation Routes of every actual round and run under [dev-implement.md § 9.1](../../dev/workflows/dev-implement.md#91-completion-summary-file), the fix and restack runs since the previous summary among them.
   - After the merge-group CI passes, keep the original pending, failed and no-verdict rows. Record that CI proof separately, by its run reference.
   - Post each bundled child's rows on its own item, through the same comment interface. A validation-routing Done-when box reads the rows where [dev-implement.md § 9.1](../../dev/workflows/dev-implement.md#91-completion-summary-file) **Where the records live** places them.

   **Linear only from here**, under [SKILL.md § Tracker Resolution](../SKILL.md#tracker-resolution): the rest of this step runs for a Linear item alone.

   - The lane owns completion after the merge.
   - Where the lane's sandbox is gone, or its item reads Done with the lane ended, the runtime's close completes the item from the PR body's `## Done-when evidence` section.
   - The overseer owns the remaining post-merge checks on the same item.

   Before completion:

   - Give every development remainder from a cut its own issue.
   - Keep post-merge boxes on `[ISSUE]` in the form the project-management skill's `references/filing.md` § Done when states.

   Linear's GitHub integration can set `[ISSUE]` Done when the PR merges.

   - Read the item live, and complete it with the command below even where the integration already set Done.
   - The merge lane never writes In Review or In Progress.
   - Box acceptance follows [SKILL.md § The Cycle](../SKILL.md#the-cycle), The overseer reads results.
   - For a failed post-merge check, follow [oversee-events.md](../references/oversee-events.md) § Verification.

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/linear/scripts/linear.sh issues get [ISSUE]
   ```

   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY gh pr view [PR_NUMBER] --json mergedAt --jq .mergedAt
   ```

   That live UTC timestamp is `[MERGED_AT]`. An absent or unreadable timestamp is a tracker-completion failure.

   On a pull-request delivery, read the PR body:

   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY gh pr view [PR_NUMBER] --json body --jq .body
   ```

   Write `[EVIDENCE_FILE]` under the checkout's `tmp/`: one `N: text` line per selected box, the text citing the recorded proof.

   - On a pull-request delivery, take `[MET_BOXES]` and those lines from the body's `## Done-when evidence` section.
   - A direct delivery ([base-publication.md](base-publication.md)) creates no pull request and reads no body.
   - Include an already-ticked box whose Evidence line needs adding, from the attached evidence file that holds its proof.
   - Select `[MET_BOXES]` under the acceptance rule. Write `all` only where that rule accepts every box. Otherwise list the box numbers in section order from 1, comma-separated.
   - Where no box needs a tick or an Evidence line, omit both `--done-when-met` and `--evidence-file`.
   - A section of plain bullets with no checkbox takes `all`, which ticks nothing and sets Done.

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/linear/scripts/linear.sh issues complete [ISSUE] --post-merge-at [MERGED_AT] --done-when-met [MET_BOXES] --evidence-file [EVIDENCE_FILE]
   ```

   - Hold a rate-limited completion under the linear skill's `patterns/workflow-actions.md` § Quota Holds. Never record it as a failed step.
   - A required supersession that fails stays a tracker-completion failure after Done.
     - Keep the transition and its structured `supersession-incomplete` diagnostic.
     - Then retry through the same completion command, with the action and options the diagnostic gives and without summary flags.
     - That retry succeeds only after an open child's disposition.
   - Done alone does not prove these effects completed.
   - A canceled or unreadable issue is a tracker failure, not a merge record. Carry the diagnostic into § 6, and claim no tracker completion.

   **Complete the in-PR bundle's children.** This step alone selects each child's proved boxes and completes the child at merge.

   - The `issues get [ISSUE]` read above lists the children as `.children` rows, each with its `.id` and `.state_type`. Include children the GitHub integration already set Done.
   - Take each non-canceled child that this PR's child `Closes` lines name.
   - For each, repeat the live read and the `issues complete` command, with its id, its own box selection and evidence file, and the same `[MERGED_AT]`. Keep `[ISSUE]` bound to the parent, and keep post-merge boxes on each child.
   - The call moves a qualified started child to Verifying while post-merge boxes remain open, and to Done otherwise. Record each child still Verifying in § 6 for the overseer.
   - A child read or completion failure is a tracker-completion failure.
   - Reconciliation's key search finds a child closed on its parent's `Closes` line. It can report `verifying-merge-unread` for a shared child's release-triggered or `+Nh` merge box. Then `orch-runtime reconcile-items --merged [CHILD]=[OWNER/REPO]#[PR_NUMBER]` judges the box from this merge ([verify.md § 1](verify.md#1-read-open-checks)). Name that command in the child handoff.

   **The container closes when its last child closes.**

   - Read `.parent_id` from the live issue. Empty: go to step 3.
   - Fetch the parent with its bundle. Children, or an `agent:multi` label, make the parent a container, unless its read reports `in_pr_bundle` true ([skill-rules.md § Coordination](../references/skill-rules.md#coordination)). Not a container: go to step 3.
   - An unreadable parent is a tracker failure.
   - Close the container through the runtime's serialized close, which keeps it open while a child is open:

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/orch-runtime container-close [MAIN_REPO_ROOT] [PARENT_ID]
   ```

   Keep its stderr diagnostics for § 6. Route its output:

   - `container-close: left cause=confined owner=overseer`, exit `0`: a confined lane closes nothing here, and the overseer's own route closes the container. Record `container [PARENT_ID] left to the overseer` in § 6, and climb no further.
   - `closed [PARENT_ID]`: where its stderr carries `container-close: canceled parent-id=[PARENT_ID]`, record `[PARENT_ID] → Canceled` in § 6. Otherwise record `[PARENT_ID] → Done`. If this container has a container parent, repeat this step for that parent.
   - `deferred [CHILD_IDS...]`: record `container [PARENT_ID] stays open (pending: [CHILD_IDS])` in § 6. Where `[ISSUE]` is among them and reads Verifying, the overseer closes the container after verification sets it Done. A bare `deferred` means the lock wait expired: report it.
   - `held [PARENT_ID] [HOLD_RESET]`: hold the command under the linear skill's `patterns/workflow-actions.md` § Quota Holds, and climb no further.
   - A nonzero exit keeps the container open. Carry its diagnostic into § 6, and climb no further. Report `container [PARENT_ID] stays open; rerun orch-runtime container-close once [CAUSE] is fixed`. A `completion-refused` refusal prints each refused row: follow each row's `remedy` before the rerun.

3. **Sync the main repo.** In a lane, skip this step. Once the overseer's close records the landing, the overseer brings the base checkout to the landed base with `sync-base`. A run outside a lane syncs after every merge:

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/sync-base [MAIN_REPO_ROOT]
   ```

   - Its stdout is `[BASE_BRANCH]`.
   - On success, read `refs/heads/[BASE_BRANCH]` as `[NEW_SHA]`, and report it in § 6.
   - On a non-zero exit, the base stays unsynchronized. Carry the script's diagnostic into § 6's warning. Then, before cleanup, read the branch and the two SHAs:

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/resolve-base-branch [MAIN_REPO_ROOT]
   ```

   ```bash
   git -C [MAIN_REPO_ROOT] rev-parse "refs/heads/[BASE_BRANCH]"
   ```

   ```bash
   git -C [MAIN_REPO_ROOT] rev-parse "refs/remotes/origin/[BASE_BRANCH]"
   ```

   The outputs are `[BASE_BRANCH]`, `[LOCAL_SHA]` and `[ORIGIN_SHA]`. A failed ref read stays in the warning as its cause. Never record the sync as done.

4. **Prepare branch and worktree cleanup.**

   - In a lane, the overseer's close owns branch and worktree cleanup. The lane still runs step 6's close-out.
   - A local close keeps a dirty or unmerged worktree, and records the reason.
   - The static SSH provider can remove a clean detached worktree without checking whether another ref reaches its HEAD. Preserve needed commits before you hand back a hosted lane for close.
   - A run outside a lane cleans up only the PR's own branch and worktree, never unrelated branches or sibling worktrees:

   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY gh pr view [PR_NUMBER] --json headRefName --jq .headRefName
   ```

   Judge the PR's worktree by [merge-contracts.md § Disposal predicate](../references/merge-contracts.md#disposal-predicate). A worktree kept on another branch leaves the merged branch to the branch delete below.

   **The merged predicate is `worktree cleanup`'s.** A branch carrying commits past its merged PR is unmerged work.

   - `worktree remove` applies this predicate when it deletes the branch.
   - A nonzero exit after the tree is gone means the branch survived, and its diagnostic names the lookup's answer. Report that as `kept` in § 6's `Branch` row.

   With no qualifying worktree, delete the local `[PR_BRANCH]` only where no worktree owns it. Check first:

   ```bash
   git -C [MAIN_REPO_ROOT] worktree list --porcelain
   ```

   - A `branch refs/heads/[PR_BRANCH]` line means a worktree still has the branch checked out. Keep the branch, and note it in § 6.
   - Where no such line stands, and the branch is present locally and not current, compare the PR's head with the branch's tip:

   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY gh pr view [PR_NUMBER] --json headRefOid --jq .headRefOid
   ```

   ```bash
   git -C [MAIN_REPO_ROOT] rev-parse "refs/heads/[PR_BRANCH]"
   ```

   - Equal: run `git -C [MAIN_REPO_ROOT] branch -D "[PR_BRANCH]"`.
   - Different: the branch carries commits the merge did not take. Keep it, and report it `kept` in § 6's `Branch` row.
   - Never run `git branch -d` here.

   For `merge-pr all`, or on the user's request, also sweep the project:

   - Check each local branch with `env -u GH_REPO -u GITHUB_REPOSITORY gh pr list --head [BRANCH] --base [BASE_BRANCH] --state all --json number,state,headRefOid,isCrossRepository`.
   - Delete without asking only a branch with no worktree whose tip equals the `headRefOid` of one of its **merged**, non-cross-repository PRs. That is the predicate `worktree cleanup` applies. Neither state alone nor a merge into another base passes.
   - Leave every other branch.
   - Ask before you remove a stale worktree or a branch with no PR.
   - Compare `ls [TREES_DIR]/` with `worktree list --porcelain` for orphan folders, and ask before you remove any.

5. **Answer the threads the wait's guard did not catch.** Read the merged PR's unresolved threads once, and answer each. Resolve the merge commit first:

   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY gh pr view [PR_NUMBER] --json mergeCommit --jq .mergeCommit.oid
   ```

   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY [MAIN_REPO_ROOT]/.agents/skills/github/scripts/github.sh -C [MAIN_REPO_ROOT] pr-threads [PR_NUMBER] --unresolved
   ```

   - That oid is `[MERGE_SHA]`.
   - Each reply is one of the three dispositions of [finding-disposition.md](../../reviewer/references/finding-disposition.md): `Declined: [reason]`, `Fixed in [MERGE_SHA]`, or `Tracked: [ISSUE_ID]`.
   - For `Tracked`, first create the issue under [skill-rules.md § Coordination](../references/skill-rules.md#coordination).
   - Reply and resolve through `github.sh post-reply` and `github.sh resolve-thread`. Clear the two variables and pass `-C [MAIN_REPO_ROOT]`, as the read above does.
   - This read happens once: nothing reads a merged PR's threads after it.

6. **Verify the project and close the item out.**

   Choose one close-out route and run it once. A hosted lane is unconfined and takes **The close-out elsewhere**, which copies the record before the archived close-out. For other runs, take **The close-out in a confined lane** if the environment has `AGENT_RUNTIME_CONFINED=1`. Otherwise take **The close-out elsewhere**.

   - Run the build, install and verification work the project's own instructions require after a merge. This workflow defines no generic command and infers none.
   - The route the project's own instructions name records its install record (`.kendex-lock.json`). The lane never records it after a merge or a restack.
   - On failure, report the command and its diagnostic in § 6, and keep the worktree.

   **The close-out in a confined lane.** Skip the copy and the archived close-out below. Where the verification passed, run the close-out with no `--archive` pair:

   ```bash
   .agents/skills/orch/scripts/orch-runtime state remove --item [STATE_KEY]
   ```

   - It stamps the item's record and answers `state-remove: left cause=confined owner=overseer`.
   - The overseer's close reads the stamp as this step's end. It ends the lane on its merge, and keeps the item's files with the open item ([schemas/workflow-state.md § Item close-out](../schemas/workflow-state.md#item-close-out)).
   - § 6's `tmp/ close-out` line reads `left to the overseer's close`.
   - A refusal keeps the worktree, and its key goes on that line.

   **The close-out elsewhere.** In an unconfined lane, save the item's record for the overseer's cycle row before the close-out:

   - Read its path, the reply's `result.path`, with `orch-runtime state path --item [STATE_KEY]` from `[MAIN_REPO_ROOT]`.
   - Create `[MAIN_REPO_ROOT]/tmp/cycle-state/` if needed.
   - Copy the record once to `[MAIN_REPO_ROOT]/tmp/cycle-state/workflow-state-pr-[PR_NUMBER].json`, named by the merged PR whatever `[STATE_KEY]` is.
   - If an earlier close-out removed the record and the saved copy reads as a JSON object, keep the saved copy and go to **The worktree**.
   - Where neither reads as a JSON object, report the failure and keep the worktree.

   Close the item out before any worktree removal, whatever the item's tracker state: Done, Verifying, or In Review with a box still open.

   - The close-out removes only the item's records, so a hold on stopping or removing a hosted lane's host does not cover it.
   - The overseer's close never runs it for an open item: it refuses `lane-live` while the record stands.
   - Pass no `--state-dir`: the runtime resolves the state folder the run's launch names.
   - Where § 4 found an issue worktree, name its `tmp/` for the close-out's archive. Otherwise drop the `--archive` pair:

   ```bash
   .agents/skills/orch/scripts/orch-runtime state remove --item [STATE_KEY] --archive [WORKTREE_PATH]/tmp
   ```

   - [schemas/workflow-state.md § Item close-out](../schemas/workflow-state.md#item-close-out) states what it takes, archives and keeps, and the reply's `result.kept`. That value goes on § 6's `tmp/ close-out` line.
   - A refusal keeps the worktree, since the worktree's records may be in no archive. The refusal's key goes on that line, and the worktree line reads `standing — close-out refused`.

   **The worktree.**

   - A lane leaves its worktree: the overseer's close stops the session, then releases the worktree (step 4). § 6's worktree line reads `standing — left to the overseer's close`.
   - A run outside a lane removes the worktree once the project verification passed and the close-out is done.
     - First judge the worktree again by [merge-contracts.md § Disposal predicate](../references/merge-contracts.md#disposal-predicate), whole: step 5's replies and this step's build can each dirty the tree or move the branch.
     - `worktree remove` refuses nothing itself. Uncommitted content, untracked content and a worktree moved to another branch all leave with the folder. The predicate is the only guard.
     - Where every part holds, remove the worktree from `[MAIN_REPO_ROOT]`:

       ```bash
       env -u GH_REPO -u GITHUB_REPOSITORY [MAIN_REPO_ROOT]/.agents/skills/worktree/scripts/worktree remove [ISSUE]
       ```

   A foreign-lease refusal keeps the worktree. Carry its diagnostic onto § 6's worktree line. Where § 4 found an issue worktree, read its path last, whichever way the removal went:

   ```bash
   ls -d -- "[WORKTREE_PATH]"
   ```

   `No such file or directory` is the removal. A listed path is a worktree still standing. Write § 6 after this step, never before.

## 6. Present Results

Output: [Lane Output](../references/skill-rules.md#lane-output).

<output_format>

### ✅ MERGED — PR #[N]: [TITLE]

| Field | Value |
|-------|-------|
| Branch | [BRANCH_NAME] (deleted / kept) |
| Issue Tracker | [ISSUE_ID] → Done / still open — [tracker result or cause from § 5 step 2] |
| Container | [PARENT_ID] → Done / Canceled / deferred / held / left to the overseer — [pending ids or cause] |
| Base sync | local `[BASE_BRANCH]` → [NEW_SHA] |

tmp/ close-out: [KEPT_LINE_OR_FIRST_REFUSAL_LINE]

Worktree `[WORKTREE_PATH]` gone / standing — [cause]

</output_format>

- The `Container` row appears only where § 5 step 2 found a container parent.
- In a lane, the `Branch` and `Base sync` rows read `left to the overseer's close`.
- Where § 5 step 3 failed, `Base sync` carries the warning in place of a SHA: `⚠️ local [BASE_BRANCH] STALE at [LOCAL_SHA] (origin/[BASE_BRANCH] at [ORIGIN_SHA]) — [CAUSE]`.
- The worktree line closes the block with step 6's reading: `gone`, or `standing — [cause]`.
  - The cause is the one the disposal predicate named, `foreign lease`, `project verification failed`, `close-out refused` or `left to the overseer's close`.
  - Omit the line only where § 4 found no issue worktree.
- The `tmp/ close-out` line carries the archive step 6's close-out reported, its refusal key, or, in a confined lane, `left to the overseer's close`. Omit it where that step never ran.
- Add a `Review gate` row only where the merge did not proceed on a plain `approved` verdict: `⚠️ reviewer-down proceed (no reviewer posted; PR_REVIEW_ON_TIMEOUT=proceed)` or `⚠️ forced (user override)`.

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

- The merge is complete once § 5 steps 1-6 have run.
- A run outside a lane whose issue worktree still stands, with no cause on § 6's worktree line, has not finished.
- A run that handed back at a verdict other than a merge reports that verdict and ends. It does not resume.
