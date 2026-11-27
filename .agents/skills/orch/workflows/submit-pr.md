# Submit PR Workflow

Publish one item's branch as a pull request: validate and review it locally, push, open or update the pull request, triage review comments, wait for the review gate, verify CI and confirm the merge gates. [publication.md](../references/publication.md) holds the pull request body, the arm, the CI rerun and the merge-gate contracts that these steps apply.

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
- Where no worktree exists and you are inside the pull request's checkout, `auto-recommended` creates one and logs the choice. `ask` asks first.

With no argument, `[DIR]` is `.`. `WT_PATH` is what `.agents/skills/orch/scripts/git-context repo-root "[DIR]"` prints.

**Standalone init** (`lifecycle: "self"`):

1. Bind `ISSUE_ID` from `git-context issue-from-branch .`.
2. Run `.agents/skills/orch/scripts/orch-runtime state exists --item [ISSUE_ID]`.
3. Where it reports no record, read the branch with `git-context branch [WT_PATH]`. Then create the record with `orch-runtime state init --item [ISSUE_ID] --worktree [WT_PATH] --branch [BRANCH]`.

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

Stop before pushing when any of these holds:

- the branch is empty (detached HEAD);
- the branch is the base branch;
- the working tree is dirty;
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
  - Where the change is queue-only, that run proves no head. The merge-group run the receipt's record names by `ci-event=merge_group` proves it ([merge-pr.md § 5](merge-pr.md#5-execute-the-merge)).
- A failing dev validation artifact blocks submission. Report it and start no validation run.
- Never re-run a dev `no-verdict` result for the current commit.
  - With `validate_mode` `ci`, it goes on with required CI pending after publication, as a `ci` receipt does.
  - With `validate_mode` `full` or `range`, no required CI holds its proof. It is unproved, blocks the push and starts no run.
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

**Skip if** `lifecycle` is `"managed"`, or a PR number argument was given: § 3 triages the comments that arrived. Otherwise ask the committed policy whether the local review runs:

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
| `reason == "valid_undermeasured"` | Report the measurement failure with the findings, as below |
| `ok == false`, or a nonzero exit | Report `reason` and its `detail`, and go to § 2 |

On `valid_undermeasured`, report its `measurement_failed` string, and `measurement_suppressed` where present, with the findings. Never treat the pass as clean.

The local review is advisory. It never blocks submission, and none of those outcomes is a pass.

