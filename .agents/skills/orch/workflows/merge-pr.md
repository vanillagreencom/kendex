# PR Merge Workflow

Check the merge conditions of one or more pull requests, merge them, and close out their items.

Run every review wait, every `queue-watch` and every `verify-pr` call of [merge-attempt.md](../references/merge-attempt.md) through [Waiter launch](../references/waiter-launch.md). A review call that reads only the mode or the request runs directly. Route each reply as this workflow says; merge-attempt.md routes `verify-pr`'s.

| Command | Flow |
|---------|------|
| `merge-pr` | List ready PRs, user selects |
| `merge-pr [N]` | Merge a specific PR |
| `merge-pr all` | Merge all ready PRs in sequence |

A lane is a session whose launch brief names a lane status file and a mailbox ([skill-rules.md § Lane Output](../references/skill-rules.md#lane-output)). A step that differs for a lane says so. A confined lane runs with `AGENT_RUNTIME_CONFINED` set to `1` in its environment.

## 1. Identify Candidates

```bash
.agents/skills/github/scripts/github.sh pr-list-ready
```

With no argument, present the list and ask which to merge. With `all`, take every ready PR in turn.

Read the decision mode once; it governs every choice below. An unset key reads `ask`. Named stops follow [SKILL.md § The Cycle](../SKILL.md#the-cycle).

```bash
.agents/skills/orch/scripts/orch-env ORCH_DECISION_MODE ask
```

Bind the main checkout's root as `[MAIN_REPO_ROOT]`:

```bash
.agents/skills/orch/scripts/git-context common-root .
```

**No hand-back leaves an armed PR.** Every route that ends this run without a merged PR first takes [merge-pr-restack.md § Unarm at a stop](merge-pr-restack.md#unarm-at-a-stop) for the PR it stops, with `[STOP_DIR]` that PR's `[ITEM_DIR]` (§ 3). This covers each `records [STOP_NAME]` route, each hand-back, the recovery-cycle cap, an `ask` answer that skips the merge, and the `closed` verdict. On the `merge-pr all` route it covers every PR in scope, since a cross-check stop exists to keep them from landing together.

**Stop routes.** A `records [STOP_NAME]` route records the stop against the PR's `[STATE_KEY]` (§ 3), renders its comment into the PR's `[ITEM_DIR]`, and posts that comment on the PR:

```bash
.agents/skills/orch/scripts/orch-runtime state post-pr-stop record --item [STATE_KEY] --name [STOP_NAME] --gate [GATE] --remaining "[REMAINING]" --comment-file [ITEM_DIR]/post-pr-stop-[STATE_KEY].md
```

```bash
env -u GH_REPO -u GITHUB_REPOSITORY .agents/skills/github/scripts/github.sh post-comment [PR_NUMBER] --body-file [ITEM_DIR]/post-pr-stop-[STATE_KEY].md
```

## 2. Cross-Check (batch merges only)

**Skip if** fewer than two PRs are in scope.

A stop here needs a PR to record against: run § 3's per-PR state for the first PR in the reported order, and record and post both stops below against that PR.

```bash
.agents/skills/github/scripts/github.sh pr-cross-check [PR_NUMBERS] --quick --json
```

On high-severity findings (conflicts), show them. `auto-recommended` records `batch-cross-check-failed`; `ask` stops with them shown. Otherwise verify:

```bash
.agents/skills/github/scripts/github.sh pr-cross-check [PR_NUMBERS] --verify --json
```

`can_batch_merge: true` → § 3, in the reported `merge_order`. `false` → show the merge, build and test failures with their suggested remediation. `auto-recommended` records `batch-cross-check-failed`; `ask` presents `Abort` | `Force anyway`, recommending `Abort`.

## 3. Check Merge Readiness

**Per-PR state.** Run this block once for each PR in scope, never once per run: a key resolved once would bind the first PR's key to every later PR and put their stops in one record. Read the PR's issue and branch:

```bash
.agents/skills/github/scripts/github.sh pr-issue [PR_NUMBER] --format=text
```

```bash
env -u GH_REPO -u GITHUB_REPOSITORY gh pr view [PR_NUMBER] --json headRefName --jq .headRefName
```

`[STATE_KEY]` is the extracted issue where there is one, else `pr-[PR_NUMBER]`. § 4 reuses this `[ISSUE]` and `[PR_BRANCH]`. Run `init` only where `exists` reads `false`:

```bash
.agents/skills/orch/scripts/orch-runtime state exists --item [STATE_KEY]
```

```bash
.agents/skills/orch/scripts/orch-runtime state init --item [STATE_KEY] --branch [PR_BRANCH]
```

```bash
.agents/skills/orch/scripts/orch-runtime state post-pr-stop clear --item [STATE_KEY]
```

Bind `[ITEM_DIR]` to the folder holding the record path this prints as `result.path`:

```bash
.agents/skills/orch/scripts/orch-runtime state path --item [STATE_KEY]
```

Stop comments, review requests and notices this workflow writes go in `[ITEM_DIR]`. A confined lane can write that folder; the main checkout's `tmp/` is outside what it can write.

**The merge's review call.** Bind `[REVIEW_BASE_CHECKOUT]` by [gates.md § Gate-mode routing](../references/gates.md#gate-mode-routing). Every review call in this workflow is [the review call](../references/gates.md#the-review-call), run from `[MAIN_REPO_ROOT]` with `[MARK_READY]` `false` and its request file in `[ITEM_DIR]`. `[OWNER/REPO]` is what `env -u GH_REPO -u GITHUB_REPOSITORY gh repo view --json nameWithOwner --jq .nameWithOwner` answers there. gates.md owns the reply's fields, its verdicts and its refusals.

```bash
jq -cn --arg repo "[OWNER/REPO]" --argjson pr [PR_NUMBER] --arg base "[REVIEW_BASE_CHECKOUT]" --argjson ready false \
  '{op: "verify-review", repo: $repo, pr: $pr, base_checkout: $base, mark_ready: $ready}' \
  > "[ITEM_DIR]/verify-review-request-[STATE_KEY].json"
.agents/skills/orch/scripts/orch-runtime op --item [STATE_KEY] --request "[ITEM_DIR]/verify-review-request-[STATE_KEY].json"
```

**Ready-head review call.** Before each readiness check, run the merge's review call once on an open ready head, a cloud PR whose lane requested no review included. Under `approval` the call settles the head's Copilot request ([gates.md § Copilot requests](../references/gates.md#copilot-requests)). Never close and reopen a PR to request review. Read whether the PR is open and ready:

```bash
if ! MERGE_PR_OPEN_READY="$(env -u GH_REPO -u GITHUB_REPOSITORY gh pr view [PR_NUMBER] --json state,isDraft --jq '.state == "OPEN" and .isDraft == false')"; then
  exit 1
fi
```

Run the call only where `MERGE_PR_OPEN_READY` reads `true`, never on a draft, closed or merged PR. Route its `request` by Copilot requests before any review wait.

**The Copilot hold.** Bind the time of the readiness check's first call as `[HOLD_START]`, and read the bound once:

```bash
.agents/skills/orch/scripts/orch-env ORCH_COPILOT_HOLD_SECS 600
```

Repeat the call on a `pending` reply whose `reason` opens `copilot-pending`, and on a verdict `approved`, `proceeded` or `off` whose `copilot.state` is `expired`. Run each repeat through Waiter launch, at most once every 30 seconds, until the call answers otherwise or that many seconds have passed since `[HOLD_START]`; then route its last answer as any other. Any other `pending` reply goes on to the readiness check. A refusal or an `unreadable` reply stops this pass. A `blocked` verdict, under either gate mode, is never a met gate: record `review-regression-open`, gate `review`, naming the location its `reason` reads, and hand back.

Read the head the readiness check judges as `[CHECK_HEAD]`, then run the check. Its JSON is `CHECK`:

```bash
env -u GH_REPO -u GITHUB_REPOSITORY gh pr view [PR_NUMBER] --json headRefOid --jq .headRefOid
```

```bash
.agents/skills/github/scripts/github.sh pr-merge [PR_NUMBER] --check
```

### 3.1 Resolve Transient Blockers First

`CHECK.transient == true` → route on each issue's prefix before any user prompt, then continue to § 3.2. Each re-check repeats § 3's head read.

| Prefix | Wait |
|--------|------|
| `unknown:` (`cause=computing` or `cause=read-failed` for the mergeability read) | No wait of its own. Re-check once, then continue to § 3.2 with the latest `CHECK` |
| `ci_pending:` | No wait here. Continue to § 3.2's gates, then to § 5 step 1's CI wait and its pending bound |
| `ci_fetch_failed:`, `ci_unconfigured:` | Re-check, at most three checks in all, then continue with the latest `CHECK` |

### 3.2 Act On The Result

`CHECK.state` routes first. `MERGED` → set `[ALREADY_MERGED]=true`, run § 4 without § 4.1, then § 5 step 1, which goes straight to step 2. `CLOSED` → records `pr-closed-unmerged`.

`can_merge: true` → § 4 once the gates below are met; show any warnings. `can_merge: false` with `transient: true` takes the same route after § 3.1 only where every remaining issue is `ci_pending:`, or `unknown:` is the only issue: pending CI takes § 5 step 1's direct attempt and its CI wait; `unknown:` takes § 5 step 1's explicit queue arm. Any other `false`, `ci_fetch_failed:` included → show the issues and their suggested fixes. `auto-recommended` takes `Fix and retry` once, and the same blocker then records `merge-check-blocked`. `ask` presents `Skip` | `Fix and retry`, recommending `Fix and retry`.

These conditions are merge gates:

- **Open review threads.** No `CHECK` field reports them: run § 3.3 before the `not_approved` wait.
- **`not_approved`.** Read the gate mode through the merge's review call. Its `mode` is the item's recorded one ([gates.md § Gate-mode routing](../references/gates.md#gate-mode-routing)). A refusal, or an `unreadable` reply with no `mode`, reads no mode: report it and stop. Route on the `mode`:
  - `off`: no approval wait; go on to § 4. A `pending copilot-pending` answer goes on too: § 5 step 1's call holds the merge call on it.
  - `approval`: a GitHub-native approval is required. Wait through the review wait ([gates.md § The review call](../references/gates.md#the-review-call)), repeating the call while it answers `pending`. At a `timeout`, `auto-recommended` records `review-gate-unmet`, and `ask` presents the choice to wait again or stop.

Route the wait's answers:

- `copilot-error`: route as [gates.md § Copilot requests](../references/gates.md#copilot-requests) says, then run the wait again. It is never a met gate.
- `comments`: an open thread. Run § 3.3, then the wait again.
- `changes_requested`: return to § 3's readiness check, whose `pr-merge --check` refuses it.
- `proceeded`: with `PR_REVIEW_ON_TIMEOUT=proceed`, a review period with no open thread and no reviewer answers `proceeded` in place of `timeout`. It is a met gate and a local verdict: orch posts no status. Record it in the § 6 report.
- `blocked`: under either mode, a regression-against-main blocker stands open on the item ([gates.md § Which waiter answers which state](../references/gates.md#which-waiter-answers-which-state)). Record `review-regression-open`, gate `review`, naming the location its `reason` reads, and hand back.
- `unreadable`: run the call once more. A second `unreadable` records `review-gate-read-failed`.

Stop waiting for a missing verdict while the item's state carries `pr_approval.forced`. The `Force merge` choice of [submit-pr.md § 4. Review Gate](submit-pr.md#4-review-gate) sets it for the item, and no push clears it. The prepared head then takes § 5 step 1's `--auto --queue` arm.

Bot-specific signals, such as emoji reactions, sticky-comment prose and checklist text, are never merge gates. The one exception is the findings section a review body lists under `Suppressed comments (N)` or `Previously missed (N)`, which the reply check `pr-merge` runs (`review_replies:`) reads. Only GitHub-native review state, the open-thread count and that reply check count.

### 3.3 Thread Read

Read the open review threads by [references/thread-read.md](../references/thread-read.md). That reference owns the read, its triage route, its return points and the list of every other reader of a thread.

## 4. Prepare

Reuse the `[ISSUE]` and `[PR_BRANCH]` § 3 read for this PR. Run the worktree commands only with an `[ISSUE]`:

```bash
.agents/skills/worktree/scripts/worktree exists [ISSUE]
```

```bash
.agents/skills/worktree/scripts/worktree path [ISSUE]
```

Bind the printed path as `[WORKTREE_PATH]`. Where no issue worktree exists, `[WORKTREE_PATH]` is `[MAIN_REPO_ROOT]`, and § 5 has no issue worktree to remove.

A [micro.md](micro.md) § 4 entry starts here. It binds `[ISSUE]`, `[PR_BRANCH]`, `[STATE_KEY]`, § 1's run-level bindings and § 3's `[ITEM_DIR]` read itself, so nothing waits on CI or on a reviewer before § 5 step 1. That entry escapes on a § 5 step 1 return to § 3.2, since § 3 produced no `CHECK` for it.

Read whose name the merge lands under:

```bash
.agents/skills/github/scripts/github.sh bot-token
```

`.configured: false` is an identity decision: the merge would land under the human's name. `auto-recommended` records `bot-auth-missing`. `ask` presents `Merge as current user` | `Abort`, recommending `Abort`.

### 4.1 Detach Orphaned Children

**Skip if** no `[ISSUE]` was extracted, `TRACKER` is `github` or `none`, or the item's state records `children_detached`: [submit-pr.md](submit-pr.md) § 2 step 5 ran this detach before its arm.

```bash
.agents/skills/linear/scripts/linear.sh issues get [ISSUE]
```

For the review audit's in-PR bundle, first run `issues validate-completion [ISSUE] --include-children-of [ISSUE]`. A started child whose result has `ok: true` stays attached for this PR's post-merge completion; leave it out of the orphan split. An unreadable validation result or tracker read stops the merge. A container child stays a separate PR unit.

Split the remaining `.children` rows by `state_type`: `backlog` and `unstarted` are **safe** (`[SAFE_IDS]`), anything else is **active**. Both empty → § 5.

An active child pauses the merge: ask the user, per child, whether this PR landed its work. Yes closes it Done; no appends it to `[SAFE_IDS]`; abort stops § 4.1.

`[SAFE_IDS]` still empty → § 5. Otherwise apply [skill-rules.md § Coordination](../references/skill-rules.md#coordination), then rebundle them under a new parent:

```bash
.agents/skills/linear/scripts/linear.sh issues get [ISSUE]
```

Read `.title`, `.project_id` and `.labels`. Join the label names with commas and split them by the taxonomy the create refuses against, with `linear.sh labels declared "[NAMES]"`: `.kept`, joined the same way, is `[PARENT_LABELS]`, and `.dropped`, shown in this step's output, is `[DROPPED_LABELS]` (`none` when empty). A non-zero exit **aborts the merge**. `[BUNDLE_PRIORITY]` is the highest priority across `[SAFE_IDS]` (Linear `1` Urgent to `4` Low, the lower number wins; `3` where none is set). Build `[BUNDLE_DESC]` from `.agents/skills/project-management/templates/parent-issue-template.md`, with a `## Sub-Issues` list and a `## Context` line naming the detachment. Its `**Reached by**` line is `this merge-pr rebundle, detaching pending children from [ISSUE] before merge`. A rebundle parent is structural, so the create passes no `--review-born`.

Write `[BUNDLE_DESC]` with the harness file-write tool to `tmp/rebundle-description-[ISSUE].md` and bind that path as `[BODY_FILE]`:

```bash
.agents/skills/linear/scripts/linear.sh issues create --state "Backlog" --title "[PARENT_TITLE] follow-ups" --description-file [BODY_FILE] --project "[PARENT_PROJECT]" --labels "[PARENT_LABELS]" --priority [BUNDLE_PRIORITY] --format=ids
```

A non-zero exit or empty output **aborts the merge**. Otherwise its output is `[NEW_BUNDLE]`. Reparent each safe id, one call each:

```bash
.agents/skills/linear/scripts/linear.sh issues update [SAFE_ID] --parent [NEW_BUNDLE]
```

Link the bundle back:

```bash
.agents/skills/linear/scripts/linear.sh issues add-relation [NEW_BUNDLE] --related [ISSUE]
```

Write this comment with the harness file-write tool to `tmp/rebundle-comment-[ISSUE].md`, bind that path as `[BODY_FILE]`, and post it on the original:

```markdown
Pending children rebundled under [NEW_BUNDLE] before merge to avoid cascade-Done. Labels the taxonomy does not declare, left off the bundle: [DROPPED_LABELS].
```

```bash
.agents/skills/linear/scripts/linear.sh comments create [ISSUE] --body-file [BODY_FILE]
```

## 5. Execute The Merge

Some harnesses reset the working directory on every shell call: use `-C` and absolute paths, never `cd &&` chains.

**Clear `GH_REPO` and `GITHUB_REPOSITORY` on every command in this section that reaches GitHub, fenced or inline.** `gh pr view`, `gh api` and the rest honour them over the working directory and `-C`, while `gh repo view` ignores them. An inherited value therefore sends a read or a mutation to the same-numbered PR of another repository while `gh repo view` names this checkout. The `github.sh` router and `worktree` call `gh` inside, so they reach GitHub too. The orch runtime's verbs name the repository on every call, and `container-close` clears both variables for the `gh` it starts, so their fences carry no `env -u`. Before adding a command here, read the script it names.

1. **Merge**, before any cleanup.

   `[RECOVERY_COUNT]` starts at `0` and grows by one per recovery cycle in this run. Nothing persists it: a run resumed after a compaction, or relaunched by the overseer, starts a fresh count. A run that keeps returning to ci-fix is the signal the cap exists for, whatever the count says.

   Read the repository:

   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY gh repo view --json nameWithOwner --jq .nameWithOwner
   ```

   Save it as `[MERGE_REPO_SLUG]`, and split it at `/` into `[MERGE_REPO_OWNER]` and `[MERGE_REPO_NAME]`.

   `[ALREADY_MERGED]=true` keeps the recorded merge decision in the status file and the PR body and skips to step 2: a merged head may be unavailable, and cleanup needs no attempt.

   **Thread read.** Run § 3.3 on every entry to this step and on every return from the cycles below. Then read the endpoints:

   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY gh pr view [PR_NUMBER] --json baseRefOid,headRefOid --jq '[.baseRefOid,.headRefOid]|@tsv'
   ```

   The head is `[PREPARED_HEAD]` and the base `[PREPARED_BASE]`. Except on a `[MICRO_ENTRY]` run, require `[PREPARED_HEAD]` to equal `[CHECK_HEAD]`; a mismatch returns to § 3 for a fresh readiness check and approval. `[PREPARED_BASE]` is the recorded base, which can trail the base branch's tip (the harness-ci skill's `wiring.md` reference, § The endpoint expressions). A `[MICRO_ENTRY]` run classifies the range, fetching both commits first so a base the worktree's last fetch missed is still measured:

   ```bash
   git -C [WORKTREE_PATH] fetch --quiet --no-tags --no-write-fetch-head origin [PREPARED_BASE] [PREPARED_HEAD]
   ```

   ```bash
   .agents/skills/orch/scripts/orch-runtime tier --base [PREPARED_BASE] --head [PREPARED_HEAD] --repo [WORKTREE_PATH]
   ```

   **The review call before a merge call.** Bind `[REVIEW_BASE_CHECKOUT]` to the consumer base by Gate-mode routing, and run the merge's review call (§ 3). Under `approval` it also settles `[PREPARED_HEAD]`'s Copilot request. Every merge call, the direct attempt's and the `--auto` arm's, re-enters this step, so this call runs before each of them. Hold as § 3's Copilot hold does, `[HOLD_START]` being the time of the first call before this merge call. This call's hold is the one before a merge call, never the triage's `orch-runtime copilot-wait`. Route its last answer:

   - `blocked`, under either mode: § 3.2's `blocked` route.
   - `comments`: § 3.3, then this step again.
   - `unreadable`: run the call once more; a second `unreadable` records `review-gate-read-failed`.
   - `approved` or `proceeded`: go on through this step.
   - `off`: run § 3.3 once more, then go on with no further call. Under the `off` gate mode the call counts no thread, and a review Copilot submits during the hold can open one.
   - `copilot-error`: route as [gates.md § Copilot requests](../references/gates.md#copilot-requests) says, then as the next row.
   - Any other `pending`, a `timeout` or a `changes_requested`: a `[MICRO_ENTRY]` run, or an item whose state carries `pr_approval.forced`, goes on through this step, since its arm leaves the approval to GitHub, which holds the merge until an approval of this head lands. Any other run returns to § 3 for a fresh readiness check and approval.

   A `[MICRO_ENTRY]` run goes on only where the `tier` line reads `tier=micro`, the reply's `mode` is `approval`, and `[MICRO_HEAD]` equals `[PREPARED_HEAD]`. A retarget can change the class without moving the head, so the fresh class carries the tier, the head shows the run is the same, and the mode is the one the item recorded. Any other answer arms nothing and escapes by micro.md condition 8.

   **Restack proof.** Before either merge route, run the proof block of [merge-pr-restack.md step 3](merge-pr-restack.md#merge-pr-restack-cycle) with this step's `[WORKTREE_PATH]`, `[STATE_KEY]` and `[PREPARED_HEAD]`. Where the block asked the reader, keep its reply, its `proof` word and the rows it names, with the merge decision. A nonzero exit records `validation-proof-missing` and takes § 1's unarm and stop routes. A `pending` reply stays pending until the exact-head CI wait or the queue proves it.

   **Merge route.** `pr-merge` picks the route; no step here judges it. It merges past the queue with `--admin` bound to the prepared head and exits `0`, or takes the queue and exits `75`, naming the cause on its `merge-route:` line (`pr-merge --help` § Merge route). Take the direct attempt below first. [submit-pr.md](submit-pr.md) § 2 step 5 arms at creation only a PR this route takes through the queue; where GitHub has queued a PR already, the attempt exits `75`. Two cases take the explicit `--auto --queue` arm below instead, which never passes `--admin`: an item whose state carries `pr_approval.forced`, and a PR on § 3.2's `unknown:` route, whose direct attempt would refuse on that issue.

   **Who acts.** The lane merges its own PR under the token the `github.sh` router selects (`github.sh --help` names the order). An emergency merge exists only in a consumer whose ruleset lists the consumer's own overseer GitHub App as a bypass actor, and only that app makes it. A merge group that cannot pass because a CI input read from the default branch broke takes the recovery route in the review-gate skill's `SKILL.md` § 4. Operations.

   **The direct attempt.** Follow [merge-attempt.md § Direct attempt](../references/merge-attempt.md#direct-attempt) for the CI wait on the approved head, its pending bound, the exact-head attempt and its exit routing. Its exit `75` enters the `queue-watch` wait below.

   **Record the merge decision.** After each attempt here or in [submit-pr.md](submit-pr.md) § 2 step 5, apply [merge-attempt.md § Record the merge decision](../references/merge-attempt.md#record-the-merge-decision) before routing its exit.

   **The `--auto` arm** takes only that same head:

   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY [MAIN_REPO_ROOT]/.agents/skills/github/scripts/github.sh -C [MAIN_REPO_ROOT] pr-merge [PR_NUMBER] --auto --queue --expected-head [PREPARED_HEAD]
   ```

   Exit `0` merged the prepared head: continue to step 2. Exit `1` with a line starting `arm: no-merge-gate=<condition>`, after a `merge-route:` line or not, armed nothing and names why: on § 3.2's `unknown:` route record `merge-readiness-unresolved`; otherwise take the direct attempt above, whose exit `75` routes a base that still queues the PR. Never fall back to a raw `gh pr merge --auto`. Any other exit but `0` or `75` is an exact-head arm failure: report it and return to § 3.2.

   Exit `75` means queued or armed. Run the queue wait below through Waiter launch, under every gate mode. Keep the lane active while polling the completion file, then route the recorded exit and reply. A changes-requested review blocked at § 3.2's readiness check, before this arm; past it no mode reads review state. The wait's late-findings guard reads the review threads while the PR is queued or armed, an armed PR GitHub holds before any queue entry included, and its `dequeued` verdict routes a thread posted after this step's thread read to Late-findings triage.

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/orch-runtime queue-watch --item [STATE_KEY] --repo [MERGE_REPO_SLUG] --pr [PR_NUMBER] --poll 180 --max-wait 540
   ```

   Keep the budget above `QUEUE_WAIT_ARM_GRACE` (120 seconds by default), so a slow enqueue is not read as `not_queued`. The detached wait does not depend on the harness's foreground timeout.

   Route a completed log's `result.verdict` and `result.cause` by the table below. An exit other than `0` is a refusal with its keyed line, a request outside its form (`queue-watch-invalid field=[FIELD]`, `verify-request-invalid field=repo`) among them: report it and stop. Where no exit is recorded, follow [Waiter launch](../references/waiter-launch.md) § Completion.

   Every wait here follows an exit `75`: GitHub reported the PR queued or armed. The item's record keeps the wait's queue memory (`queue_watch`) across waits for the same head and arm, so a PR that left the queue or lost its arm between two waits answers `ejected` or `disarmed` once confirmed. A new head, or a newer arm, starts a fresh memory.

   | `verdict` | Route |
   |-----------|-------|
   | `merged` | Step 2 |
   | `conflicting` | The Restack cycle below |
   | `ejected` | `reach: within` or `reach: unread` takes the Recovery cycle below, with the resolved gate mode and `[RECOVERY_COUNT]`. `reach: outside`, where the consumer's reach command answered every failed check outside the change's paths, re-arms the same head once under the re-queue rule and first sends the failure to the overseer: write `[ITEM_DIR]/queue-reach-[STATE_KEY].md` with the harness file tool, naming the head and each of `failed_checks` with its `reach` and its `url`, then send it with `.agents/skills/mailbox/scripts/lane-mail notice --item [STATE_KEY] --file [ITEM_DIR]/queue-reach-[STATE_KEY].md`. The overseer files it as [oversee-events.md § File one item alone](../references/oversee-events.md#file-one-item-alone) states. A second `outside` ejection at the same head hands back naming both runs |
   | `disarmed` | `cause: merge_hold`: a person, `disarmed_by`, disabled the automatic merge on purpose, and the wait opened the item's merge hold. Take no Recovery cycle and never re-arm: the merge waits on that person. Ask for their answer through the run's question route (in a lane, `lane-mail ask`, [skill-rules.md § Lane mail](../references/skill-rules.md#lane-mail)). When it arrives, first close the hold with `.agents/skills/orch/scripts/orch-runtime op --item [STATE_KEY] --request-json '{"op":"record-pr-progress","step":"merge-answered"}'`, then follow it: a merge returns to step 1, anything else hands back. Any other cause takes the Recovery cycle below |
   | `armed_blocked` | Armed and not enqueued when the wait ended. `cause: check_failed` takes the Recovery cycle below. `cause: not_mergeable` is the wait's last check read before its deadline, which settled as `pass` or `none` with no entry standing; it is no check verdict ([gates.md](../references/gates.md#which-waiter-answers-which-state)). Read the head's CI afresh with merge-attempt.md's `verify-pr` call: `fail` takes the Recovery cycle; `pending` waits again as `armed_awaiting_checks` does; `pass` or `none` returns to § 3 for a fresh readiness check, which names what keeps the PR out of the queue, spending no recovery cycle. A readiness check that passes on the same head arms and waits again under the wall-clock budget below; one that names a blocker routes it by § 3.2 |
   | `dequeued` | Late-findings triage below. On `cause: late_findings_dequeue_failed`, confirm the dequeue or the disarm first |
   | `queued` | Unconfirmed at the deadline. With an entry, every cause but `exit_unconfirmed`, the PR is still armed. `cause: still_progressing`: the merge is live; run the wait again, and repeat until a verdict ends it. `cause: progress_unobservable`: the entry's head could not be read, which is no evidence of an idle queue; run the wait again on the same head under the bound below. `cause: blocked_by_entry_ahead`: take the Entry-ahead wait below, spending no recovery cycle. `cause: stalled`: the Recovery cycle below. `cause: exit_unconfirmed`: not armed; the last poll saw the PR out of the queue and unarmed, short of the confirmation count (`unconfirmed_verdict` names which). Do not wait for it to merge: run the wait once more, which reads the arm afresh, and route its verdict |
   | `armed_awaiting_checks` | Armed, not yet enqueued, and no check failed: GitHub enqueues the PR when its required checks pass. Run the wait again on the same head, whose probe reads the checks afresh, spending no recovery cycle, under the wall-clock budget below |
   | `not_queued` | `cause: never_armed`: no poll saw an arm or entry on this head within `QUEUE_WAIT_ARM_GRACE`, though exit `75` reported one. The arm may never have registered, or may have left before the first poll. Take the Recovery cycle below. Never re-arm here: the arm may have left with a failed merge-group run, which the Recovery cycle reads before anything re-arms, and a red head re-armed into a shared queue can eject the PRs batched with it |
   | `closed` | Hand back with the verdict; no replay |
   | `unknown` | Unrecognized, or `status: error`: a read failed and says nothing about the arm, which after exit `75` is usually still live. Unarm by § 1's rule, then hand back with the `error` and `cause` fields. Never re-arm |

   A `still_progressing` repeat has no limit. Keep the lane active until a verdict ends the wait; after a merge, run steps 2-6.

   For `armed_awaiting_checks`, and for `armed_blocked` with `cause: not_mergeable`, record the time of the first such result on this head and read the budget once:

   ```bash
   .agents/skills/orch/scripts/orch-env QUEUE_WAIT_ARMED_MINUTES 90
   ```

   Repeat the wait while that many minutes have not passed since the recorded time. A new head, or any verdict but those two, clears the record. Past the budget, hand back with the last result's `pending_checks` and the minutes waited, skipping steps 2-6. Under `cause: checks_unread` there are no pending checks: say the checks were never read within the wait's budget. Under `cause: not_mergeable` there are none either: say the last check read settled as `pass` or `none` with no entry. This budget, not `CI_FIX_MAX_CYCLES`, bounds a wait on checks that have not failed. No wait past the budget starts until the overseer, judging with the minutes waited, has appended one `ruling` row for the item through `orch-runtime state log append --fleet` ([oversee-events.md § Judgement rules](../references/oversee-events.md#judgement-rules)).

   **Entry-ahead wait.** Save `queue_ahead_pr` as `[AHEAD_PR]`. Repeat the same `queue-watch` command through Waiter launch. Route `merged`, `closed`, `dequeued` and `status: error` at once by the table. For every other result, read whether the saved entry is still queued:

   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY gh api graphql -f query='query($owner: String!, $repo: String!, $number: Int!) { repository(owner: $owner, name: $repo) { pullRequest(number: $number) { mergeQueueEntry { position } } } }' -F owner=[MERGE_REPO_OWNER] -F repo=[MERGE_REPO_NAME] -F number=[AHEAD_PR]
   ```

   A failed or unreadable response proves no departure: follow § 1's unarm rule, then hand back with that read failure. While `mergeQueueEntry` is non-null, repeat the wait and this read, and route none of these results to Recovery. Once it reads null, the saved entry has left; read this PR:

   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY gh pr view [PR_NUMBER] --repo [MERGE_REPO_SLUG] --json state,mergeable
   ```

   Read `state` first: `MERGED` continues to step 2, and `CLOSED` hands back. On an open PR, `mergeable: CONFLICTING` takes the Restack cycle, and any other value repeats the original wait and routes its fresh verdict by the table. This cause never enters the Recovery cycle.

   For `progress_unobservable`, repeat once on the same head. A second `progress_unobservable` in a row takes the Recovery cycle, as `stalled` does. The reply's progress counts, `progress_head_polls`, `progress_check_reads` and `last_running_count`, report what the wait could read; none of them routes.

   **Recovery cycle.** Route the failure back into ci-fix; never fix CI by hand. Read the cap:

   ```bash
   .agents/skills/orch/scripts/orch-runtime state cap CI_FIX_MAX_CYCLES
   ```

   Its reply's `limit` is `[MAX_CYCLES]`, the recovery cycles one merge-pr run may spend. At the cap, report the failing check names, ci-fix's last error summary and what each cycle attempted, never a bare "persistent failure", then skip steps 2-6 and hand back. No cycle starts past the cap until the overseer, judging with `[RECOVERY_COUNT]` and that `limit`, has appended one `ruling` row for the item through `orch-runtime state log append --fleet`. A gate or CI behaviour change needs a fresh head.

   **The re-queue rule**, which every other workflow points to: after a merge-group run concludes `failure` or `timed_out`, re-arm only a new head, the fix ci-fix pushes. A cancelled merge-group run, or one the infrastructure lost, may re-arm the same head once. So may a red run whose `queue-watch` ejection reads `reach: outside`; a second such red at the same head hands back naming both runs. No other unchanged head re-enters the queue after a red run: the merge-group run is the only proof of a head, and a repeat of the same head spends a full queue run on a known failure.

   1. `⤵ workflows/ci-fix.md [PR_NUMBER] § 1-6 → § 5 step 1` with context `worktree`, `lifecycle: "managed"`, `issue_id`. For a queue ejection the failing run is the **merge-group** run (event `merge_group`), not necessarily the PR-head run. Find it through the ejection's `failed_checks[].url`, which names each failed check's run, or `gh run list --event merge_group --limit 10`, and point ci-fix at it.
   2. Under the gate mode ci-fix returned, re-confirm the gate at the head about to be re-armed; skip this under the `off` gate mode. Write the merge's review call's request (§ 3), then run it as the review wait with the shorter period:

      ```bash
      env PR_REVIEW_WAIT_SECS=300 .agents/skills/orch/scripts/orch-runtime op --item [STATE_KEY] --request "[ITEM_DIR]/verify-review-request-[STATE_KEY].json"
      ```

      `copilot-error` takes [gates.md § Copilot requests](../references/gates.md#copilot-requests), then this wait again before re-arming. `comments` takes § 3.3, then this wait again. `blocked` takes § 3.2's `blocked` route. `approved`, `proceeded` or `timeout` goes on to step 3, where step 1's call routes the head. `changes_requested` returns to § 3. `unreadable` runs the call once more; a second records `review-gate-read-failed`.

   3. Return to step 1 and wait.

   **Restack cycle.** The base, not CI, is the blocker. Follow [merge-pr-restack.md](merge-pr-restack.md), then return to step 1. Never route a conflict into ci-fix.

   **Late-findings triage.** The findings, not CI, are the blocker.

   1. On `cause: late_findings_dequeue_failed`, first take [merge-pr-restack.md](merge-pr-restack.md) step 1's disarm, then dequeue, with its PR node id read: the PR must be out of the queue before triage pushes.
   2. Run § 3.3. With the head unmoved, return to step 1 and wait.

2. **Post the merge comment, complete the issue and close a finished container.** **Skip if** `TRACKER=none`, a directed change ([SKILL.md § Tracker Resolution](../SKILL.md#tracker-resolution)): it has no tracker item to post to or complete.

   Before tracker completion or worktree cleanup, post the merge summary through [post-summary.md § 1](post-summary.md#1-post-the-summary), with this PR and item's caller context. A direct delivery ([submit-pr.md § 2.1](submit-pr.md#21-base-publication)) passes no `pr_number`, so the summary goes on the Linear item alone; a direct delivery of a GitHub-tracked item posts no summary. Include every actual round's and run's Validation Routes under [dev-implement.md § 9.1](../../dev/workflows/dev-implement.md#91-completion-summary-file), the fix and restack runs since the previous summary among them. Keep the original pending, failed and no-verdict rows after the merge-group CI passes, and record that CI proof separately by its run reference. Post each bundled child's rows on its own item through the same comment interface. A validation-routing Done-when box reads these comments on that item.

   **Linear only from here**, under [SKILL.md § Tracker Resolution](../SKILL.md#tracker-resolution): the rest of this step runs for a Linear item alone.

   The lane owns completion after merge. Where its sandbox is gone, or its item reads Done with the lane ended, the runtime's close completes the item from the PR body's `## Done-when evidence` section. The overseer owns the remaining post-merge checks on the same item.

   Give every development remainder from a cut its own issue or bundle before completion. Prove every branch-provable Done-when box before merge. Keep post-merge boxes on `[ISSUE]` in the form the project-management skill's `SKILL.md` § Disposition states: each box names its reading, its location, why the branch cannot prove it, and a deadline in that section's form.

   Linear's GitHub integration can set `[ISSUE]` Done when the PR merges. Read the item live and complete it with the command below. It sets Done when no post-merge box remains open, and Verifying otherwise, including when the integration already set Done. The merge lane never writes In Review or In Progress. Box acceptance follows [SKILL.md § The Cycle](../SKILL.md#the-cycle), The overseer reads results. For a failed post-merge check, follow [oversee-events.md](../references/oversee-events.md) § Verification.

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

   Write `[EVIDENCE_FILE]` under the checkout's `tmp/`, one `N: text` line per selected box, the text citing the recorded proof. On a pull-request delivery, take `[MET_BOXES]` and those lines from the `## Done-when evidence` section of that body. A direct delivery ([submit-pr.md § 2.1](submit-pr.md#21-base-publication)) creates no pull request and reads no body. Include an already-ticked box whose Evidence line needs adding from the existing evidence comment. Select `[MET_BOXES]` under the acceptance rule: `all` only where that rule accepts every box, otherwise their numbers in section order from 1, comma-separated. Where no box needs a tick or an Evidence line, omit both `--done-when-met` and `--evidence-file`. A section of plain bullets with no checkbox takes `all`, which ticks nothing and sets Done.

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/linear/scripts/linear.sh issues complete [ISSUE] --post-merge-at [MERGED_AT] --done-when-met [MET_BOXES] --evidence-file [EVIDENCE_FILE]
   ```

   The command refuses an open branch-provable box or invalid post-merge metadata before any write. A rate-limited completion is held under the linear skill's `patterns/workflow-actions.md` § Quota Holds, never recorded as a failed step. A required supersession that fails stays a tracker-completion failure after Done: keep the transition and its structured `supersession-incomplete` diagnostic, then retry through the same completion command with the action and options it gives, without summary flags. An open child's disposition comes before that retry can succeed. Done alone does not prove these effects completed. A canceled or unreadable issue is a tracker failure, not a merge record: carry the diagnostic into § 6 and claim no tracker completion.

   **Complete the in-PR bundle's children.** This step alone selects each child's proved boxes and completes it at merge. The `issues get [ISSUE]` read above lists the children as `.children` rows, each with its `.id` and `.state_type`; include children the GitHub integration already set Done. For each non-canceled child this PR's child `Closes` lines name, repeat the live read and the `issues complete` command with that child's id, its own box selection and evidence file, and the same `[MERGED_AT]`. Keep `[ISSUE]` bound to the parent and post-merge boxes on each child. The call moves a qualified started child to Verifying while post-merge boxes remain open, and to Done otherwise. Record each child still Verifying in § 6 for the overseer. A child read or completion failure is a tracker-completion failure. Reconciliation finds a child closed on its parent's `Closes` line by its key search. Where it reports `verifying-merge-unread` for a shared child's release-triggered or `+Nh` merge box, `orch-runtime reconcile-items --merged [CHILD]=[OWNER/REPO]#[PR_NUMBER]` judges the box from this merge ([verify.md § 1](verify.md#1-read-open-checks)); name it in the child handoff.

   **The container closes when its last child closes.** Read `.parent_id` from the live issue; empty → step 3. Fetch the parent with its bundle. Children, or an `agent:multi` label, make it a container unless its read reports `in_pr_bundle` true ([skill-rules.md § Coordination](../references/skill-rules.md#coordination)). Not a container → step 3. An unreadable parent is a tracker failure. Close the container through the runtime's serialized close, which keeps it open while a child is open:

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/orch-runtime container-close [MAIN_REPO_ROOT] [PARENT_ID]
   ```

   Keep its stderr diagnostics for § 6. Route its output:

   - `container-close: left cause=confined owner=overseer`, exit `0`: a confined lane closes nothing here, and the overseer's own route closes the container. Record `container [PARENT_ID] left to the overseer` in § 6, and climb no further.
   - `closed [PARENT_ID]`: record `[PARENT_ID] → Canceled` in § 6 where its stderr carries `container-close: canceled parent-id=[PARENT_ID]`, else `[PARENT_ID] → Done`. If this container has a container parent, repeat this step for that parent.
   - `deferred [CHILD_IDS...]`: record `container [PARENT_ID] stays open (pending: [CHILD_IDS])` in § 6. Where `[ISSUE]` is among them and reads Verifying, the overseer closes the container after verification sets it Done. A bare `deferred` means the lock wait expired: report it.
   - `held [PARENT_ID] [HOLD_RESET]`: hold the command under the linear skill's `patterns/workflow-actions.md` § Quota Holds, and climb no further.
   - A nonzero exit keeps the container open. Carry its diagnostic into § 6, climb no further, and report `container [PARENT_ID] stays open; rerun orch-runtime container-close once [CAUSE] is fixed`. A `completion-refused` refusal prints each refused row; follow each row's `remedy` before the rerun.

3. **Sync the main repo.** In a lane, skip this step: once the overseer's close records the landing, it brings the base checkout to the landed base with `sync-base`. A run outside a lane syncs after every merge:

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/sync-base [MAIN_REPO_ROOT]
   ```

   Its stdout is `[BASE_BRANCH]`. On success, read `refs/heads/[BASE_BRANCH]` as `[NEW_SHA]` and report it in § 6. On a non-zero exit the base stays unsynchronized: carry the script's diagnostic into § 6's warning, then read the branch and the two SHAs before cleanup:

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

4. **Prepare branch and worktree cleanup.** In a lane, skip this step: the overseer's close stops the lane's session, then releases its worktree, removing a clean, merged one and keeping a dirty or unmerged one with its reason. A run outside a lane cleans up the PR's own branch and worktree alone, never unrelated branches or sibling worktrees:

   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY gh pr view [PR_NUMBER] --json headRefName --jq .headRefName
   ```

   **The disposal predicate.** It holds when the PR's worktree exists, its tree is clean, and its checked-out branch is still `[PR_BRANCH]`. Read the two facts:

   ```bash
   git -C [WORKTREE_PATH] status --porcelain
   ```

   ```bash
   git -C [WORKTREE_PATH] branch --show-current
   ```

   It holds on empty output from the first and `[PR_BRANCH]` from the second. Otherwise the cause is `dirty tree` or `branch moved`; a command that exits non-zero fails its fact as `tree unreadable` or `branch unreadable`. The predicate answers only where it proves a fact, never from absent output. Step 6 runs it again, whole, just before the removal, and removes only where every part holds. Anything else keeps the worktree and its branch, and the cause goes on § 6's worktree line. A worktree kept on another branch leaves the merged branch to the branch delete below.

   **The merged predicate is `worktree cleanup`'s**: ancestry into the repository's default branch, or, where ancestry fails, a pull request merged into that default branch whose head commit is the local branch's tip. A squash merge leaves no ancestry, so the second proof is the one every PR landing through the queue meets, and the commit proves it: a branch carrying commits past its merged PR is unmerged work. `worktree remove` applies this predicate when it deletes the branch: a nonzero exit after the tree is gone means the branch survived, and its diagnostic names the answer the lookup gave. Report that as `kept` in § 6's `Branch` row.

   With no qualifying worktree, delete the local `[PR_BRANCH]` only where no worktree owns it. Check first:

   ```bash
   git -C [MAIN_REPO_ROOT] worktree list --porcelain
   ```

   A `branch refs/heads/[PR_BRANCH]` line means a worktree still has it checked out: keep it, and note it in § 6. With no such line, and the branch present locally and not current, compare the PR's head with the branch's tip:

   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY gh pr view [PR_NUMBER] --json headRefOid --jq .headRefOid
   ```

   ```bash
   git -C [MAIN_REPO_ROOT] rev-parse "refs/heads/[PR_BRANCH]"
   ```

   Equal → `git -C [MAIN_REPO_ROOT] branch -D "[PR_BRANCH]"`. Different → the branch carries commits the merge did not take: keep it and report it `kept` in § 6's `Branch` row. Never `git branch -d` here: it proves merge against the branch's configured upstream, which `worktree push` sets, so it passes for any pushed branch however far it is from `[BASE_BRANCH]`.

   For `merge-pr all`, or on the user's request, also sweep the project. Check each local branch with `env -u GH_REPO -u GITHUB_REPOSITORY gh pr list --head [BRANCH] --base [BASE_BRANCH] --state all --json number,state,headRefOid,isCrossRepository`. Delete without asking only a branch with no worktree whose tip equals the `headRefOid` of one of its **merged**, non-cross-repository PRs, the predicate `worktree cleanup` applies. Neither state alone nor a merge into another base passes: a closed PR merged nothing; a PR merged into a release or other side branch left its commit out of `[BASE_BRANCH]`; a merged PR whose head differs from the tip left the extra commits reachable from this ref alone. Leave every other branch, and ask before removing a stale worktree or a branch with no PR. Compare `ls [TREES_DIR]/` with `worktree list --porcelain` for orphan folders, and ask before removing any.

5. **Answer the threads the wait's guard did not catch.** GitHub's merge queue never re-checks thread resolution once a PR is admitted. `queue-watch`'s late-findings guard does, on its own probe clock (`QUEUE_WAIT_PROBE_INTERVAL`, 120 seconds by default), so a finding that lands inside that gap, or after the merge, rides the merge in. A PR [submit-pr.md](submit-pr.md) § 2 step 5 armed at creation has a wider gap: GitHub can enqueue it while the lane is still in submit-pr § 3 to § 6, and a thread posted before step 1's queue wait starts rides the merge in too. Read the merged PR's unresolved threads once and answer each. Resolve the merge commit first, since the queue merged a head this run never saw:

   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY gh pr view [PR_NUMBER] --json mergeCommit --jq .mergeCommit.oid
   ```

   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY [MAIN_REPO_ROOT]/.agents/skills/github/scripts/github.sh -C [MAIN_REPO_ROOT] pr-threads [PR_NUMBER] --unresolved
   ```

   That oid is `[MERGE_SHA]`. Each reply is one of the three dispositions of [finding-disposition.md](../../reviewer/references/finding-disposition.md): `Declined: [reason]`, `Fixed in [MERGE_SHA]`, or `Tracked: [ISSUE_ID]` with the issue created first under [skill-rules.md § Coordination](../references/skill-rules.md#coordination). Reply and resolve through `github.sh post-reply` and `github.sh resolve-thread`, clearing the two variables and passing `-C [MAIN_REPO_ROOT]` as the read above does. This read happens once: nothing reads a merged PR's threads after it.

6. **Verify the project and close the item out.** Run the build, install and verification work the project's own instructions require after a merge. This workflow defines no generic command and infers none. A project's install record (`.kendex-lock.json`) is recorded by the route its own instructions name, never by the lane after a merge or a restack. On failure, report the command and its diagnostic in § 6 and keep the worktree.

   **The close-out in a confined lane.** Skip the copy and the close-out below. `state remove` answers `state-remove: left cause=confined owner=overseer` at exit `0` and changes nothing. The overseer's close of the lane removes the item's files after their archive, and its cycle row reads the live record. § 6's `tmp/ close-out` line reads `left to the overseer's close`.

   **The close-out elsewhere.** In an unconfined lane, save the item's record before the close-out, for the overseer's cycle row. Read its path, the reply's `result.path`, with `orch-runtime state path --item [STATE_KEY]` from `[MAIN_REPO_ROOT]`. Create `[MAIN_REPO_ROOT]/tmp/cycle-state/` if needed, and copy the record once to `[MAIN_REPO_ROOT]/tmp/cycle-state/workflow-state-pr-[PR_NUMBER].json`, named by the merged PR whatever `[STATE_KEY]` is: a PR number names one merge, so a later merge of the same item never reads this copy as its own. The copy sits outside the worktree and inside `tmp/cycle-state/`: the close-out takes the item's own folder `items/[STATE_KEY]/` whole and judges the other top-level state entries by item name, so a copy directly under `tmp/` would leave too. Where an earlier close-out already removed the record, keep the saved copy. Where neither reads as a JSON object, report the failure and keep the worktree. The overseer's close reads the live record first, then this copy, and leaves the copy in place, so a repeated close reads it again.

   Close the item out under the main checkout's state folder before any worktree removal. Where § 4 found an issue worktree, name its `tmp/` for the close-out's archive; otherwise drop the `--archive` pair:

   ```bash
   .agents/skills/orch/scripts/orch-runtime state remove --item [STATE_KEY] --archive [WORKTREE_PATH]/tmp
   ```

   [schemas/workflow-state.md § Item close-out](../schemas/workflow-state.md#item-close-out) states what it takes, archives and keeps. Its reply's `result.kept` names the archive holding the item's state and the worktree's `tmp/` records, or is null where no archive root is set; it goes on § 6's `tmp/ close-out` line. A refusal keeps the worktree, since the worktree's records may be in no archive: the refusal's key goes on that line, and the worktree line reads `standing — close-out refused`.

   **The worktree.** A lane leaves its worktree: the overseer's close stops the session, then releases the worktree (step 4). § 6's worktree line reads `standing — left to the overseer's close`. A run outside a lane removes it once the project verification passed and the close-out is done. Run step 4's disposal predicate again, whole: step 5's replies and this step's build can each dirty the tree or move the branch. `worktree remove` runs `git worktree remove --force` and then deletes the folder, so it refuses nothing itself: uncommitted content, untracked content and a worktree moved to another branch all leave with the folder. The predicate is the only guard. Every part holding, remove it from `[MAIN_REPO_ROOT]`, so the run is not deleting its own working directory:

   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY [MAIN_REPO_ROOT]/.agents/skills/worktree/scripts/worktree remove [ISSUE]
   ```

   A foreign-lease refusal keeps the worktree; carry its diagnostic onto § 6's worktree line. Where § 4 found an issue worktree, read its path last, whichever way the removal went:

   ```bash
   ls -d -- "[WORKTREE_PATH]"
   ```

   `No such file or directory` is the removal; a listed path is a worktree still standing. Write § 6 after this step, never before.

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

The `Container` row appears only where § 5 step 2 found a container parent. In a lane, the `Branch` row reads `left to the overseer's close` and the `Base sync` row reads `left to the overseer's close`. Where § 5 step 3 failed, `Base sync` carries the warning in place of a SHA: `⚠️ local [BASE_BRANCH] STALE at [LOCAL_SHA] (origin/[BASE_BRANCH] at [ORIGIN_SHA]) — [CAUSE]`. The worktree line closes the block with step 6's reading: `gone`, or `standing — [cause]`, the cause being the one step 4's disposal predicate named, `foreign lease`, `project verification failed`, `close-out refused` or `left to the overseer's close`. Omit it only where § 4 found no issue worktree. The `tmp/ close-out` line carries the archive step 6's close-out reported, its refusal key, or `left to the overseer's close`; omit it where that step never ran. Add a `Review gate` row only where the merge did not proceed on a plain `approved` verdict: `⚠️ reviewer-down proceed (no reviewer posted; PR_REVIEW_ON_TIMEOUT=proceed)` or `⚠️ forced (user override)`.

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

The merge is complete once § 5 steps 1-6 have run. A run outside a lane whose issue worktree still stands, with no cause on § 6's worktree line, has not finished. A run that handed back at a verdict other than a merge reports that verdict and ends; it does not resume.
