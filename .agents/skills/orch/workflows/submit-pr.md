# Submit PR Workflow

Run a local pre-PR review, push, create or update the PR, triage review comments, wait for the reviewer-gate verdict, verify CI, and confirm the merge gates. The review gate (§ 4) runs before CI verification (§ 5).

Run every long waiter below through [Waiter launch](../references/waiter-launch.md). `approval-wait --resolve-mode` runs directly, not through that launch. Exit `5` with the log line `<waiter>: mail=<count>` or `<waiter>: mail-unreadable=<path>` is no verdict: run `.agents/skills/orch/scripts/lane-mail inbox --item [ISSUE_ID]`, act on what it prints, then launch the same waiter again in a fresh run directory; route every other exit as written below.

| Command | Behavior |
|---------|----------|
| `submit-pr` | Submit the current branch as a PR |
| `submit-pr [PR#]` | Manage an existing PR |
| (from start-worktree) | Managed lifecycle with caller context |

**Caller context** (via `⤵`): `worktree`; `lifecycle` — `"managed"` (return at § 7) or `"self"` (default); `issue_id` — the workflow-state key, the normalized issue ID, never the bare GitHub issue number.

Resolve `ORCH_DECISION_MODE` once for every post-PR choice in this workflow:

```bash
.agents/skills/orch/scripts/orch-env ORCH_DECISION_MODE auto-recommended
```

**With a PR number**: `github.sh pr-issue [PR_NUMBER] --format=text` gives `ISSUE_ID`; `worktree exists`/`worktree path` give `[DIR]`. When none exists from inside the PR checkout, `auto-recommended` creates one and logs the choice; `ask` prompts first. With no argument `[DIR]` is `.`. `WT_PATH` is `git-context repo-root "[DIR]"`.

**Standalone init** (`lifecycle: "self"`): resolve `ISSUE_ID` with `git-context issue-from-branch .`, then `workflow-state exists --json [ISSUE_ID]`; when absent, initialize with `git-context branch [WT_PATH]` and `workflow-state init`.