1. Route the findings per the `review-finding` schema.
2. Disposition every finding per [finding-disposition.md § Decision flow](../../reviewer/references/finding-disposition.md#decision-flow), Step 0 first. Only what survives enters the fix set.
3. Complete the shared contract for this batch before you take any route below.

- With no blockers and no `category: "fix"` or `category: "issue"` suggestions, go to § 2.
- Send blockers and fix-category suggestions to `⤵ workflows/dev-fix.md § 1-3 → § 1.2 tail`, with context `worktree`, `lifecycle: "managed"`, `issue_id`, `items` (the blockers and fix-category suggestions) and `source: local-review`.
- File the `category: "issue"` suggestions, and the fix round's escalated items that clear the filing bar of [finding-disposition.md](../../reviewer/references/finding-disposition.md):
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

**Quick-change triage.** Carry the calling micro run's quick-change context through submit and its nested routes. Keep the live review and required-check reads. If a step would start PR-comment triage for a quick change, take [micro.md § Escape](micro.md#escape) before entering triage.

Read the delivery setting in `[WORKTREE_PATH]` before any pull-request read or push:

```bash
.agents/skills/orch/scripts/orch-env ORCH_DELIVERY pr
```

- `pr`, or no value, takes the steps below.
- `push-base` takes [base-publication.md](base-publication.md) instead and runs no pull-request section, also where a tier enters only steps 1-4.
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

- While workflow state `pr_order` reads `open-first` or `push-first`, an armed pull request was armed before its internal review returned. Unarm it first by [merge-pr-restack.md](merge-pr-restack.md) step 1. Its hand-back pushes nothing and returns to the caller.
- After § 6.1 confirms every merge gate, an armed standalone submit enters [merge-pr.md](merge-pr.md) from its entry point.
- An armed managed submit returns that recorded decision with its final result, and the caller's merge stage owns the lifecycle.

1. **Push.** With workflow state `pr_order` reading `open-first-returned` or `push-first-returned`, the first pass after the internal review of the pull request [start-worktree.md](start-worktree.md) § 2.1 opened runs § 3's triage first.

   - Apply this section's quick-change triage rule before running `⤵ workflows/review-pr-comments.md [PR_NUMBER] § 1-8 → § 2 step 1 push` with managed context. `[PR_NUMBER]` is the `number` the `pr view` read above printed.
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

   **Published-head route.** Run [copilot-head-route.md § Copilot head route](../references/copilot-head-route.md#copilot-head-route) from its current-head Copilot wait.

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

3. **Build the PR body** by [publication.md § PR body](../references/publication.md#pr-body). Bind the file's path as `BODY_FILE`.

4. **Create or update the pull request.**

   - Never defer, queue or gate CI behind bot review activity.
   - `[ISSUE_TITLE]` comes from `.agents/skills/linear/scripts/linear.sh issues get [ISSUE_ID]` or `gh issue view [N] --repo [OWNER/REPO] --json title --jq '.title'`.
   - The title names no tracker id but `[ISSUE_ID]`: Linear's GitHub automation moves every item a merged pull request's title names. Where `[ISSUE_TITLE]` names another item, drop that id from the title and name the item in the body as `Related to [ID]`.

   ```bash
   .agents/skills/github/scripts/github.sh -C "[WORKTREE_PATH]" pr-create --title "[PREFIX]([ISSUE_ID]): [ISSUE_TITLE]" --body-file "$BODY_FILE"
   ```

   With `pr_order` reading `push-first`, add `--draft` to that command. The caller's first-head review call ([start-worktree.md](start-worktree.md) § 2.1), run with `[MARK_READY]` `true`, owns the ready transition.

   With an existing pull request, update its body instead:

   ```bash
   .agents/skills/github/scripts/github.sh -C "[WORKTREE_PATH]" pr-edit-body "$PR_NUM" --body-file "$BODY_FILE"
   ```

   **Push-first ready head.** With `pr_order` reading `push-first-returned`:

   1. Confirm the internal review's verdict is `pass`.
   2. Run [the review call](../references/gates.md#the-review-call) once from `[WORKTREE_PATH]` with `[MARK_READY]` `true`. It marks a draft ready.
   3. Route its `request` by [gates.md § Copilot requests](../references/gates.md#copilot-requests).

   Route the reply:

   - A refusal, a closed pull request's `pr-not-open` among them, or an `unreadable` reply stops this pass. The next pass resumes here.
   - On a `pending` reply reading `ready-head-moved`, run the call again on the new head.
   - Otherwise record the order, then write the lane's `Review: pass` line:

   ```bash
   .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-pr-progress","step":"order","order":"push-first-pushed"}'
   ```

   After those writes, run step 1's **Published-head route**.

5. **Arm auto-merge** on every pass through this section. [publication.md § Arm auto-merge](../references/publication.md#arm-auto-merge) states when the arm runs, its skips and what each exit means.

   **Skip if** a skip condition of that section holds.

   1. Read the bot token as [merge-pr.md § 4](merge-pr.md#4-prepare) does. On `.configured: false`, arm nothing here: merge-pr.md § 4 decides whose name a merge lands under, and that workflow's § 4 and § 5 make the arm.

      ```bash
      .agents/skills/github/scripts/github.sh bot-token
      ```

   2. Detach orphaned children before any arm.
      - **Skip if** workflow state already records `children_detached`: the detach runs once per item.
      - Run [merge-pr.md § 4.1](merge-pr.md#41-detach-orphaned-children) for this item, `[ISSUE]` being `[ISSUE_ID]`, with its skip conditions and its per-orphan ask. A lane sends that ask through its ask gate.
      - An abort there arms nothing. Skip the rest of this step; [merge-pr.md](merge-pr.md) § 4.1 runs the detach again.
      - Record the detach once it completes, or once the conditions of § 4.1 skip it:

      ```bash
      .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-pr-progress","step":"children-detached"}'
      ```

   3. Read the pushed head as `[HEAD_SHA]`:

      ```bash
      git -C "[WORKTREE_PATH]" rev-parse HEAD
      ```

   4. Arm:

      ```bash
      env -u GH_REPO -u GITHUB_REPOSITORY .agents/skills/github/scripts/github.sh -C "[WORKTREE_PATH]" pr-merge [PR_NUMBER] --auto --expected-head [HEAD_SHA]
      ```

   5. Before you route the exit, record the merge decision as publication.md § Arm auto-merge states, with `[HEAD_SHA]`, this call's exit and its returned route.
   6. Route the exit:

      | Exit | Action |
      |---|---|
      | `75` | Continue with the CI wait, the gate wait and § 6.1 |
      | `0` | Continue |
      | `1` | Continue unarmed |

      On exit `1`, report the `arm: no-merge-gate=` line once.

Once the pull request exists, this run is a continuing action. Before you enter another post-PR gate, clear any stop a capped run left:

```bash
.agents/skills/orch/scripts/orch-runtime state post-pr-stop clear --item [ISSUE_ID]
```

---

## 3. Async Comment Triage

Bot prose is never a gate signal: never parse emoji reactions, sticky comments or checklist text for gating. Triage what exists now and move on. Every bot comment still gets a reply and a resolution.

```bash
.agents/skills/github/scripts/github.sh pr-threads [PR_NUMBER] --unresolved
```

- On `.unresolved_count == 0`, go to § 3.2.
- Otherwise apply [§ 2's quick-change triage rule](#2-push-and-submit) before running `⤵ workflows/review-pr-comments.md [PR_NUMBER] § 1-8 → § 3 tail` with managed context. That workflow records its own results (its § 8) and counts its own pass (its § 6.3). Write neither here.

Do not wait for a bot's re-review round.

### 3.1 Re-submit set

The re-submit set is the issues this session filed for work the cap did not deny.

- Some filings stand in for a fix the cap refused: one made at or past `REVIEW_MAX_EXTERNAL_ROUNDS`, or deferred instead of fixed.
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
2. Implement through `⤵ workflows/dev-start.md § 1-4`, managed, with the same `worktree` and `issue_id`. A `no-change` return adds nothing to the set: skip the review and go to step 4.
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
- Its reply's `mode`, `approval` or `off`, is `GATE_MODE`. The runtime records it on the item: never derive it here.
- A refusal, or a second `unreadable` reply with no `mode`, gives no mode. Report it and do not guess one.
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
   | `proceeded` | Clear the review-wait budget, record `reviewer-down` (below), then go to step 2 |
   | `changes_requested` or `comments` | Run the triage pass, then the Restart check |
   | `blocked` | Record `review-regression-open` and stop, as below |
   | `copilot-error` | Route as [gates.md § Copilot requests](../references/gates.md#copilot-requests) says, then enter the Restart check |
   | `timeout` | Route by the decision mode, as below |
   | `unreadable` | Run the call once more, as below |
   | refusal `pr-not-open` | Report the pull request's `state` and stop |

   - `proceeded` is the reviewer-down answer under `PR_REVIEW_ON_TIMEOUT=proceed`. CI and gate 3 still apply in full. Orch posts no status and makes no review evidence.
   - `blocked`: a regression-against-main blocker stands open on the item, its location in `reason` ([gates.md § Which waiter answers which state](../references/gates.md#which-waiter-answers-which-state)). No restart meets the gate while it stands.
     1. Record `review-regression-open` through `post-pr-stop`, naming that location, as the Restart check's `at-cap` row records its stop.
     2. Post the rendered comment.
     3. Return `MERGE_READY = false` and skip § 5.
   - `copilot-error`: the approval gate stays unmet until an approval arrives.
   - `timeout` under `auto-recommended`: log `Keep waiting` and enter the Restart check.
   - `timeout` under `ask`: present `Force merge` \| `Keep waiting` \| `Stop here`, with `Keep waiting` recommended. Route the answer by **On `timeout` under `ask`** below.
   - `unreadable`: if it repeats, `auto-recommended` records `review-gate-read-failed`. `ask` presents `Keep waiting` \| `Stop here`, with `Keep waiting` recommended.
   - `pr-not-open`: the pull request is closed or merged.

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

The runtime's `verify-pr` operation gives the pull request's CI verdict. One call reads the pull request's current head, base and state. It reads that head as the `verify-head` of [base-publication.md § 5](base-publication.md#5-verify-the-published-head) reads a pinned head, and records the verdict itself with `source: verify-pr`. Its judgement adds one rule: under a required set, a workflow job's check counts only from a run GitHub evaluates for a pull request or a run a required workflow rule binds.

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
| `conflict` | Restack, as below |
| `status=complete`, `verdict=pass` | Go to § 6 |
| `status=complete`, `verdict=none` | Run the coverage check below |
| `status=complete`, `verdict=fail` | Go to § 5.1 |
| `status=pending` or `status=unreadable` at the budget | Run the call once more, as below |
| refusal `pr-not-open` | Report the pull request's `state` and stop |

- `conflict`: `mergeable` read `CONFLICTING` before the first call, so the base, not CI, is the blocker.
  1. Run [merge-pr-restack.md](merge-pr-restack.md) steps 1-3. A red run there hands back.
  2. That push is a fix-up push: take the § 4 Restart check, then re-enter § 5 at its merge-state read.
  3. Never route a conflict into § 5.1 or the budget row.
- `verdict=none`: only the coverage check's exit 0 lets you record `ci: none` in workflow state and go to § 6.
- `pending` or `unreadable` at the budget: if it repeats, `auto-recommended` records `ci-status-unconfirmed`. `ask` presents `Skip CI` \| `Retry` \| `Abort`, with `Retry` recommended.
- `pr-not-open`: the pull request is closed or merged.

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

Take [publication.md § One rerun per head](../references/publication.md#one-rerun-per-head) first. Its `verify-pr` call is the § 5 call, and its next route is Run Workflow below.

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

Judge the four gates of [publication.md § Merge gates](../references/publication.md#merge-gates), and set `MERGE_READY` as that section states. Read the recorded gate mode there once, for gate 4 and the § 7 report.

**Gate 1**: a managed run reads the verdict of the review its caller ran. A standalone run reads `json_paths` with that section's command.

**Gate 2** is the recorded § 5 result.

**Gate 3**, the final live check:

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

- On exit `1`, rewrite the replies by gate 3 of [publication.md § Merge gates](../references/publication.md#merge-gates).
- Send every `suppressed-entry` through the body-finding route of [copilot-head-route.md § Body findings](../references/copilot-head-route.md#body-findings) with managed context.
  - Complete its triage pass and [review-pr-comments.md](review-pr-comments.md) §§ 7.2-8, then return here with the current head and whether the pass pushed.
  - If it pushed commits, re-confirm the gates as the thread pass above does.
- Run the command once more. A second exit `1` records `review-replies-unmet`.
- On exit `2`, report its first stderr line. The gate is unmet.

**Gate 4**: check the recorded § 4 result under the mode read above.

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
