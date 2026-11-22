# Submit PR Workflow

Publish one item's branch: validate and review it locally, push, open or update the pull request, triage review comments, wait for the review gate, verify CI and confirm the merge gates. Under `push-base` delivery, § 2.1 publishes to the base branch instead, and no pull-request section runs.

- Run each review wait and each `verify-pr` call through [Waiter launch](../references/waiter-launch.md).
- A [review call](../references/gates.md#the-review-call) that reads only its `mode` or its `request` runs directly.

| Command | Behavior |
|---------|----------|
| `submit-pr` | Submit the current branch |
| `submit-pr [PR#]` | Manage an existing pull request |
| (from start-worktree) | Managed lifecycle with caller context |

**Caller context** (via `⤵`): `worktree`; `lifecycle`, `"managed"` (return at § 7) or `"self"` (the default); `issue_id`, the workflow-state key: the normalized issue ID, never the bare GitHub issue number.

Resolve the decision mode once for every post-PR choice in this workflow:

```bash
.agents/skills/orch/scripts/orch-env ORCH_DECISION_MODE auto-recommended
```

**With a PR number**:

- `.agents/skills/github/scripts/github.sh pr-issue [PR_NUMBER] --format=text` prints `ISSUE_ID`.
- `.agents/skills/worktree/scripts/worktree exists` and `worktree path` give `[DIR]`.
- Where no worktree exists and you are inside the pull request's checkout, `auto-recommended` creates one and logs the choice; `ask` asks first.

With no argument, `[DIR]` is `.`. `WT_PATH` is what `.agents/skills/orch/scripts/git-context repo-root "[DIR]"` prints.

**Standalone init** (`lifecycle: "self"`):

1. Bind `ISSUE_ID` from `git-context issue-from-branch .`.
2. Run `.agents/skills/orch/scripts/orch-runtime state exists --item [ISSUE_ID]`.
3. Where it reports no record, read the branch with `git-context branch [WT_PATH]`, then create the record with `orch-runtime state init --item [ISSUE_ID] --worktree [WT_PATH] --branch [BRANCH]`.

**Every path** resolves `TRACKER` and `ISSUE_REF` from `ISSUE_ID` per [SKILL.md § Tracker Resolution](../SKILL.md#tracker-resolution). It resolves `SUB_ISSUE_REF` the same way from each completed sub-issue's ID.

---

## 1. Preflight And Local Review

### 1.1 Preflight

```bash
.agents/skills/orch/scripts/resolve-base-branch "[WORKTREE_PATH]"
.agents/skills/orch/scripts/git-context branch "[WORKTREE_PATH]"
git -C "[WORKTREE_PATH]" status --porcelain
git -C "[WORKTREE_PATH]" diff "origin/[BASE_BRANCH_FROM_PREVIOUS_COMMAND]"...HEAD --stat
```

Stop before pushing when:

- the branch is empty (detached HEAD);
- the branch is the base branch;
- the working tree is dirty; or
- the committed diff against the base is empty.

In the managed lifecycle, return a failed preflight to the caller, so the dev agent can normalize the branch and clean the worktree.

Bind `[REVIEW_BASE_CHECKOUT]` by [gates.md § Gate-mode routing](../references/gates.md#gate-mode-routing).

Ask the consumer's committed policy whether the preflight stage runs:

```bash
.agents/skills/orch/scripts/orch-runtime validate policy --base-checkout "[REVIEW_BASE_CHECKOUT]" --stage preflight
```

On `.result.answer` `skip`, skip the preflight run. On `run`, run it:

```bash
.agents/skills/preflight/scripts/preflight --base "origin/[BASE_BRANCH_FROM_PREVIOUS_COMMAND]" --repo "[WORKTREE_PATH]"
```

- On `run` with no preflight script installed, report that in one line and continue.
- A failing preflight blocks the push.

**Accepted dev round.** Read an accepted dev round's receipt through the runtime's acceptance check. Add `--expect-items-from-round` for a fix round:

```bash
.agents/skills/orch/scripts/orch-runtime dev-return --text check --worktree [WORKTREE_PATH] --issue [ISSUE_ID] --round-id [DEV_ROUND_ID]
```

Read only the receipt at its returned `path`, through `orch-runtime dev-return --text check --file [SELECTED_PATH]`.

- A valid `ci` receipt for the current commit accepts the completed local edits, with required CI pending after publication.
  - Start no `DEV_VALIDATE_CMD` for it.
  - After publication, § 5 and § 5.1 read the pull request's required CI.
  - Where the change is queue-only, that run proves no head; the merge-group run the receipt's record names by `ci-event=merge_group` proves it ([merge-pr.md § 5](merge-pr.md#5-execute-the-merge)).
- A failing dev validation artifact blocks submission. Report it and start no validation run.
- Never re-run a dev `no-verdict` result for the current commit.
  - With `validate_mode` `ci`, it goes on with required CI pending after publication, as a `ci` receipt does.
  - With `validate_mode` `full` or `range`, no required CI holds its proof: it is unproved, blocks the push and starts no run.
- In a project whose own policy forbids orch's validation runner, reuse a dev `pass` as it stands where its `commit` is the current HEAD and its `validate_mode` is `full`.
  - Its receipt comes from a [foreground validation record](../schemas/dev-return.md#foreground-validation-record).
  - Ask the runtime nothing and start no run.

**Proof rows.** For any other dev result, or none, ask the runtime, read-only, whether the item's proof rows already prove the current commit under the project's declaration:

```bash
SUBMIT_HEAD="$(git -C "[WORKTREE_PATH]" rev-parse HEAD)"
SUBMIT_TREE="$(git -C "[WORKTREE_PATH]" rev-parse "HEAD^{tree}")"
SUBMIT_BASE="$(git -C "[WORKTREE_PATH]" merge-base HEAD "origin/[BASE_BRANCH_FROM_PREVIOUS_COMMAND]")"
if ! SUBMIT_PROOF="$(.agents/skills/orch/scripts/orch-runtime read-proof --item [ISSUE_ID] --need submit --tree "$SUBMIT_TREE" --head "$SUBMIT_HEAD" --base "$SUBMIT_BASE")"; then
  exit 1
fi
SUBMIT_PROOF_WORD="$(jq -r '.result.proof' <<<"$SUBMIT_PROOF")"
```

Where the item's dev round closed `pass-excused`:

1. Take that round's `exception` object from its row in the item's `stages` (`orch-runtime state get --item [ISSUE_ID] /stages`).
2. Write it to `[WORKTREE_PATH]/tmp/round-exception-[ISSUE_ID].json` with the harness file tool.
3. Add `--exception-file [WORKTREE_PATH]/tmp/round-exception-[ISSUE_ID].json` to the `read-proof` line.

| `SUBMIT_PROOF_WORD` | Action |
|---|---|
| `complete` | Reuse the run `.result.rows[0].run_dir` names |
| `pending` | Accept the commit with required CI pending after publication, as a `ci` receipt does |
| `missing`, or a refusal | Run the project's `DEV_VALIDATE_CMD` through `.agents/skills/orch/scripts/orch-runtime validate entry` |

Start and poll the `missing` run as [dev SKILL.md § Long-Running Validation](../../dev/SKILL.md#long-running-validation) sets out, the route [dev-implement.md § 5. Validate](../../dev/workflows/dev-implement.md#5-validate) takes.

- A run this submit starts that ends `no-verdict` takes the route that section gives a dev round's `no-verdict`.
  - Its `--base` is the merge base of HEAD and `origin/[BASE_BRANCH_FROM_PREVIOUS_COMMAND]`.
  - Run no suite list by hand.
  - Where its final record's `validate-mode` is not `ci`, the result is unproved and blocks the push.
- A start refused as `run-live` ran nothing. It blocks no push and returns nothing to the caller. Take that section's route for the refusal, then start again.
- A changed commit needs a new result.

Retain the mode of the validation result this section accepts as `SUBMIT_VALIDATE_MODE`:

- For an accepted dev receipt, it is the receipt's `validate_mode`.
- For a `complete` or `pending` answer, it is `.result.rows[0].mode`, and `[RUN_DIR]` is `.result.rows[0].run_dir`.
- For a run this submit starts, a `ci` run with `verdict=pending` included, bind `[RUN_DIR]` to its run directory. Read its mode from the run's own record:

```bash
if ! SUBMIT_VALIDATE_RECORD="$(.agents/skills/orch/scripts/orch-runtime validate entry --record --run-dir "[RUN_DIR]")"; then
  exit 1
fi
SUBMIT_VALIDATE_MODE="${SUBMIT_VALIDATE_RECORD%% *}"
SUBMIT_VALIDATE_MODE="${SUBMIT_VALIDATE_MODE#validate-mode=}"
```

### 1.2 Local Pre-PR Review

Drain what a review bot would surface before the pull request exists.

**Skip if** `lifecycle` is `"managed"`, or a PR number argument was given (§ 3 triages the comments that arrived). Otherwise ask the committed policy whether the local review runs:

```bash
.agents/skills/orch/scripts/orch-runtime validate policy --base-checkout "[REVIEW_BASE_CHECKOUT]" --stage local-review
```

- On `.result.answer` `skip`, go to § 2.
- On `run` with `.agents/skills/second-opinion/scripts/second-opinion` not installed, report that in one line and go to § 2.

1. Apply the admission of [workflow-state.md § Record verified findings](../schemas/workflow-state.md#record-verified-findings) to this local batch, with state writes enabled. Its freshness boundary is `LOCAL_STARTED_AT`.
2. Launch the review. It backgrounds itself and prints when to check:

```bash
mkdir -p [WORKTREE_PATH]/tmp
.agents/skills/orch/scripts/git-context timestamp compact
.agents/skills/second-opinion/scripts/second-opinion review --cwd [WORKTREE_PATH] --output [WORKTREE_PATH]/tmp/review-local-[TIMESTAMP_FROM_PREVIOUS_COMMAND].json --foreground
```

Capture the launch's status, stdout and stderr. A nonzero launch, or stdout with no line beginning `wait:`, has no wait protocol. On a launch with no wait protocol:

- Report `local external review failed — [SECOND-OPINION STDERR]`.
- Run neither the wait nor the check below.
- Go to § 2.

Otherwise:

1. Run the exact command printed after `wait:`.
2. Repeat it as its exit code says (`second-opinion --help`) until it is terminal, doing other event checks in between.
3. Apply the shared contract's acceptance to `LOCAL_OUTPUT`, the `--output` path:

```bash
.agents/skills/orch/scripts/orch-runtime review-artifact --text check --file "$LOCAL_OUTPUT" --worktree [WORKTREE_PATH] --delegated-at [LOCAL_STARTED_AT] --issue [ISSUE_ID]
```

| Result | Action |
|---|---|
| `ok == true` | Route the findings below |
| `reason == "valid_undermeasured"` | Report its `measurement_failed` string, and `measurement_suppressed` where present, with the findings; never treat the pass as clean |
| `ok == false`, or a nonzero exit | Report `reason` and its `detail`, and go to § 2 |

The local review is advisory. It never blocks submission, and none of those outcomes is a pass.

1. Route the findings per the `review-finding` schema.
2. Disposition every finding per [finding-disposition.md § Decision flow](../../reviewer/references/finding-disposition.md#decision-flow), Step 0 first. Only what survives enters the fix set.
3. Complete the shared contract for this batch before you take any route below.

- No blockers and no `category: "fix"` or `category: "issue"` suggestions: go to § 2.
- Blockers and fix-category suggestions: `⤵ workflows/dev-fix.md § 1-3 → § 1.2 tail` with context `worktree`, `lifecycle: "managed"`, `issue_id`, `items` (the blockers and fix-category suggestions) and `source: local-review`.
- `category: "issue"` suggestions, and the fix round's escalated items that clear the filing bar of [finding-disposition.md](../../reviewer/references/finding-disposition.md):
  1. Build an audit-input file at `tmp/audit-local-review-YYYYMMDD-HHMMSS.json` per `.agents/skills/project-management/schemas/audit-issues-input.md` with `source: "local-review"`.
  2. Apply [skill-rules.md § Coordination](../references/skill-rules.md#coordination), then `⤵ .agents/skills/project-management/workflows/audit-issues.md --issues [FILE_PATH] § 1-9`.
  3. Each escalated item takes the `origin` its `outcome` maps to in [review-pr.md](review-pr.md) § 8.
  4. List the created IDs in the PR body.

**One confirming pass.** If dev-fix applied commits:

1. Take the shared contract's fresh admission.
2. Launch and accept the review once more over the updated diff, with the same disposition and completion. This pass delegates no further fix round.
3. Run § 1.1's validation for the new HEAD.
4. Go to § 2, whatever the review found.

If dev-fix applied nothing, go to § 2.

---

## 2. Push And Submit

Read the delivery setting in `[WORKTREE_PATH]` before any pull-request read or push:

```bash
.agents/skills/orch/scripts/orch-env ORCH_DELIVERY pr
```

- `pr`, or no value, takes the steps below.
- `push-base` takes § 2.1 instead, also where a tier enters only steps 1-4.
- A failed setting read stops publication.

**A cut after the last review pass.**

- Set the `pre_delegate_sha` boundary in the item's state to the cut commit's parent.
- Route exactly once through [review-pr.md § Bounded Re-Review](review-pr.md#bounded-re-review) before the push.
- Keep the cut in a commit whose parent holds everything it deletes.

**Before every push**, read the pull request and whether auto-merge is armed:

```bash
.agents/skills/orch/scripts/orch-runtime pr view "[WORKTREE_PATH]" --json number,state,autoMergeRequest
```

Record whether `autoMergeRequest` is set.

- While workflow state `pr_order` reads `open-first` or `push-first`, an armed pull request was armed before its internal review returned. Unarm it first by [merge-pr-restack.md](merge-pr-restack.md) step 1; its hand-back pushes nothing and returns to the caller.
- After § 6.1 confirms every merge gate, an armed standalone submit enters [merge-pr.md](merge-pr.md) from its entry point.
- An armed managed submit returns that recorded decision with its final result, and the caller's merge stage owns the lifecycle.

Arm only through `github.sh pr-merge --auto` (step 5). A raw `gh pr merge --auto` is never the arm.

1. **Push.** With workflow state `pr_order` reading `open-first-returned` or `push-first-returned`, the first pass after the internal review runs § 3's triage first. That is the review of the pull request [start-worktree.md](start-worktree.md) § 2.1 opened.

   - Run `⤵ workflows/review-pr-comments.md [PR_NUMBER] § 1-8 → § 2 step 1 push` with managed context, `[PR_NUMBER]` being the `number` the `pr view` read above printed.
   - Its fix round commits on top of the internal review's, and its `record-push` request (that workflow's § 6.1) carries both.
   - It resolves its own fix SHAs through `.rebase_map` before its replies cite them.
   - The triage returns to the push request below, never to the start of this step.

   Write `[WORKTREE_PATH]/tmp/submit-push-[ISSUE_ID].json` with the harness file tool as `{"op": "record-push", "mode": "branch", "worktree": "[WORKTREE_PATH]", "args": ["--set-upstream"]}`, then run it:

   ```bash
   .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request [WORKTREE_PATH]/tmp/submit-push-[ISSUE_ID].json
   ```

   - `args` are the worktree skill's own push flags, passed as written.
   - The push rebases onto the updated base where that base needs it. The request reconciles every SHA workflow state records.
   - A merge-queue base takes the rule of `worktree push --help` § Merge-queue base.
   - Route the exit as [merge-pr-restack.md](merge-pr-restack.md) step 3 does. The reply's `push` carries the worktree skill's own exit and output.

   A `worktree-push-base-conflict` refusal in that output pushed and rebased nothing; the guarded restack is its one rebase. Run [merge-pr-restack.md](merge-pr-restack.md) steps 1-3, then continue here. A red validation run there hands back instead.

   - Regenerate any drafted publication text from the reconciled state.
   - Resolve every SHA taken from a review or QA artifact, such as a perf QA `benchmark_commit`, through `.rebase_map` before you publish it. Follow the chain until no key matches.
   - Never publish an unreconciled pre-rebase SHA.

   **Open-first head.** On the `open-first-returned` pass, once the push lands, this step owns the pushed head. It ends the overseer's hold and routes the head once.

   - In a lane whose brief names a status file, replace the pending line with `Review: [VERDICT]`, the verdict [review-pr.md](review-pr.md) § 9 returned.
   - Then, in a lane or not, record the pass, so no later pass repeats the triage-first branch:

   ```bash
   .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-pr-progress","step":"order","order":"open-first-pushed"}'
   ```

   **Published-head route.** Run [review-pr-comments.md § 7.2](review-pr-comments.md#72-copilot-head-route) from its current-head Copilot wait.

   - Keep `[REVIEW_READ]` for its **Head moved** route.
   - Keep its body checks, its policy and refusal handling, and its **Head unmoved** notice for a completed review on the unchanged head.
   - Bypass its **Skip if** conditions for this publication pass: route the published head whatever threads the triage answered.
   - With no Copilot review, the head takes **Head moved**, an unchanged push-first head included.
   - That section's review call settles its request by [gates.md § Copilot requests](../references/gates.md#copilot-requests).

2. **Check for an existing pull request**:

   ```bash
   .agents/skills/orch/scripts/orch-runtime pr view "[WORKTREE_PATH]" --json number,state
   ```

   `{"status":"no_pr","number":null}` means create one in step 4. A failed read exits 1: stop and report it.

3. **Build the PR body.** Write it to `[WORKTREE_PATH]/tmp/pr-body-[ISSUE_ID]-[TIMESTAMP].md` (`git-context timestamp compact`) with the harness file-write tool or `apply_patch`, never redirection or a heredoc. Bind that path as `BODY_FILE`:

   ```markdown
   ## Summary
   [1-3 bullets describing the changes]

   ## Merge danger
   - **Door:** [one-way or two-way. A change that deletes data, migrates a format or changes a published contract is one-way.]
   - **Blast radius:** [who breaks if this is wrong]

   ## Context
   - **[DECISION_ID]**: [ONE_LINE_SUMMARY] — `[DECISION_FILE_PATH]`
   - **Research**: [TITLE] — `[RESEARCH_FILE_PATH]`

   ## Completed Issues
   - Closes [ISSUE_REF] - [TITLE]
     - Closes [SUB_ISSUE_REF] - [SUB_TITLE]

   ## Done-when evidence
   [N]: [PROOF]

   ## Created Issues
   - [ISSUE_ID] - [TITLE] — Project: [PROJECT]

   ## QA Metrics
   [Results from the QA agents that ran — project-configurable.]

   ## Merge decision
   [Pending the merge attempt. The lane records the returned merge-route line here.]

   ## Proposed rules
   [Each string in workflow state `pr_comment_review.proposed_rules`.]

   ## Test Plan
   [Before-and-after evidence: the test that failed before and passes now, or the command output before and after.]
   ```

   - Keep `## Merge decision` and `## Merge danger`: every change has a Door answer.
   - On an existing pull request, keep its recorded merge decision through body updates. Use the pending text only before any attempt is recorded.
   - Omit the other empty sections.
   - Write one `N: text` line under `## Done-when evidence` for each branch-provable Done-when box. `N` is the box's number in section order from 1; the text is its proving artifact at the head.
   - Keep the `## Done-when evidence` section current on every body update. The runtime's close reads it where the lane cannot complete the item.
   - Include each proposed rule once, and do not perform it.
   - Take decision paths only from `decisions search --issue [ISSUE_ID]`.
   - Check each decision path with `test -f [DECISION_FILE_PATH]`, one command per path. Omit a path that fails.
   - Include qualified started bundle children in the child `Closes` lines: this pull request carries their implementation.
   - For a GitHub item, save its live body from `gh issue view [N] --repo [OWNER/REPO] --json body --jq .body` under `tmp/` on every body build. Its classification under [SKILL.md § Tracker Resolution](../SKILL.md#tracker-resolution) picks `Refs` or `Closes`. A failed read stops the body build.

4. **Create or update the pull request.**

   - Never defer, queue or gate CI behind bot review activity.
   - `[ISSUE_TITLE]` comes from `.agents/skills/linear/scripts/linear.sh issues get [ISSUE_ID]` or `gh issue view [N] --repo [OWNER/REPO] --json title --jq '.title'`.

   ```bash
   .agents/skills/github/scripts/github.sh -C "[WORKTREE_PATH]" pr-create --title "[PREFIX]([ISSUE_ID]): [ISSUE_TITLE]" --body-file "$BODY_FILE"
   ```

   With `pr_order` reading `push-first`, add `--draft` to that command. The caller's first-head review call ([start-worktree.md](start-worktree.md) § 2.1), run with `[MARK_READY]` `true`, owns the ready transition.

   With an existing pull request, update its body instead:

   ```bash
   .agents/skills/github/scripts/github.sh -C "[WORKTREE_PATH]" pr-edit-body "$PR_NUM" --body-file "$BODY_FILE"
   ```

   **Push-first ready head.** With `pr_order` reading `push-first-returned`:

   - Confirm the internal review's verdict is `pass`.
   - Run [the review call](../references/gates.md#the-review-call) once from `[WORKTREE_PATH]` with `[MARK_READY]` `true`. It marks a draft ready.
   - Route its `request` by [gates.md § Copilot requests](../references/gates.md#copilot-requests).

   Route the reply:

   - A refusal, a closed pull request's `pr-not-open` among them, or an `unreadable` reply stops this pass. The next pass resumes here.
   - On a `pending` reply reading `ready-head-moved`, run the call again on the new head.
   - Otherwise record the order, then write the lane's `Review: pass` line:

   ```bash
   .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-pr-progress","step":"order","order":"push-first-pushed"}'
   ```

   After those writes, run step 1's **Published-head route**.

5. **Arm auto-merge** as soon as the pull request exists, on every pass through this section, for a pull request that will take the queue. The arm reads [merge-pr.md](merge-pr.md) § 5 step 1's merge route. It arms nothing where that route takes the pull request past the queue.

   - **Skip if** `.agents/skills/orch/scripts/orch-env ORCH_MERGE_AUTONOMY auto` prints anything but `auto`.
   - **Skip if** workflow state `pr_order` reads `open-first` or `push-first`: the internal review of the pull request [start-worktree.md](start-worktree.md) § 2.1 opened has not returned. The pass after [review-pr.md](review-pr.md) § 9 arms it.

   Read the bot token as [merge-pr.md § 4](merge-pr.md#4-prepare) does:

   - On `.configured: false`, arm nothing here.
   - [merge-pr.md § 4](merge-pr.md#4-prepare) decides whose name a merge lands under, and that workflow's § 4 and § 5 make the arm.

   ```bash
   .agents/skills/github/scripts/github.sh bot-token
   ```

   Detach orphaned children before any arm:

   - Run [merge-pr.md § 4.1](merge-pr.md#41-detach-orphaned-children) for this item, `[ISSUE]` being `[ISSUE_ID]`, with its skip conditions and its per-orphan ask. A lane sends that ask through its ask gate.
   - **Skip if** workflow state already records `children_detached`: the detach runs once per item.
   - An abort there arms nothing. Skip the rest of this step; [merge-pr.md](merge-pr.md) § 4.1 runs the detach again.
   - Record the detach once it completes, or once § 4.1's own conditions skip it:

   ```bash
   .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-pr-progress","step":"children-detached"}'
   ```

   Read the pushed head as `[HEAD_SHA]`, then arm:

   ```bash
   git -C "[WORKTREE_PATH]" rev-parse HEAD
   ```

   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY .agents/skills/github/scripts/github.sh -C "[WORKTREE_PATH]" pr-merge [PR_NUMBER] --auto --expected-head [HEAD_SHA]
   ```

   Before you route the exit, apply [merge-pr.md § 5 step 1](merge-pr.md#5-execute-the-merge)'s **Record the merge decision** instruction with `[HEAD_SHA]`, this call's exit and its returned route.

   - For that instruction, `[STATE_KEY]` is `[ISSUE_ID]` and `[MAIN_REPO_ROOT]` is this worktree.
   - On exit `1`, that instruction confirms removal of any earlier arm before this routing.

   | Exit and line | Meaning and action |
   |---|---|
   | `75` | Armed. Continue with the CI wait, the gate wait and § 6.1; GitHub holds the merge as `pr-merge --help` § Approvals and review threads states |
   | `0` | Merged. § 6 enters [merge-pr.md](merge-pr.md), whose § 3.2 takes a merged pull request straight to its post-merge steps |
   | `1` | Armed nothing. Continue unarmed; [merge-pr.md](merge-pr.md) § 5 takes the merge after § 6.1 |

   On exit `1`, report an `arm: no-merge-gate=` line once. `unverified` is a failed read of the base branch's rules, and any other gap names the setting that fixes it (`pr-merge --help`).

Once the pull request exists, this run is a continuing action. Before you enter another post-PR gate, clear any stop a capped run left:

```bash
.agents/skills/orch/scripts/orch-runtime state post-pr-stop clear --item [ISSUE_ID]
```

### 2.1 Base publication

Under `ORCH_DELIVERY=push-base`, `orch-runtime pr order` answers `review-first`, so no early pull request exists.

**Open post-merge boxes.** **Skip if** `TRACKER=none` ([SKILL.md § Tracker Resolution](../SKILL.md#tracker-resolution)): a directed change has no item to read.

- Before any other step here, read the root item live.
- For a single bundle, also read each non-canceled child the commit implements.
- Use `.agents/skills/linear/scripts/linear.sh issues get [ID]` for Linear and `gh issue view [N] --repo [OWNER/REPO] --json body` for GitHub.

Save each read body or description under `tmp/` and classify it with `linear.sh done-when parse --description-file [FILE]`, as [SKILL.md § Tracker Resolution](../SKILL.md#tracker-resolution) reads its answer. An item answered with an open post-merge box or any `errors` takes the PR route:

1. Write `[WORKTREE_PATH]/tmp/delivery-post-merge-[ISSUE_ID].md` with one `delivery-post-merge: issue=[ID] route=pr` line per such item, and print it.
2. Send it: `.agents/skills/mailbox/scripts/lane-mail notice --item [ISSUE_ID] --file "[WORKTREE_PATH]/tmp/delivery-post-merge-[ISSUE_ID].md"`.
3. Stop. The stop prepares, pushes and completes nothing. The overseer relaunches the item with `ORCH_DELIVERY=pr`.

A failed read or classification stops publication. An absent linear package is neither: [SKILL.md § Tracker Resolution](../SKILL.md#tracker-resolution) states its outcome.

**Review check.** Apply § 6.1 gate 1 before preparation.

- Bind `[LIFECYCLE]` to `managed` or `self`.
- For a managed caller, bind `[REVIEW_VERDICT]` to the internal review's returned verdict.
- A standalone caller needs a non-empty `json_paths` record; § 1.2's advisory local review does not count.
- A micro item keeps its internal-review exception.

```bash
if ! BASE_REVIEW_STATE="$(.agents/skills/orch/scripts/orch-runtime state get --item [ISSUE_ID])"; then
  exit 1
fi
BASE_REVIEW_STATE="$(jq -c '.result.value | {tier: (.tier // "standard"), json_paths: (.json_paths // [])}' <<<"$BASE_REVIEW_STATE")"
if ! jq -e --arg lifecycle "[LIFECYCLE]" --arg verdict "[REVIEW_VERDICT]" '.tier == "micro" or (if $lifecycle == "managed" then $verdict == "pass" else (.json_paths | length) > 0 end)' <<<"$BASE_REVIEW_STATE" >/dev/null; then
  printf 'delivery-review: issue=%s state=unaccepted\n' '[ISSUE_ID]' >&2
  exit 1
fi
```

A refused review check publishes nothing:

- Run [review-pr.md § 1-9](review-pr.md), then repeat this check with its result.
- Keep the tier's local validation.

**Prepare.**

1. Bind `git -C [WORKTREE_PATH] rev-parse --verify HEAD` as `[BOUND_HEAD]`.
2. Write `[WORKTREE_PATH]/tmp/base-prepare-[ISSUE_ID].json` with the harness file tool as `{"op": "record-push", "mode": "prepare", "worktree": "[WORKTREE_PATH]"}`, then run it:

   ```bash
   .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request [WORKTREE_PATH]/tmp/base-prepare-[ISSUE_ID].json
   ```

   The request runs the worktree skill's preparation, its normal commit hooks and SHA reconciliation. It returns before validation and transport.

3. Bind `[BASE]`, `[PREPARED_BASE]` and `[PREPARED_HEAD]` from the reply's `prepared` receipt: its `base`, `before` and `commit`.
4. Apply [SKILL.md § The Cycle](../SKILL.md#the-cycle)'s rules reload after a rebase at once, against `[BOUND_HEAD]`.
5. If the new rules require edits or review, complete that work and restart this section.
6. Keep the receipt's values across this pause.

**Publish.** Write `[WORKTREE_PATH]/tmp/base-publish-[ISSUE_ID].json` with the harness file tool as `{"op": "record-push", "mode": "publish", "worktree": "[WORKTREE_PATH]", "base": "[PREPARED_BASE]", "head": "[PREPARED_HEAD]"}`, then run it:

```bash
.agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request [WORKTREE_PATH]/tmp/base-publish-[ISSUE_ID].json
```

The request refuses a head that moved from `[PREPARED_HEAD]`, before validation and again after it. It validates the prepared head locally over the range from the prepared base, then publishes through the worktree skill's pinned base transport without rebasing. A micro item takes the tier check first, which refuses any range that is not micro. Where the consumer's committed policy runs the `git-hooks` stage, the armed commit chain stands in for the micro item's range validation. Otherwise the range validation runs too.

- Exit 0: read the reply's `delivery` receipt. Its `commit` is `[PUSHED_SHA]` and its `at` is `[PUSHED_AT]`.
- A refusal exits 1 with its key, and a failed push exits with its status.
- A `worktree-push-base-conflict`, `worktree-push-base-rejected` or `worktree-push-rebase-failed` refusal in the reply's `push` output returns to [merge-pr-restack.md](merge-pr-restack.md). That route returns here after its guarded restack and rules reload.
- A red validation publishes nothing. A failed push sends no completion notice.

**Verification.** Verify the published head where it stands. The verification is pinned to `[PUSHED_SHA]`, never the branch's later head or a pull request. `[OWNER/REPO]` is what `gh repo view --json nameWithOwner --jq .nameWithOwner` answers from `[WORKTREE_PATH]`, whatever the item's tracker.

```bash
jq -cn --arg repo "[OWNER/REPO]" --arg base "[BASE]" --arg head "[PUSHED_SHA]" \
  '{op: "verify-head", repo: $repo, base: $base, head: $head, required_only: true}' \
  > "[WORKTREE_PATH]/tmp/verify-request-[ISSUE_ID].json"
.agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request "[WORKTREE_PATH]/tmp/verify-request-[ISSUE_ID].json"
```

| Reply | Action |
|--------|--------|
| `ok` true, `result.status` `complete` | Bind `[VERDICT]` to `result.verdict` |
| `ok` true, `result.status` `pending` | Not final: repeat the call, as below |
| `ok` true, `result.status` `unreadable` | Run the call once more, as below |
| `ok` false | Report the refusal's key with the pushed SHA in the completion notice. Do not repeat transport |

- On `complete`, the op records a `fail` on a published head as read. Name it in the completion notice. Its fix is a new item.
- On `pending`, the op runs no wait of its own. Repeat the same call every 180 seconds until `CI_WAIT_MAX_SECS` seconds have passed since the first call (`.agents/skills/orch/scripts/orch-env CI_WAIT_MAX_SECS 600`). A `pending` reply at that point is unconfirmed: record nothing, and write `verification: head=[PUSHED_SHA] unconfirmed` in the completion notice.
- On `unreadable`, if it repeats, record nothing and write `verification: head=[PUSHED_SHA] unconfirmed` in the completion notice. Never record a verdict that did not arrive.

The op records a `complete` verdict in the same call ([workflow-state.md](../schemas/workflow-state.md) `verification`). Make no separate `record-verification` call.

**Linear completion**, Linear only. Read the common checkout before you enter the reused step, a standalone caller included:

```bash
.agents/skills/orch/scripts/git-context common-root "[WORKTREE_PATH]"
```

Stop on a nonzero exit. Bind the printed path as `[MAIN_REPO_ROOT]`. Substitute the value into each later command: a shell variable does not survive a separate tool call. Run [merge-pr.md § 5 step 2](merge-pr.md#5-execute-the-merge) alone, with these bindings:

- `[ISSUE]` is this session's root `[ISSUE_ID]`, and `[MERGED_AT]` is the receipt's `[PUSHED_AT]`.
- Its merge summary runs [post-summary.md § 1](post-summary.md#1-post-the-summary) with no `pr_number`. The summary goes to the Linear item alone.
- Skip both of its `gh pr view` reads, the timestamp and the body: this delivery has no pull request.
- Write `[EVIDENCE_FILE]` and select `[MET_BOXES]` as that step states for a direct delivery.
- Use its `issues complete --post-merge-at` command.
- For the in-PR bundle, repeat the completion for each non-canceled child the pushed commit implements.
- Follow that step's container close.

**GitHub completion**, GitHub only. Use this session's resolved tracker and repository. Bind `[ISSUE_NUMBER]` to the root GitHub item's number from Tracker Resolution, then run:

```bash
gh issue close [ISSUE_NUMBER] --repo "[OWNER/REPO]" --reason completed
```

- Repeat that command with each qualified started bundle child's resolved number and repository: the children a PR body's `Closes` lines would include.
- Item commits need no closing trailer.
- A GitHub-tracked direct delivery posts no summary.
- Report a tracker failure with the pushed SHA, and do not repeat transport.

**Completion notice.** Write `[WORKTREE_PATH]/tmp/delivery-[ISSUE_ID].md` with three parts: `Pushed [PUSHED_SHA] to [BASE].`, the verification line `verification: head=[PUSHED_SHA] verdict=[VERDICT]` or its unconfirmed form, and the tracker completion result. Send it through the lane mailbox:

```bash
.agents/skills/mailbox/scripts/lane-mail notice --item [ISSUE_ID] --file "[WORKTREE_PATH]/tmp/delivery-[ISSUE_ID].md"
```

Return the receipt to the caller.

- A managed caller retires its agents through [start-worktree.md § 5.4](start-worktree.md#54-retire-agents), then ends.
- A standalone caller ends here.

---

## 3. Async Comment Triage

Bot prose is never a gate signal: never parse emoji reactions, sticky comments or checklist text for gating. Triage what exists now and move on. Every bot comment still gets a reply and a resolution.

```bash
.agents/skills/github/scripts/github.sh pr-threads [PR_NUMBER] --unresolved
```

- On `.unresolved_count == 0`, go to § 3.2.
- Otherwise run `⤵ workflows/review-pr-comments.md [PR_NUMBER] § 1-8 → § 3 tail` with managed context. That workflow records its own results (its § 8) and counts its own pass (its § 6.3). Write neither here.

Do not wait for a bot's re-review round.

### 3.1 Re-submit set

The re-submit set is the issues this session filed for work the cap did not deny. Some filings stand in for a fix the cap refused: one made at or past `REVIEW_MAX_EXTERNAL_ROUNDS`, or deferred instead of fixed.

- Record such a filing in `pr_comment_review.issues_created` and report it in the PR body. It never enters the set.

Tell work the item's goal needs from separable work of another concern.

- Finish the first here.
- Give the second its own item, with its actual owner, in the same pass.

Implement the re-submit set before merge, in at most two re-submit cycles:

```bash
.agents/skills/orch/scripts/orch-runtime state get --item [ISSUE_ID] /submit_cycles
```

At a `result.value` of 2 or more, go to § 3.2 with the note "max re-submit cycles reached, the re-submit set may need manual implementation". Otherwise:

1. Increment the count: `orch-runtime state increment --item [ISSUE_ID] /submit_cycles`.
2. Implement through `⤵ workflows/dev-start.md § 1-4`, managed, with the same `worktree` and `issue_id`. A `no-change` return adds nothing to the set. Skip the review and go to step 4.
3. Review through `⤵ workflows/review-pr.md § 1-9`, managed, with the same `worktree` and `issue_id`.
4. Re-enter § 2 to push and update the PR body with the new `Closes` lines.

### 3.2 Golden Baselines

**Skip if** the consumer's `[skill-instructions].orch`, injected into the installed `SKILL.md` Project Instructions, selects no baseline policy. Continue to § 4 with no capture, baseline commit or push. An issue label alone grants none of them.

With a selected policy:

1. Apply its capture criterion and visual QA target. If the criterion does not hold, continue to § 4.
2. If no baseline-capable target exists, report why and continue to § 4 without capture.
3. Apply the policy's approval, host and isolation gate before capture. On an unmet gate, continue to § 4 without capture.
4. Only after those conditions pass, capture with the selected target in the worktree. Then stage and inspect:

```bash
git -C [WT_PATH] add [BASELINE_PATH]/
git -C [WT_PATH] diff --cached --name-only
git -C [WT_PATH] diff --cached
```

Check that every staged file is a baseline file.

- Staged product code takes no exception: commit it under the normal commit rules and return to § 2's normal submission path.
- Only a separately selected baseline-only CI exception permits a CI skip, with the subject that exception names.
- With only baseline files staged and no selected exception, use normal CI and the normal commit rules for `[BASELINE_SUBJECT]`.
- With nothing staged, continue to § 4.
- Otherwise commit the baseline change on its own and push it, still under the selected capture policy:

```bash
git -C [WT_PATH] commit -m "[BASELINE_SUBJECT]"
.agents/skills/worktree/scripts/worktree push [WT_PATH] --no-rebase
```

---

## 4. Review Gate

The review gate runs before CI verification, on every repository. Named stops below use [SKILL.md § The Cycle](../SKILL.md#the-cycle).

- Bind `[REVIEW_BASE_CHECKOUT]` by [gates.md § Gate-mode routing](../references/gates.md#gate-mode-routing).
- Run [the review call](../references/gates.md#the-review-call) once from `[WORKTREE_PATH]` with `[MARK_READY]` `false`.
- Its reply's `mode`, `approval` or `off`, is `GATE_MODE`. The runtime records it on the item; never derive it here.
- A refusal, or a second `unreadable` reply with no `mode`, gives no mode: report it and do not guess one.
- On `approval`, route the reply's `request` by [gates.md § Copilot requests](../references/gates.md#copilot-requests) before the verdict.

The gate reads only GitHub-native review state, from any reviewer, human or bot.

- A `blocked` verdict takes the step 1 table's `blocked` row under either mode.
- Under the `off` gate mode, a `complete` verdict `off` or a `pending copilot-pending` reply skips the wait and goes to § 5. The internal review, CI, comment-hygiene and gate 3 checks apply in full.

**Who acts.** The lane waits and triages under its own credential. It never approves its own pull request. The overseer approves a head only as [copilot-head-notices.md](../references/copilot-head-notices.md) sets.

1. **Wait.** Wait for the verdict and new comments together through [the review wait](../references/gates.md#the-review-call): the same call, run from `[WORKTREE_PATH]`, repeated while it answers `pending`.

   A step the runtime recorded as accepted under an `authorization` presents no ask here, in § 5 or in § 6.1.

   - Each `ask` row takes its `auto-recommended` action, and the repository's required checks and reviews stay untouched.
   - Read the acceptance in the dev entry's `authorization` in `stages` (`orch-runtime state inspect --item [ISSUE_ID]`): the overseer's acceptance, or the owner's directive.

   | Reply | Action |
   |-------|--------|
   | `approved` | Clear the review-wait budget, then go to step 2 |
   | `proceeded` | The reviewer-down answer under `PR_REVIEW_ON_TIMEOUT=proceed`: clear the review-wait budget, record `reviewer-down` (below), then go to step 2 |
   | `changes_requested` or `comments` | Run the triage pass, then the Restart check |
   | `blocked` | Record `review-regression-open` and stop, as below |
   | `copilot-error` | Route as [gates.md § Copilot requests](../references/gates.md#copilot-requests) says, then enter the Restart check |
   | `timeout` | `auto-recommended` logs `Keep waiting` and enters the Restart check. `ask` asks, as below |
   | `unreadable` | Run the call once more, as below |
   | refusal `pr-not-open` | The pull request is closed or merged: report its `state` and stop |

   - `proceeded`: CI and gate 3 still apply in full. Orch posts no status and makes no review evidence.
   - `blocked`: a regression-against-main blocker stands open on the item, its location in `reason` ([gates.md § Which waiter answers which state](../references/gates.md#which-waiter-answers-which-state)). No restart meets the gate while it stands.
     1. Record `review-regression-open` through `post-pr-stop`, naming that location, as the Restart check's `at-cap` row records its stop.
     2. Post the rendered comment.
     3. Return `MERGE_READY = false` and skip § 5.
   - `copilot-error`: the approval gate stays unmet until an approval arrives.
   - `timeout` under `ask`: present `Force merge` \| `Keep waiting` \| `Stop here`, with `Keep waiting` recommended, and route the answer by **On `timeout` under `ask`** below.
   - `unreadable`: if it repeats, `auto-recommended` records `review-gate-read-failed`; `ask` presents `Keep waiting` \| `Stop here`, with `Keep waiting` recommended.

   Record the reviewer-down answer:

   ```bash
   .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-pr-progress","step":"reviewer-down"}'
   ```

   A met gate clears its head-bound budget:

   ```bash
   .agents/skills/orch/scripts/orch-runtime state head-budget reset --item [ISSUE_ID] --kind review-wait
   ```

   **Triage pass**: `⤵ workflows/review-pr-comments.md [PR_NUMBER] § 1-8 → § 4 step 1` with managed context. It applies the external cap to its own fix pushes. The Restart check bounds this step.

   **Restart check.** Every automatic path that would restart the wait passes the item's review-wait budget first. Read the pull request's head immediately before each take, so that a triage push restarts the count:

   ```bash
   .agents/skills/orch/scripts/orch-runtime pr view "[WORKTREE_PATH]" [PR_NUMBER] --json headRefOid
   ```

   Bind its `.headRefOid` as `[REVIEW_HEAD]`:

   ```bash
   .agents/skills/orch/scripts/orch-runtime state head-budget take --item [ISSUE_ID] --kind review-wait --head [REVIEW_HEAD]
   ```

   - On the reply's `verdict` `continue`, restart step 1.
   - On `at-cap`, record `review-round-cap`, post the rendered comment, return `MERGE_READY = false` and skip § 5:

   ```bash
   .agents/skills/orch/scripts/orch-runtime state post-pr-stop record --item [ISSUE_ID] --name review-round-cap --gate review --remaining "[REMAINING_FEEDBACK]" --comment-file [WORKTREE_PATH]/tmp/post-pr-stop-[ISSUE_ID].md
   ```

   ```bash
   .agents/skills/github/scripts/github.sh post-comment [PR_NUMBER] --body-file [WORKTREE_PATH]/tmp/post-pr-stop-[ISSUE_ID].md
   ```

   The cap is the overseer's ruling point.

   - No wait restarts past it until the overseer has appended one `ruling` row for the item through `orch-runtime state log append --fleet [RULING_FILE]` ([oversee-events.md § Judgement rules](../references/oversee-events.md#judgement-rules)).
   - The overseer judges with the reply's `attempts` and `limit`. When the ruling authorizes another wait, the overseer runs `orch-runtime state head-budget reset --item [ISSUE_ID] --kind review-wait` before the next take.
   - Before an automatic budget transition, `ask` presents `Triage again` \| `Stop here`, with `Triage again` recommended. Under `ask`, `Triage again` is the user's override for one more pass.
   - `Stop here` goes to § 6 with `MERGE_READY = false` and skips § 5.

   A standing `changes_requested` verdict on the current head outlives a disposition. Only a dismissal or a newer review clears it.

   **On `timeout` under `ask`**:

   - `Keep waiting` goes to the Restart check.
   - `Stop here` goes to § 6 with `MERGE_READY = false` and skips § 5.
   - `Force merge` records the forced approval and continues to step 2, which records the status that led to it. The § 6.1 gates still apply:

   ```bash
   .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-pr-progress","step":"forced"}'
   ```

2. **Record the result** for gate 4: the gate status and the `unresolved_count` at verdict time. Then go to § 5.

After any fix-up push, in order:

1. Push, and take the Restart check.
2. On a restart, wait for a new review of the new head.
3. Triage, reply to and resolve every thread.
4. Run § 5 Verify CI, then the § 6 merge gates.

---

## 5. Verify CI

Read the pull request's merge state before the first call:

```bash
env -u GH_REPO -u GITHUB_REPOSITORY .agents/skills/github/scripts/github.sh pr-merge [PR_NUMBER] --check
```

Its JSON's `mergeable` routes first:

- `CONFLICTING` takes the `conflict` row of the table below.
- `MERGEABLE`, and `UNKNOWN` while GitHub still computes mergeability, go on to the first call.

The runtime's `verify-pr` operation gives the pull request's CI verdict. One call reads the pull request's current head, base and state. It judges that head as § 2.1's `verify-head` judges a pinned head, and records the verdict itself with `source: verify-pr`.

- Run it through [Waiter launch](../references/waiter-launch.md), within the lane's CI budget `CI_WAIT_MAX_SECS`.
- Repeat it while `result.status` is `pending` or `unreadable`, no more often than every 180 seconds.
- `[OWNER/REPO]` is what `gh repo view --json nameWithOwner --jq .nameWithOwner` answers from `[WORKTREE_PATH]`:

```bash
jq -cn --arg repo "[OWNER/REPO]" --argjson pr [PR_NUMBER] \
  '{op: "verify-pr", repo: $repo, pr: $pr, required_only: true}' \
  > "[WORKTREE_PATH]/tmp/verify-pr-request-[ISSUE_ID].json"
.agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request "[WORKTREE_PATH]/tmp/verify-pr-request-[ISSUE_ID].json"
```

| Result | Action |
|--------|--------|
| `conflict` | `mergeable` read `CONFLICTING` before the first call. The base, not CI, is the blocker: restack, as below |
| `status=complete`, `verdict=pass` | Go to § 6 |
| `status=complete`, `verdict=none` | Run the coverage check below. Only its exit 0 lets you record `ci: none` in workflow state and go to § 6 |
| `status=complete`, `verdict=fail` | Go to § 5.1 |
| `status=pending` or `status=unreadable` at the budget | Run the call once more, as below |
| refusal `pr-not-open` | The pull request is closed or merged: report its `state` and stop |

- `conflict`:
  1. Run [merge-pr-restack.md](merge-pr-restack.md) steps 1-3; a red run there hands back.
  2. That push is a fix-up push: take the § 4 Restart check, then re-enter § 5 at its merge-state read.
  3. Never route a conflict into § 5.1 or the budget row.
- `pending` or `unreadable` at the budget: if it repeats, `auto-recommended` records `ci-status-unconfirmed`; `ask` presents `Skip CI` \| `Retry` \| `Abort`, with `Retry` recommended.

A step accepted under an `authorization` (§ 4 step 1) takes the budget row's `auto-recommended` action under either mode.

**Coverage check.** For `verdict=none`, use the `SUBMIT_VALIDATE_MODE` § 1.1 retained. A pending `ci` result requires CI proof, including a run submit started without a dev receipt. With no required CI, stop before § 6:

```bash
if [[ "$SUBMIT_VALIDATE_MODE" == ci ]]; then
  printf 'submit-pr: ci-uncovered cause=no-required-ci\n' >&2
  exit 1
fi
```

### 5.1 CI Failure Recovery

```bash
.agents/skills/orch/scripts/orch-runtime state cap CI_FIX_MAX_CYCLES
```

Its reply's `limit` is `MAX_CYCLES`.

**One rerun per head.** Rerun a transient runner failure, such as a lost runner or a dependency install that timed out, once per head before any fix round. Read the recorded rerun:

```bash
.agents/skills/orch/scripts/orch-runtime state get --item [ISSUE_ID] /ci_rerun/head
```

- When its `result.value` is the verdict's `result.head`, this head had its rerun: go to Run Workflow.
- Otherwise record the rerun for this head, then ask for it. Write the record before the ask, never after.
- `[HEAD]` is the verdict's `result.head`. `ci-rerun --help` says which failed run it reruns:

```bash
.agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-pr-progress","step":"ci-rerun","head":"[HEAD]"}'
env -u GH_REPO -u GITHUB_REPOSITORY .agents/skills/github/scripts/github.sh ci-rerun [PR_NUMBER] --required-only
```

On a `rerun run=[RUN_ID]` line:

- Return to the § 5 call after the interval § 5 keeps between calls, never at once. The § 5 call then reads the rerun attempt as the current run.
- Before you return, record the run on the item:

```bash
.agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-pr-progress","step":"ci-rerun-run","head":"[HEAD]","run":[RUN_ID]}'
```

A `no-rerun` line, or exit `1`, goes to Run Workflow.

**Run Workflow**: `⤵ workflows/ci-fix.md [PR_NUMBER] § 1-6 → § 5.1 tail` with context `worktree`, `lifecycle: "managed"` and `issue_id`. Ci-fix pushes, re-confirms the § 4 gate at the new head, and only then re-verifies CI. It reads the gate at the new head through the review call, whose `mode` is the item's recorded one.

- Record that mode as `GATE_MODE`, and its gate re-confirmation as the § 4 result. An unblocked `off` has no re-confirmation to record.
- A returned `comments`, `changes_requested`, `copilot-error` or `blocked` routes through the § 4 step 1 table first. It re-enters § 5 once the approval gate is met.
- Route a returned final CI result through the § 5 table.

Keep routing failures back into ci-fix until CI passes or `MAX_CYCLES` is spent. At the cap:

- Go to § 6 with a failure report, never a bare "CI is failing". The report names the checks still failing, quotes ci-fix's last error summary and lists what each cycle attempted.
- No ci-fix cycle starts past the cap until the overseer has appended one `ruling` row for the item through `orch-runtime state log append --fleet [RULING_FILE]` ([oversee-events.md § Judgement rules](../references/oversee-events.md#judgement-rules)).
- The overseer judges with ci-fix's counted cycles and the reply's `limit`. When the ruling authorizes another cycle, the overseer runs `orch-runtime state head-budget reset --item [ISSUE_ID] --kind ci-fix` before the next take.

---

## 6. Merge Gates And Summary

### 6.1 Merge Gates

A pull request merges on exactly four deterministic gates. Gates 2 and 4 check results § 5 and § 4 already recorded; do not run the waits again. Gate 3 is a final live check.

| # | Gate | Check |
|---|------|-------|
| 1 | Internal review verdict recorded | Managed: `review-pr.md` completed with verdict `pass`. Standalone: `json_paths` is non-empty |
| 2 | CI green | The § 5 result is `status=complete` with `verdict=pass`, or `verdict=none` after its coverage check passes (met with a `CI: none configured` note in the summary) |
| 3 | Zero unresolved review comments | `pr-threads` reports `unresolved_count == 0`, every actionable PR-level bot comment has a reply (tracked in `pr_comment_review.replied`), and `check-review-replies` exits 0 |
| 4 | Reviewer-gate verdict | `approval`: § 4 ended `approved`, or a recorded `pr_approval.forced` or `pr_approval.reviewer_down` meets it. `off`: not applicable |

**Gate 4 reads the recorded mode**, the one the runtime records per base ([gates.md § Gate-mode routing](../references/gates.md#gate-mode-routing)). Read it for gate 4 and the § 7 report:

```bash
.agents/skills/orch/scripts/orch-runtime state get --item [ISSUE_ID] /pr_review/mode
```

**Gate 1**, standalone only:

```bash
STATE_READ="$(.agents/skills/orch/scripts/orch-runtime state get --item [ISSUE_ID])" && jq -c '.result.value | {json_paths: (.json_paths // []), cycles: (.cycles // 0)}' <<<"$STATE_READ"
```

Empty `json_paths` means no internal review is recorded. Report the unmet gate and recommend `orch review-pr [PR_NUMBER]`.

**Gate 2** is the recorded § 5 result.

- Raw `gh pr checks` output is never the gate.
- On a `pr-merge --check` refusal, run `.agents/skills/github/scripts/github.sh ci-classify-refusal [PR_NUMBER]`. Report its `cause:` line with its detail; `ci-classify-refusal --help` gives the output contract.

**Gate 3**, the final live check. Replying to every bot comment stays § 3's hygiene rule, not a gate in any mode.

```bash
.agents/skills/github/scripts/github.sh pr-threads [PR_NUMBER] --unresolved
```

On `unresolved_count > 0`:

1. Run one triage pass: `⤵ workflows/review-pr-comments.md [PR_NUMBER] § 1-8 → § 6.1 gate 3`, managed. The same `REVIEW_MAX_EXTERNAL_ROUNDS` cap on `pr_comment_review.iterations` bounds it.
2. If that pass pushed commits, re-confirm the § 4 gate through its Restart check with a short [review wait](../references/gates.md#the-review-call) at the new head, then run § 5 again.
   - Skip the wait when `GATE_MODE` is `off`.
   - Write the call's request file as § 4 does, with `[MARK_READY]` `false`.
   - Run it with the shorter period, and route each reply by § 4 step 1's table:

```bash
env PR_REVIEW_WAIT_SECS=300 .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request "[WORKTREE_PATH]/tmp/verify-review-request-[ISSUE_ID].json"
```

Run the gate 3 command once more. If threads remain, read the external-round cap with `orch-runtime state cap REVIEW_MAX_EXTERNAL_ROUNDS --item [ISSUE_ID]`:

- Below the cap, `auto-recommended` logs `Triage again` and runs one more pass.
- At the cap, it records `review-threads-open`.
- No triage pass runs past the cap until the overseer has appended one `ruling` row for the item through `orch-runtime state log append --fleet [RULING_FILE]` ([oversee-events.md § Judgement rules](../references/oversee-events.md#judgement-rules)). The overseer judges with the cap reply's `count` and `limit`.
- Under `ask`, present `Triage again` \| `Stop here`, with `Triage again` recommended.
- A step accepted under an `authorization` (§ 4 step 1) takes the `auto-recommended` action under either mode.

Then read what the replies say, live:

```bash
env -u GH_REPO -u GITHUB_REPOSITORY .agents/skills/github/scripts/github.sh -C "[WORKTREE_PATH]" check-review-replies [PR_NUMBER]
```

- Exit `1` prints one line per failing rule. Rewrite each reply it counts as one of the three dispositions in [finding-disposition.md § Decision flow](../../reviewer/references/finding-disposition.md#decision-flow).
- Send every `suppressed-entry` through the body-finding route of [review-pr-comments.md § 7.2](review-pr-comments.md#72-copilot-head-route) with managed context.
  - Complete its triage pass and its §§ 7.2-8, then return here with the current head and whether the pass pushed.
  - If it pushed commits, re-confirm the gates as the thread pass above does.
- A reply or comment counts only from the pull request's author, the identity the check runs as, or an `OWNER`, `MEMBER` or `COLLABORATOR` of the repository. Post it under one of those identities. `check-review-replies --help` names which replies do not count; the command reports them on stderr.
- Run the command once more. A second exit `1` records `review-replies-unmet`.
- Exit `2` reached no verdict. Report its first stderr line; the gate is unmet.

**Gate 4**: check the recorded § 4 result under the mode read above.

`MERGE_READY = true` only when all four gates are met.

**No stop leaves an armed pull request.** Once `MERGE_READY` is false, by these gates or by a stop that sent the run here, take [merge-pr-restack.md § Unarm at a stop](merge-pr-restack.md#unarm-at-a-stop). Take it before § 6.2 or § 7 reports the stop, with `[STATE_KEY]` being `[ISSUE_ID]` and `[STOP_DIR]` being `[WORKTREE_PATH]/tmp`.

### 6.2 Standalone Summary

**Skip if** managed: go to § 7.

On `MERGE_READY = false`, record the unmet gate here, so § 7 returns a named stop instead of reading as complete. `record-if-empty` keeps a more precise stop recorded upstream. Only its `recorded` answer writes the file the post below sends:

```bash
.agents/skills/orch/scripts/orch-runtime state post-pr-stop record-if-empty --item [ISSUE_ID] --name merge-gates-unmet --gate merge --remaining "[UNMET_GATE_AND_REMAINING_WORK]" --comment-file [WORKTREE_PATH]/tmp/post-pr-stop-[ISSUE_ID].md
.agents/skills/github/scripts/github.sh post-comment [PR_NUMBER] --body-file [WORKTREE_PATH]/tmp/post-pr-stop-[ISSUE_ID].md
```

Post a summary comment when the run made fixes or created issues:

1. Take fix SHAs from workflow state. Resolve SHAs taken from artifacts through `.rebase_map` first.
2. Write the summary to a file in the session-summary form of [post-summary.md § 1](post-summary.md#1-post-the-summary), its opening stating the current merge state. Bind it as `SUMMARY_FILE`.
3. Post it:

```bash
.agents/skills/github/scripts/github.sh post-comment [PR_NUMBER] --body-file "$SUMMARY_FILE"
```

A Linear item also gets it on the issue. The PR body's `Closes` or `Refs` line names a GitHub item:

```bash
.agents/skills/linear/scripts/linear.sh comments create [ISSUE_ID] --body-file "$SUMMARY_FILE"
```

Output: [skill-rules.md § Lane Output](../references/skill-rules.md#lane-output).

<output_format>

### ✅ PR SUBMITTED — #[PR_NUMBER]

| Metric | Value |
|--------|-------|
| PR | #[PR_NUMBER] |
| CI | ✅ passing / ❌ failing |
| Review gate | ✅ approved / ⏳ pending / forced / off ([Gate-mode routing](../references/gates.md#gate-mode-routing)) |
| Unresolved threads | [N] |
| Comment iterations | [N] |
| Fixes applied | [N] |
| Issues created | [N] |

</output_format>

**Merge.** **Skip if** `MERGE_READY` is false. On such a run, § 6.1 unarmed any pull request § 2 step 5 armed.

```bash
.agents/skills/orch/scripts/orch-env ORCH_MERGE_AUTONOMY auto
```

- On `auto`, merge without asking: `⤵ workflows/merge-pr.md [PR_NUMBER] § 1-7 → end`.
- On anything else, ask `orch merge-pr [PR_NUMBER]` \| `Skip`. Record the question before you ask it:

```bash
.agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-pr-progress","step":"merge-asked"}'
```

When the answer arrives, record it, then on `orch merge-pr` run the same workflow:

```bash
.agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-pr-progress","step":"merge-answered"}'
```

On a pull request § 2 step 5 armed, [merge-pr.md](merge-pr.md) keeps only the queue wait, the late-thread answers and the post-merge steps. Its § 5 arm re-arms the prepared head and answers exit `75`.

---

## 7. Return

**Managed**: return to the parent workflow's next section with the § 6.1 gate results: `MERGE_READY`, the § 4 gate mode and status, the unresolved thread count and the § 5 CI verdict. **Standalone**: return `.post_pr_stop` where one stands; otherwise the session is complete.