**Every path** then resolves `TRACKER` and `ISSUE_REF` from `ISSUE_ID` per [Tracker Resolution](../SKILL.md#tracker-resolution), and `SUB_ISSUE_REF` the same way from each completed sub-issue's own id; every `Closes` line renders a tracker reference only.

---

## 1. Preflight And Local Review

### 1.1 Preflight

```bash
.agents/skills/orch/scripts/resolve-base-branch "[WORKTREE_PATH]"
.agents/skills/orch/scripts/git-context branch "[WORKTREE_PATH]"
git -C "[WORKTREE_PATH]" status --porcelain
git -C "[WORKTREE_PATH]" diff "origin/[BASE_BRANCH_FROM_PREVIOUS_COMMAND]"...HEAD --stat
```

Stop before pushing when the branch is empty (detached HEAD), equals the base branch, the working tree is dirty, or the committed diff against the base is empty. Then run `.agents/skills/preflight/scripts/preflight --base "origin/[BASE_BRANCH_FROM_PREVIOUS_COMMAND]" --repo [WORKTREE_PATH]` when installed. Reuse a successful validation result for the current commit whose mode is `full` and whose class covered the whole branch, from an accepted dev completion artifact's `validate_mode` with a `null` `validate_class_base` or a `validate_selection` of `battery`, or this submit session. A `range` pass, or any other `full` pass with a `validate_class_base`, is never reused, because it covers one fix round's changes and not the branch: submit then runs `DEV_VALIDATE_CMD` for the current commit as when no dev result exists. A failing dev validation artifact blocks submission and is reported without another validation run. A dev `no-verdict` result for the current commit, `full` or `range`, is not re-run: its battery already hit the bound, its `validate_note` names the scoped suites that passed, and CI is the full record. A run submit starts that ends `no-verdict` takes the fallback [dev-implement.md § 5. Validate](../../dev/workflows/dev-implement.md#5-validate) gives the dev round: its scoped suites once each, one red blocking the push and all green pushing with those suites named in the PR body; a diff whose fallback selects no suite file is a failing result and blocks the push. When no dev result exists, run the project's `DEV_VALIDATE_CMD` through `.agents/skills/orch/scripts/dev-validate-run`, started and polled as [dev SKILL.md § Long-Running Validation](../../dev/SKILL.md#long-running-validation) sets out, the same route [dev-implement.md § 5. Validate](../../dev/workflows/dev-implement.md#5-validate) takes. A start refused as `run-live` ran nothing: it blocks no push and returns nothing to the caller; take that section's route for that refusal, then start again. What the runner hands the command, and whose failure a full battery the class does not need is, are that section's. A changed commit needs a new result. Either check failing blocks the push. In managed lifecycle, return the failed preflight to the caller so the dev agent can normalize the branch and clean the worktree. Never create a PR from dirty or detached state.

### 1.2 Local Pre-PR Review

Drain what a review bot would surface before the PR exists.

**Skip if** any holds: `lifecycle` is `"managed"`; a PR number argument was provided (arrived comments are triaged in § 3); or `.agents/skills/second-opinion/scripts/second-opinion` does not exist.

Run `second-opinion …`; it backgrounds itself and prints when to check.

```bash
mkdir -p [WORKTREE_PATH]/tmp
.agents/skills/orch/scripts/git-context timestamp epoch
.agents/skills/orch/scripts/git-context timestamp compact
.agents/skills/second-opinion/scripts/second-opinion review --cwd [WORKTREE_PATH] --output [WORKTREE_PATH]/tmp/review-local-[TIMESTAMP_FROM_PREVIOUS_COMMAND].json --foreground
```

Capture the launch status, stdout, and stderr. A nonzero launch or stdout with no line beginning `wait:` means no wait protocol exists: report `local external review failed — [SECOND-OPINION STDERR]` and continue to § 2 without running the wait command or `review-artifact-check`.

Execute the exact command printed after `wait:` and repeat it per its exit code (`second-opinion --help`) until terminal, doing other event checks in between, before running `review-artifact-check`.

Use the epoch output as `LOCAL_STARTED_AT`:

```bash
.agents/skills/orch/scripts/review-artifact-check --file "$LOCAL_OUTPUT" [WORKTREE_PATH] [LOCAL_STARTED_AT]
```

`ok == true` → route the findings below; `reason == "valid_undermeasured"` → report its `measurement_failed` string (and `measurement_suppressed` when present) with the findings; never treat the local pass as clean. `ok == false`, or any non-zero exit, → report the `reason` and its `detail` and continue to § 2. Local review is advisory, never a submission blocker, and none of those outcomes is a pass.

Route the findings per the `review-finding` schema. Disposition every finding per [references/finding-disposition.md](../references/finding-disposition.md) § Decision flow, Step 0 first, and only what survives it enters the fix set. No blockers and no `category: "fix"` or `category: "issue"` suggestions → § 2. Otherwise delegate any blockers and fix-category suggestions: `⤵ workflows/dev-fix.md § 1-3 → § 1.2 tail` with context `worktree`, `lifecycle: "managed"`, `issue_id`, `items` (blockers plus fix-category suggestions), `source: local-review`. `category: "issue"` suggestions and the fix round's escalated items that clear the filing bar ([references/finding-disposition.md](../references/finding-disposition.md)) build an audit-input file at `tmp/audit-local-review-YYYYMMDD-HHMMSS.json` per `.agents/skills/project-management/schemas/audit-issues-input.md` with `source: "local-review"`, then apply [skill-rules.md § Coordination](../references/skill-rules.md#coordination) before `⤵ .agents/skills/project-management/workflows/audit-issues.md --issues [FILE_PATH] § 1-9`, each escalated item taking the `origin` its `outcome` maps to in [`review-pr.md`](review-pr.md) § 8, with the created IDs listed in the PR body.

**The loop is bounded at one confirming pass.** If dev-fix applied commits, run the review once more over the updated diff, then run § 1.1's validation for the new HEAD under § 1.1's rules for a pass that covers one fix round's changes and a `no-verdict` result, then → § 2 regardless of what the review found. If nothing was applied, → § 2.

---

## 2. Push And Submit

When a cut follows the last review pass, set the existing `pre_delegate_sha` workflow-state boundary to the cut commit's parent, route exactly once through [review-pr.md § Bounded Re-Review](review-pr.md#bounded-re-review) before push, and keep the cut in a commit whose parent contains everything it deletes. Before every push, run `env -u GH_REPO -u GITHUB_REPOSITORY .agents/skills/orch/scripts/pr-view-json "[WORKTREE_PATH]" --json number,state,autoMergeRequest` and record whether `autoMergeRequest` is armed. While workflow state `pr_order` reads `open-first`, an armed read is a PR armed before its internal review returned: unarm it first by [merge-pr-restack.md](merge-pr-restack.md) step 1, whose hand-back pushes nothing and returns to the caller. After § 6.1 confirms all merge gates, an armed standalone submit enters [merge-pr.md](merge-pr.md) from its entry point, while an armed managed submit returns that recorded decision with its final result so the caller's merge stage owns the canonical lifecycle. Arming happens only through `github.sh pr-merge --auto`, which refuses with `arm: no-merge-gate` on a repository with no merge gate; a raw `gh pr merge --auto` is never the arm.

1. **Push**. With workflow state `pr_order` reading `open-first-returned`, the first pass after the internal review of the PR [start-worktree.md](start-worktree.md) § 2.1 opened, first run § 3's triage pass, `⤵ workflows/review-pr-comments.md [PR_NUMBER] § 1-8 → § 2 step 1 push` with managed context, `[PR_NUMBER]` being the `number` this section's opening `pr-view-json` read printed: its fix round commits on top of the internal review's, its push through `worktree-push` by that workflow's § 6.1 carries both, and that workflow resolves its own fix SHAs through `.rebase_map` before its replies cite them, and the push below sends what remains. The triage returns to the `worktree-push` command below, never to this step's start, whose condition still holds.

   ```bash
   .agents/skills/orch/scripts/worktree-push --worktree "[WORKTREE_PATH]" --issue [ISSUE_ID] --set-upstream
   ```

   The push rebases onto the updated base where that base needs it and reconciles every SHA workflow state records. A merge-queue base whose rules demand no up-to-date branch takes a branch that merges cleanly as it stands; `worktree push --help` § Merge-queue base owns that rule. Route its exit code and its `sha-reconcile:` line by `worktree-push --help`, which owns the reconciliation and repair contract.

   A `worktree-push-base-conflict` refusal pushed and rebased nothing: the branch conflicts with that base, and the guarded restack is its one rebase. Run [merge-pr-restack.md](merge-pr-restack.md) steps 1-3, which unarm the PR where one exists, restack, validate the restacked head where the project sets `DEV_VALIDATE_RANGE_CMD`, and push through `worktree-push`, then continue here; a red run there hands back instead.

   Regenerate any already-drafted publication text from the reconciled state, and resolve every SHA sourced from a review or QA artifact (e.g. a perf QA `benchmark_commit`) through `.rebase_map` before publishing it — follow the chain until no key matches. Publishing an unreconciled pre-rebase SHA is forbidden.

   **Open-first head.** On that `open-first-returned` pass, once the push lands, this step owns the pushed head: it ends the overseer's hold and routes the head once. In a lane whose brief names a status file, write the review line `Review: [VERDICT]` in place of the pending line, `[VERDICT]` being the verdict [review-pr.md](review-pr.md) § 9 returned. Then, lane or not, record the pass, so no later pass repeats the triage-first branch:

   ```bash
   .agents/skills/orch/scripts/workflow-state set [ISSUE_ID] pr_order open-first-pushed
   ```

   Then run [review-pr-comments.md](review-pr-comments.md) § 7.2, including its current-head Copilot wait before the mode read. Keep `[COPILOT_WAIT]` for its **Head moved** route. Bypass only its **Skip if** conditions: the triage's own § 7.2 routed no head on this pull request, so this run routes the pushed head whatever threads the triage answered. With no Copilot review, the head takes **Head moved**. Work already requested on that head counts as its request. Otherwise request that head even where the push moved nothing: GitHub's request event restarts pr-watch's quiet period, so the overseer's held `awaiting-stale` line rises again after the hold ends.

2. **Check for an existing PR**:

   ```bash
   .agents/skills/orch/scripts/pr-view-json "[WORKTREE_PATH]" --json number,state
   ```

   `status` of `no_pr` means create one in step 4. Stop and report auth, token, timeout, or parse errors.

3. **Build the PR body.** Write it to a file with the harness file-write tool or `apply_patch`, never redirection or a heredoc, at `[WORKTREE_PATH]/tmp/pr-body-[ISSUE_ID]-[TIMESTAMP].md` (`git-context timestamp compact`), and use that path as `BODY_FILE`.

   ```markdown
   ## Summary
   [1-3 bullets describing the changes]

   ## Context
   - **[DECISION_ID]**: [ONE_LINE_SUMMARY] — `[DECISION_FILE_PATH]`
   - **Research**: [TITLE] — `[RESEARCH_FILE_PATH]`

   ## Completed Issues
   - Closes [ISSUE_REF] - [TITLE]
     - Closes [SUB_ISSUE_REF] - [SUB_TITLE]

   ## Created Issues
   - [ISSUE_ID] - [TITLE] — Project: [PROJECT]

   ## QA Metrics
   [Results from the QA agents that ran — project-configurable.]

   ## Merge decision
   [Pending the merge attempt. The lane records the returned merge-route line here.]

   ## Proposed rules
   [Each string in workflow state `pr_comment_review.proposed_rules`.]

   ## Test Plan
   [validation steps]
   ```

   Keep `## Merge decision`. For an existing PR, preserve its recorded head and route through body updates; use pending text only before any attempt is recorded. Omit other empty sections. Include each proposed rule once and do not perform it. Decision paths come only from `decisions search --issue [ISSUE_ID]`, each verified with `test -f [DECISION_FILE_PATH]` (one command per path) and omitted on failure. Every published SHA must be post-reconciliation.

4. **Create or update the PR.** Never defer, queue, or gate CI behind bot review activity.

   ```bash
   .agents/skills/github/scripts/github.sh -C "[WORKTREE_PATH]" pr-create --title "[PREFIX]([ISSUE_ID]): [ISSUE_TITLE]" --body-file "$BODY_FILE"
   ```

   With an existing PR, update the body instead:

   ```bash
   .agents/skills/github/scripts/github.sh -C "[WORKTREE_PATH]" pr-edit-body "$PR_NUM" --body-file "$BODY_FILE"
   ```

   `[ISSUE_TITLE]` comes from `linear.sh issues get [ISSUE_ID]` or `gh issue view [N] --json title --jq '.title'`.

5. **Arm auto-merge** as soon as the PR exists, on every pass through this section, for a PR that will take the queue: the arm reads [merge-pr.md](merge-pr.md) § 5 step 1's merge route and arms nothing where that route takes the PR past the queue. **Skip if** `orch-env ORCH_MERGE_AUTONOMY auto` prints anything but `auto`: the arm is the merge consent that setting holds back. **Skip if** workflow state `pr_order` reads `open-first`: the internal review of the PR [start-worktree.md](start-worktree.md) § 2.1 opened has not returned, and the pass after [review-pr.md](review-pr.md) § 9 arms it, as a review-first PR is armed once its review returns.

   Read the bot token as [merge-pr.md § 4](merge-pr.md#4-prepare) does. `.configured: false` arms nothing here: whose name a merge lands under is the decision [merge-pr.md](merge-pr.md) § 4 owns, and § 4-§ 5 there make the arm.

   ```bash
   .agents/skills/github/scripts/github.sh bot-token
   ```

   Detach orphaned children next, before any arm: once the PR is armed GitHub can merge it before [merge-pr.md](merge-pr.md) reaches its own detach, and the merge's cascade-Done would close them. Run [merge-pr.md § 4.1](merge-pr.md#41-detach-orphaned-children) for this item, `[ISSUE]` being `[ISSUE_ID]`, with its skip conditions and its per-orphan ask, which a lane sends through its ask gate. **Skip if** workflow state already records `children_detached`, the detach running once per item. An abort there arms nothing: skip the rest of this step, and [merge-pr.md](merge-pr.md) § 4.1 runs the detach again. Record the detach once it completes, or once § 4.1's own conditions skip it:

   ```bash
   .agents/skills/orch/scripts/workflow-state set [ISSUE_ID] children_detached true
   ```

   Read the pushed head:

   ```bash
   git -C "[WORKTREE_PATH]" rev-parse HEAD
   ```

   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY .agents/skills/github/scripts/github.sh -C "[WORKTREE_PATH]" pr-merge [PR_NUMBER] --auto --expected-head [HEAD_SHA]
   ```

   Before routing the exit, apply [merge-pr.md § 5 step 1](merge-pr.md#5-execute-the-merge)'s **Record the merge decision** instruction with `[HEAD_SHA]`, this call's exit and returned route. Use `[STATE_KEY]=[ISSUE_ID]` and this worktree as `[MAIN_REPO_ROOT]` for that instruction. The record must survive an early merge and the later already-merged shortcut.

   Exit `75` armed it. `pr-merge` arms only where the base requires an approval and thread resolution and dismisses stale approvals on push, so GitHub then holds the merge until an approval of the current head, thread resolution and every required check pass (`pr-merge --help` § Approvals and review threads), and the CI wait, the gate wait and § 6.1 are the lane's triage and fix work, not preconditions of the arm, and a turn that ends mid-chain leaves the PR armed. The late-findings guard starts where [merge-pr.md](merge-pr.md) § 5 step 1 arms the prepared head again and waits in `queue-wait`; the window before it is the accepted gap [merge-pr.md](merge-pr.md) § 5 step 5 answers. Exit `0` merged it: § 6 enters [merge-pr.md](merge-pr.md), whose § 3.2 takes a merged PR straight to its post-merge steps. On exit `1`, the shared recording instruction above confirms removal of any prior arm before this routing. Exit `1` with first line `merge-route: admin cause=queue-bypass-safe ruleset=<ids> bypass=<values>` armed nothing because [merge-pr.md](merge-pr.md) § 5 step 1's direct attempt takes this PR past the queue once its gates pass, and an arm would have GitHub queue it first: continue with the PR unarmed. Exit `1` with a diagnostic line starting `arm: no-merge-gate=unverified repo=<owner/repo>`, including after a `merge-route:` line, armed nothing because the base branch's rules could not be read: a read failure, not a ruleset gap. Report it and continue; [merge-pr.md](merge-pr.md) § 5 arms the prepared head after § 6.1. Exit `1` with any other `arm: no-merge-gate=<gap>` armed nothing because that repository has auto-merge off, or that base branch requires no approval, no thread resolution or no stale-approval dismissal, and an arm there would merge before review, past an open thread, or on an approval of an earlier head: report the line once and continue. That repository's merge keeps the route [merge-pr.md](merge-pr.md) § 5 sets out, after § 6.1, and the fix that lets it arm here is the setting the line names. Any other exit `1` armed nothing: continue, and [merge-pr.md](merge-pr.md) § 5 arms the prepared head after § 6.1.

Once the PR exists, this run is a continuing action. Clear any stop a capped run left before entering another post-PR gate:

```bash
.agents/skills/orch/scripts/workflow-state update [ISSUE_ID] '.post_pr_stop = null'
```

---

## 3. Async Comment Triage

**Bot prose is never a gate signal** — emoji reactions, sticky comments, and checklist text are never parsed for gating. Triage what exists now and move on; every bot comment still gets a reply and a resolution.

```bash
.agents/skills/github/scripts/github.sh pr-threads [PR_NUMBER] --unresolved
```

`.unresolved_count == 0` → § 3.2. Otherwise **Run Workflow**: `⤵ workflows/review-pr-comments.md [PR_NUMBER] § 1-8 → § 3 tail` with managed context. That workflow records its own results (§ 8) and counts its own pass (§ 6.3); write neither here.

Do not wait for a bot re-review round — late comments are caught by the § 4 gate, the § 6.1 gate-3 check, or queue-wait's late-findings guard, which reaches `merge-pr.md` § 5 step 1 as the `dequeued` verdict and routes to its Late-findings triage cycle.

The **re-submit set** is the issues this session filed for work the cap did not deny. A filing that stood in for a fix the cap refused — one made at or past `REVIEW_MAX_EXTERNAL_ROUNDS`, or deferred rather than fixed — is recorded in `pr_comment_review.issues_created` and reported in the PR body, and never enters the set: implementing it here is the fix the cap refused, one step later. The re-submit set needs implementing before merge, bounded at two re-submit cycles:

```bash
.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '.submit_cycles // 0'
```

At 2 or more → § 3.2 with the note "max re-submit cycles reached, the re-submit set may need manual implementation". Otherwise increment `submit_cycles`, implement via `⤵ workflows/dev-start.md § 1-4`, review via `⤵ workflows/review-pr.md § 1-9` (both managed, same `worktree` and `issue_id`), then re-enter § 2 to push and update the PR body with the new `Closes` lines.

### 3.2 Golden Baselines

**Skip if** the consumer's `[skill-instructions].orch`, injected into the installed `SKILL.md` Project Instructions, selects no baseline policy. Continue to § 4 without capture, a baseline commit or a push. An issue label alone grants none of them.

With a selected policy, apply its capture criterion and visual QA target. If the criterion does not hold, continue to § 4. If no baseline-capable target exists, report why and continue to § 4 without capture. Apply the policy's approval, host and isolation gate before capture; an unmet gate continues to § 4 without capture.

Only after those conditions pass, capture with the selected target in the worktree, then stage and inspect:

```bash
git -C [WT_PATH] add [BASELINE_PATH]/
git -C [WT_PATH] diff --cached --name-only
git -C [WT_PATH] diff --cached
```

Only a separately selected baseline-only CI exception permits a CI skip, with the subject that exception names. Verify that every staged file is a baseline file before using it. Staged product code takes no exception: commit under the normal commit rules and return to § 2's normal submission path. With only baseline files staged but no selected exception, use normal CI and the normal commit rules for `[BASELINE_SUBJECT]`. With no staged changes, continue to § 4. Otherwise commit the separate baseline change and push, still under the selected capture policy:

```bash
git -C [WT_PATH] commit -m "[BASELINE_SUBJECT]"
.agents/skills/worktree/scripts/worktree push [WT_PATH] --no-rebase
```

---

## 4. Review Gate

The review gate runs **before** CI verification, universally, with no repo detection. Named stops below use [SKILL.md § The Cycle](../SKILL.md#the-cycle).

Bind `[REVIEW_BASE_CHECKOUT]` per [Gate-mode routing](../references/gates.md#gate-mode-routing). Resolve through that consumer base:

```bash
env -u GH_REPO -u GITHUB_REPOSITORY .agents/skills/orch/scripts/approval-wait [PR_NUMBER] --resolve-mode --base-checkout [REVIEW_BASE_CHECKOUT]
```

The printed value is `GATE_MODE`, `approval` or `off`, resolved by the trusted owner per [Gate-mode routing](../references/gates.md#gate-mode-routing); never re-derive it here. A non-zero exit is no mode: report it and do not guess one. This gate reads only GitHub-native review state, from any reviewer, human or bot; bot-specific signals are never parsed.

Record the resolved mode as a bare word (never pre-quoted):

```bash
.agents/skills/orch/scripts/workflow-state set [ISSUE_ID] pr_review.mode [GATE_MODE]
```

For `off`, skip the wait and go to § 5. The internal review, CI, and comment-hygiene gates still apply in full, and gate 3 below applies too.

A retarget changes the base without touching the head, so every path below that re-resolves the mode runs this section's command again and records what it prints, and § 6.1 re-runs it before gate 4.

**Who acts.** The lane waits and triages under its own credential, and never approves its own PR. The overseer approves a head only as [copilot-head-notices.md](../references/copilot-head-notices.md) sets, reached by pr-watch's `awaiting-stale` line ([oversee-events.md](../references/oversee-events.md), `pr-watch`) or a Copilot notice from a lane: [review-pr-comments.md](review-pr-comments.md#72-copilot-head-route) § 7.2 sends each kind, [gates.md § Copilot requests](../references/gates.md#copilot-requests) sends `copilot-fallback` on a refused request, and under `PR_COPILOT_REQUESTS=off` the wait in step 1 sends it itself, once per head (`approval-wait --help`). The lane's own `timeout` row below keeps it waiting or asks the user. An approval that arrives ends the wait as `approved`.

1. **Wait.** Poll for the verdict and new comments together:

   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY .agents/skills/orch/scripts/approval-wait [PR_NUMBER] 30 --json --mode [GATE_MODE] --item [ISSUE_ID] --base-checkout [REVIEW_BASE_CHECKOUT]
   ```

   No `max_wait` positional: the budget resolves through `PR_REVIEW_WAIT_SECS`. approval-wait emits a JSON result on every exit but `2` and `5`. Exit `2` is a stop: report its stderr line.

   | `status` | Action |
   |----------|--------|
   | `approved` | Clear the review-wait budget, then → step 2. An approval returns only with zero unresolved threads: one standing open returns `comments` |
   | `proceeded` | Reviewer-down degrade under `PR_REVIEW_ON_TIMEOUT=proceed`. Clear the review-wait budget, record `pr_approval.reviewer_down` (below), then → step 2. CI and gate 3 still apply in full. Orch posts no status and manufactures no review evidence |
   | `changes_requested` or `comments` | Run the triage pass, then the Restart check |
   | `unreviewable` | No automatic reviewer targets this PR's base ([references/gates.md](../references/gates.md) § Stacked pull requests). Run the [Copilot request owner](../references/gates.md#copilot-requests) once. On `approval`, enter the Restart check. On `fallback`, route as that owner says, then enter the Restart check. On `off`, go to § 5. If the wait returns `unreviewable` again, `auto-recommended` records `review-gate-unreviewable`; `ask` presents `Force merge` \| `Keep waiting` \| `Stop here`, with `Stop here` recommended, and routes the answer by the override paragraph below |
   | `copilot-error` | Route as [Copilot requests](../references/gates.md#copilot-requests) says, then enter the Restart check. The approval gate stays unmet until an approval arrives |
   | `timeout` | `auto-recommended` logs `Keep waiting` and enters the Restart check; `ask` presents `Force merge` \| `Keep waiting` \| `Stop here`, with `Keep waiting` recommended, and routes the answer by the override paragraph below |
   | `error` | Re-run step 1 once. If it repeats, `auto-recommended` records `review-gate-read-failed`; `ask` presents `Keep waiting` \| `Stop here`, with `Keep waiting` recommended |

   ```bash
   .agents/skills/orch/scripts/workflow-state set [ISSUE_ID] pr_approval.reviewer_down true
   ```

   A met gate clears its head-bound budget:

   ```bash
   .agents/skills/orch/scripts/workflow-state update [ISSUE_ID] '.post_pr_budgets.review_wait = null'
   ```

   **Triage pass**: `⤵ workflows/review-pr-comments.md [PR_NUMBER] § 1-8 → § 4 step 1` with managed context. It applies the external cap to its own fix pushes; what bounds this step is the Restart check.

   **Restart check.** Every automatic path that would restart the wait passes through the one atomic budget owner first. Resolve the authoritative head immediately before each take so a triage push resets the counter:

   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY gh pr view [PR_NUMBER] --json headRefOid --jq .headRefOid
   ```

   ```bash
   .agents/skills/orch/scripts/workflow-state head-budget take [ISSUE_ID] review-wait [REVIEW_HEAD]
   ```

   `continue` restarts step 1, after re-resolving `GATE_MODE` by this section's command and recording it; `at-cap` records `review-round-cap` through `post-pr-stop`, posts the rendered comment, returns `MERGE_READY = false`, and skips § 5:

   ```bash
   .agents/skills/orch/scripts/workflow-state post-pr-stop record [ISSUE_ID] review-round-cap review "[REMAINING_FEEDBACK]" [WORKTREE_PATH]/tmp/post-pr-stop-[ISSUE_ID].md
   ```

   ```bash
   .agents/skills/github/scripts/github.sh post-comment [PR_NUMBER] --body-file [WORKTREE_PATH]/tmp/post-pr-stop-[ISSUE_ID].md
   ```

   `ask` presents `Triage again` | `Stop here`, with `Triage again` recommended, before an automatic budget transition. A standing `changes_requested` verdict on the current head outlives a disposition. Only a dismissal or a newer review clears it. Under `ask`, `Triage again` is the user's override for one more pass, and `Stop here` goes to § 6 with `MERGE_READY = false` and skips § 5.

   **On `timeout` or `unreviewable` under `ask`**: `Keep waiting` goes to the Restart check; `Force merge` records `pr_approval.forced` and continues to step 2, which records the status that led to it, with the § 6.1 gates still applying; `Stop here` goes to § 6 with `MERGE_READY = false` and skips § 5.

   ```bash
   .agents/skills/orch/scripts/workflow-state set [ISSUE_ID] pr_approval.forced true
   ```

2. **Record the result** for gate 4 — the gate status and the `unresolved_count` at verdict time — then → § 5.

After any fix-up push: push → the Restart check, and on a restart wait for a NEW review of the new head → triage, reply to, and resolve every thread → § 5 Verify CI → § 6 merge gates.

---

## 5. Verify CI

```bash
.agents/skills/orch/scripts/ci-wait [PR_NUMBER] --required-only --json --item [ISSUE_ID]
```

| Result | Action |
|--------|--------|
| `status=complete`, `verdict=pass` | → § 6 |
| `status=complete`, `verdict=none` | Repo has no CI configured. Record `ci: none` in workflow state and → § 6 |
| `status=complete`, `verdict=fail` | → § 5.1 |
| `status=timeout` or `status=error` | Re-run once. If it repeats, `auto-recommended` records `ci-status-unconfirmed`; `ask` presents `Skip CI` \| `Retry` \| `Abort`, with `Retry` recommended |

A PR already green when the wait started reaches the first row, never this one: `ci-wait --help` pairs `verdict=pass` with `status=complete` alone.

### 5.1 CI Failure Recovery

```bash
.agents/skills/orch/scripts/workflow-state cap CI_FIX_MAX_CYCLES
```

The printed value is `MAX_CYCLES`. Reruns-in-place are for flakes and re-gating on unchanged workflows only; a PR that changes gate or CI workflow behavior exhibits it only on a fresh head.

**Run Workflow**: `⤵ workflows/ci-fix.md [PR_NUMBER] § 1-6 → § 5.1 tail` with context `worktree`, `lifecycle: "managed"`, `issue_id`. ci-fix pushes, re-confirms the § 4 gate at the new head, and only then re-verifies CI. ci-fix resolves the mode itself at the new head. Record its mode as `GATE_MODE` and its gate re-confirmation as the § 4 result. Mode `off` has no re-confirmation to record. A returned `comments`, `changes_requested` or `copilot-error` routes through the § 4 step-1 table first, then re-enters § 5 after the approval gate is met. Route a returned final CI result through the § 5 table above.

Keep routing failures back into ci-fix until CI passes or `MAX_CYCLES` is spent. At the cap, go to § 6 with a failure report that names the checks still failing, quotes ci-fix's last error summary, and lists what each cycle attempted — never a bare "CI is failing".

---

## 6. Merge Gates And Summary

### 6.1 Merge Gates

A PR merges on exactly four deterministic gates. Gates 2 and 4 **verify results already recorded** by § 5 and § 4 — do not re-run the waits; gate 3 is a final live check.

| # | Gate | Check |
|---|------|-------|
| 1 | Internal review verdict recorded | Managed: `review-pr.md` completed with verdict `pass`. Standalone: `json_paths` is non-empty |
| 2 | CI green | The § 5 result is `status=complete` with `verdict=pass`, or `verdict=none` (satisfied with a `CI: none configured` note in the summary) |
| 3 | Zero unresolved review comments | `pr-threads` reports `unresolved_count == 0` AND every actionable PR-level bot comment has a reply (tracked in `pr_comment_review.replied`) AND `check-review-replies` exits 0 |
| 4 | Reviewer-gate verdict | `approval`: § 4 ended `approved`, or a recorded `pr_approval.forced` or `pr_approval.reviewer_down` meets it. `off`: not applicable |

**Gate 4 reads the live mode, never a record.** GitHub retargets a pull request to another base without moving its head, so the mode recorded in § 4 can name a base the pull request left. Re-run § 4's command before gate 4 and record what it prints. The recorded mode gates nothing; read it for the § 7 report:

```bash
.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '.pr_review.mode // ""'
```

**Gate 1** — standalone only:

```bash
.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '{json_paths: (.json_paths // []), cycles: (.cycles // 0)}'
```

Empty `json_paths` means no internal review is recorded: report the unmet gate and recommend `orch review-pr [PR_NUMBER]`.

**Gate 2** is the recorded § 5 result. Do not re-run ci-wait. Raw `gh pr checks` output is never the gate. On a `pr-merge --check` refusal run `.agents/skills/github/scripts/github.sh ci-classify-refusal [PR_NUMBER]` and report its `cause:` line with its printed detail. Read `ci-classify-refusal --help` for the output contract.

**Gate 3** — final live check. Replying to every bot comment stays § 3.1's hygiene rule, which is not a gate in any mode.

```bash
.agents/skills/github/scripts/github.sh pr-threads [PR_NUMBER] --unresolved
```

`unresolved_count > 0` runs ONE triage pass (`⤵ workflows/review-pr-comments.md [PR_NUMBER] § 1-8 → § 6.1 gate 3`, managed, bounded by the same `REVIEW_MAX_EXTERNAL_ROUNDS` cap on `pr_comment_review.iterations`). If that pass pushed commits, re-resolve `GATE_MODE` by § 4's command and record it, then re-confirm the § 4 gate through its Restart check with a short wait (no wait when that mode is `off`), then re-run § 5:

```bash
env -u GH_REPO -u GITHUB_REPOSITORY .agents/skills/orch/scripts/approval-wait [PR_NUMBER] 15 300 --json --mode [GATE_MODE] --item [ISSUE_ID] --base-checkout [REVIEW_BASE_CHECKOUT]
```

Re-run the gate-3 command once. If threads remain and the external-round cap is below, `auto-recommended` logs `Triage again` and runs one more pass; at the cap it records `review-threads-open`. Under `ask`, present `Triage again` | `Stop here`, with `Triage again` recommended.

Then read what the replies say, live: an author can edit a reply without a push, and neither approval nor resolution reads its content.

```bash
env -u GH_REPO -u GITHUB_REPOSITORY .agents/skills/github/scripts/github.sh -C "[WORKTREE_PATH]" check-review-replies [PR_NUMBER]
```

Exit `1` prints one line per failing rule. Rewrite each reply it counts as one of the three dispositions in [finding-disposition.md § Decision flow](../references/finding-disposition.md#decision-flow). Send every `suppressed-entry` through the body-finding route in [review-pr-comments.md § 7.2 Copilot Head Route](review-pr-comments.md#72-copilot-head-route) with managed context, returning here after its triage pass. If that pass pushes commits, re-confirm the gates as the thread pass above does. Run the command once more. A reply or that comment counts only from the PR author, the identity the check runs as, or an `OWNER`, `MEMBER` or `COLLABORATOR` of the repository: post it under one of those identities. Which replies that do not count the command names on stderr is in `check-review-replies --help`. A second exit `1` records `review-replies-unmet`. Exit `2` reached no verdict: report its first stderr line, and the gate is unmet.

**Gate 4** — verify the recorded § 4 result, under the mode the resolution above printed.

`MERGE_READY = true` only when all four gates are met.

**No stop leaves an armed PR.** Once `MERGE_READY` is false, whether by these gates or by a stop that sent the run here, take [merge-pr-restack.md § Unarm at a stop](merge-pr-restack.md#unarm-at-a-stop) before § 6.2 or § 7 reports the stop, with `[STATE_KEY]` being `[ISSUE_ID]` and `[STOP_DIR]` being `[WORKTREE_PATH]/tmp`.

### 6.2 Standalone Summary

**Skip if** managed → § 7.

`MERGE_READY = false` records the unmet gate here, so § 7 returns a named stop instead of reading as complete; only the managed `start-worktree.md` § 5 caller recorded it before. `record-if-empty` keeps a precise upstream stop, and only `recorded` writes the file the post below sends:

```bash
.agents/skills/orch/scripts/workflow-state post-pr-stop record-if-empty [ISSUE_ID] merge-gates-unmet merge "[UNMET_GATE_AND_REMAINING_WORK]" [WORKTREE_PATH]/tmp/post-pr-stop-[ISSUE_ID].md
.agents/skills/github/scripts/github.sh post-comment [PR_NUMBER] --body-file [WORKTREE_PATH]/tmp/post-pr-stop-[ISSUE_ID].md
```

Post a summary comment when there were fixes or created issues. Fix SHAs come from workflow state; artifact-sourced SHAs resolve through `.rebase_map` first. Write the summary to a file and post it:

```bash
.agents/skills/github/scripts/github.sh post-comment [PR_NUMBER] --body-file "$SUMMARY_FILE"
```

Linear items also get it on the issue; GitHub items get linkage through `Closes #N` in the PR body:

```bash
.agents/skills/linear/scripts/linear.sh comments create [ISSUE_ID] --body-file "$SUMMARY_FILE"
```

```markdown
## Recommendations Processed

### Fixed in PR
- [SOURCE]: [ITEM] — [SHA]

### Issues Created
- [ISSUE_ID] - [TITLE] — [PROJECT]

### Skipped
- [SOURCE]: [ITEM] — [REASON]
```

Output: [Lane Output](../references/skill-rules.md#lane-output).

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

**Merge** — skip unless `MERGE_READY`.

```bash
.agents/skills/orch/scripts/orch-env ORCH_MERGE_AUTONOMY auto
```

`auto` → merge without asking: `⤵ workflows/merge-pr.md [PR_NUMBER] § 1-7 → end`. Anything else → ask `orch merge-pr [PR_NUMBER]` | `Skip`, and on merge run the same workflows. `MERGE_READY = false` never auto-merges: § 6.1 disarmed a PR § 2 step 5 armed. On a PR that step armed, [merge-pr.md](merge-pr.md) keeps only the queue wait, the late-thread answers and the post-merge steps: its § 5 arm re-arms the prepared head and answers exit `75`.

---

## 7. Return

**Managed**: return to the parent workflow's next section with the § 6.1 gate results (`MERGE_READY`, the § 4 gate mode and status, the unresolved thread count, the § 5 CI verdict). **Standalone**: return `.post_pr_stop` when present; otherwise the session is complete.
