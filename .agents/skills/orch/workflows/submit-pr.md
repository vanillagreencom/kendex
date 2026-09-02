# Submit PR Workflow

Run a local pre-PR review, push, create or update the PR, triage review comments, wait for the reviewer-gate verdict, verify CI, and confirm the merge gates. The review gate (§ 4) runs before CI verification (§ 5).

| Command | Behavior |
|---------|----------|
| `submit-pr` | Submit the current branch as a PR |
| `submit-pr [PR#]` | Manage an existing PR |
| (from start-worktree) | Managed lifecycle with caller context |

**Caller context** (via `⤵`): `worktree`; `lifecycle` — `"managed"` (return at § 7) or `"self"` (default); `issue_id` — the workflow-state key, the normalized issue ID, never the bare GitHub issue number.

**With a PR number**: `github.sh pr-issue [PR_NUMBER] --format=text` gives `ISSUE_ID`; `worktree exists`/`worktree path` give `[DIR]`, or ask before creating one when already inside the PR checkout; with no argument `[DIR]` is `.`. `WT_PATH` is `git-context repo-root "[DIR]"`.

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

Stop before pushing when the branch is empty (detached HEAD), equals the base branch, the working tree is dirty, or the committed diff against the base is empty. Then run `.agents/skills/preflight/scripts/preflight --base "origin/[BASE_BRANCH_FROM_PREVIOUS_COMMAND]" --repo [WORKTREE_PATH]` when installed, and re-run the validation command this session's dev rounds used. Either failing blocks the push. In managed lifecycle, return the failed preflight to the caller so the dev agent can normalize the branch and clean the worktree. Never create a PR from dirty or detached state.

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
.agents/skills/orch/scripts/review-artifact-check --file "$LOCAL_OUTPUT" [LOCAL_STARTED_AT]
```

`ok == true` → route the findings below; `reason == "valid_undermeasured"` → report its `measurement_failed` string (and `measurement_suppressed` when present) with the findings; never treat the local pass as clean. `ok == false`, or any non-zero exit, → report the `reason` and its `detail` and continue to § 2. Local review is advisory, never a submission blocker, and none of those outcomes is a pass.

Route the findings per the `review-finding` schema. Disposition every finding per [references/finding-disposition.md](../references/finding-disposition.md) § Decision flow, Step 0 first, and only what survives it enters the fix set. No blockers and no `category: "fix"` or `category: "issue"` suggestions → § 2. Otherwise delegate any blockers and fix-category suggestions: `⤵ workflows/dev-fix.md § 1-3 → § 1.2 tail` with context `worktree`, `lifecycle: "managed"`, `issue_id`, `items` (blockers plus fix-category suggestions), `source: local-review`. `category: "issue"` suggestions and the fix round's escalated items that clear the filing bar ([references/finding-disposition.md](../references/finding-disposition.md)) build an audit-input file at `tmp/audit-local-review-YYYYMMDD-HHMMSS.json` per `.agents/skills/project-management/schemas/audit-issues-input.md` with `source: "local-review"`, then go through `⤵ .agents/skills/project-management/workflows/audit-issues.md --issues [FILE_PATH] § 1-9`, each escalated item taking the `origin` its `outcome` maps to in [`review-pr.md`](review-pr.md) § 8, with the created IDs listed in the PR body.

**The loop is bounded at one confirming pass.** If dev-fix applied commits, run the review once more over the updated diff, then go to § 2 regardless of what it found. If nothing was applied, → § 2.

---

## 2. Push And Submit

1. **Push**:

   ```bash
   .agents/skills/orch/scripts/worktree-push --worktree "[WORKTREE_PATH]" --issue [ISSUE_ID] --set-upstream
   ```

   The push auto-rebases onto the updated base and reconciles every SHA workflow state records. Route its exit code and its `sha-reconcile:` line by `worktree-push --help`, which owns the reconciliation and repair contract.

   Regenerate any already-drafted publication text from the reconciled state, and resolve every SHA sourced from a review or QA artifact (e.g. a perf QA `benchmark_commit`) through `.rebase_map` before publishing it — follow the chain until no key matches. Publishing an unreconciled pre-rebase SHA is forbidden.

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

   ## Test Plan
   [validation steps]
   ```

   Omit empty sections. Decision paths come only from `decisions search --issue [ISSUE_ID]`, each verified with `test -f [DECISION_FILE_PATH]` (one command per path) and omitted on failure. Every published SHA must be post-reconciliation.

4. **Create or update the PR.** Never defer, queue, or gate CI behind bot review activity.

   ```bash
   .agents/skills/github/scripts/github.sh -C "[WORKTREE_PATH]" pr-create --title "[PREFIX]([ISSUE_ID]): [ISSUE_TITLE]" --body-file "$BODY_FILE"
   ```

   With an existing PR, update the body instead:

   ```bash
   .agents/skills/github/scripts/github.sh -C "[WORKTREE_PATH]" pr-edit-body "$PR_NUM" --body-file "$BODY_FILE"
   ```

   `[ISSUE_TITLE]` comes from `linear.sh cache issues get [ISSUE_ID]` or `gh issue view [N] --json title --jq '.title'`.

---

## 3. Async Comment Triage

**Bot prose is never a gate signal** — emoji reactions, sticky comments, and checklist text are never parsed for gating. Triage what exists now and move on; every bot comment still gets a reply and a resolution.

```bash
.agents/skills/github/scripts/github.sh pr-threads [PR_NUMBER] --unresolved
```

`.unresolved_count == 0` → § 3.2. Otherwise **Run Workflow**: `⤵ workflows/review-pr-comments.md [PR_NUMBER] § 1-8 → § 3 tail` with managed context. That workflow records its own results (§ 8) and counts its own pass (§ 6.3); write neither here.

Do not wait for a bot re-review round — late comments are caught by the § 4 gate, the § 6.1 gate-3 check, or queue-wait's late-findings guard, which reaches `merge-pr.md` § 5 as a `triage` action.

The **re-submit set** is the issues this session filed for work the cap did not deny. A filing that stood in for a fix the cap refused — one made at or past `REVIEW_MAX_EXTERNAL_ROUNDS`, or deferred rather than fixed — is recorded in `pr_comment_review.issues_created` and reported in the PR body, and never enters the set: implementing it here is the fix the cap refused, one step later. The re-submit set needs implementing before merge, bounded at two re-submit cycles:

```bash
.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '.submit_cycles // 0'
```

At 2 or more → § 3.2 with the note "max re-submit cycles reached, the re-submit set may need manual implementation". Otherwise increment `submit_cycles`, implement via `⤵ workflows/dev-start.md § 1-4`, review via `⤵ workflows/review-pr.md § 1-9` (both managed, same `worktree` and `issue_id`), then re-enter § 2 to push and update the PR body with the new `Closes` lines.

### 3.2 Golden Baselines

**Skip if** the issue does not carry the `design` label (`linear.sh cache issues get [ISSUE_ID] --format=compact`, or `gh issue view [N] --json labels`).

Capture golden baselines in the worktree with the project's visual QA tooling; if the project has no baseline-capable target, skip and report why. Commit and push without retriggering CI:

```bash
git -C [WT_PATH] add [BASELINE_PATH]/
git -C [WT_PATH] commit -m "chore: update golden baselines [skip ci]"
.agents/skills/worktree/scripts/worktree push [WT_PATH] --no-rebase
```

---

## 4. Review Gate

The review gate runs **before** CI verification, universally, with no repo detection.

```bash
.agents/skills/orch/scripts/approval-wait --resolve-mode
```

The printed value is `GATE_MODE` — `approval`, `review`, or `off` (full semantics: [references/gates.md](../references/gates.md)); never re-derive it here. This gate reads only GitHub-native review state, from any reviewer, human or bot; bot-specific signals are never parsed.

Record the resolved mode as a bare word (never pre-quoted):

```bash
.agents/skills/orch/scripts/workflow-state set [ISSUE_ID] pr_review.mode [GATE_MODE]
```

For `off`, skip the wait and go to § 5 — the internal review, CI, and comment-hygiene gates still apply in full.

1. **Wait.** Poll for the verdict and new comments together:

   ```bash
   .agents/skills/orch/scripts/approval-wait [PR_NUMBER] 30 --json --mode [GATE_MODE]
   ```

   No `max_wait` positional: the budget resolves through `PR_REVIEW_WAIT_SECS`. approval-wait always emits a JSON result and nudges a silent reviewer itself after `PR_REVIEW_NUDGE_SECS`, once per head SHA, with the clock restarting on every push.

   | `status` | Action |
   |----------|--------|
   | `approved`, `unresolved_count == 0` | → step 2 |
   | `approved`, `unresolved_count > 0` | Run the triage pass below. Pushed no commits → the approval stands, → step 2. Pushed commits → the Restart check |
   | `reviewed` | → step 2 |
   | `proceeded` | Reviewer-down degrade under `PR_REVIEW_ON_TIMEOUT=proceed`. Record `pr_approval.reviewer_down` (below), then → step 2. CI and gate 3 still apply in full. Orch posts no status and manufactures no review evidence |
   | `changes_requested` or `comments` | Run the triage pass, then the Restart check |
   | `timeout` | Ask the user: `Force merge` \| `Keep waiting` \| `Stop here` |
   | `error` | Re-run step 1 once; if it repeats, report and ask: `Keep waiting` \| `Stop here` |

   ```bash
   .agents/skills/orch/scripts/workflow-state set [ISSUE_ID] pr_approval.reviewer_down true
   ```

   **Triage pass**: `⤵ workflows/review-pr-comments.md [PR_NUMBER] § 1-8 → § 4 step 1` with managed context. It applies the external cap to its own fix pushes; what bounds this step is the Restart check.

   **Restart check.** Every path that would restart the wait passes through here first — both restart arms above, `Keep waiting` on `timeout`, and § 6.1 gate 3's re-confirmation. Nothing restarts step 1 without it:

   ```bash
   .agents/skills/orch/scripts/workflow-state cap REVIEW_MAX_EXTERNAL_ROUNDS --issue [ISSUE_ID]
   ```

   A `below` verdict on `REVIEW_MAX_EXTERNAL_ROUNDS` → restart step 1. On `at-cap` the wait does not restart on its own: present the remaining feedback and ask `Triage again` | `Force merge` | `Stop here`. A standing `changes_requested` verdict on the current head outlives a disposition — only a dismissal or a newer review clears it, and triage dismisses only what it classifies as noise — so a restart returns that same verdict at once and triages past the cap. `Triage again` is the user's override for one more pass, which returns here; `Force merge` records the override and continues to step 2 with the § 6.1 gates applying; `Stop here` goes to § 6 with `MERGE_READY = false` and skips § 5.

   **On `timeout`**: `Keep waiting` goes to the Restart check; `Force merge` records the override and continues to step 2 with the § 6.1 gates still applying; `Stop here` goes to § 6 with `MERGE_READY = false` and skips § 5.

   ```bash
   .agents/skills/orch/scripts/workflow-state set [ISSUE_ID] pr_approval.forced true
   ```

2. **Record the result** for gate 4 — the gate status and the `unresolved_count` at verdict time — then → § 5.

After any fix-up push: push → the Restart check, and on a restart wait for a NEW review of the new head → triage, reply to, and resolve every thread → § 5 Verify CI → § 6 merge gates.

---

## 5. Verify CI

```bash
.agents/skills/orch/scripts/ci-wait [PR_NUMBER] --json
```

| Result | Action |
|--------|--------|
| `status=complete`, `verdict=pass` | → § 6 |
| `status=complete`, `verdict=none` | Repo has no CI configured. Record `ci: none` in workflow state and → § 6 |
| `status=complete`, `verdict=fail` | → § 5.1 |
| `status=timeout` or `status=error` | Re-run once; if it repeats, ask: `Skip CI` \| `Retry` \| `Abort` |

### 5.1 CI Failure Recovery

```bash
.agents/skills/orch/scripts/workflow-state cap CI_FIX_MAX_CYCLES
```

The printed value is `MAX_CYCLES`. Reruns-in-place are for flakes and re-gating on unchanged workflows only; a PR that changes gate or CI workflow behavior exhibits it only on a fresh head.

**Run Workflow**: `⤵ workflows/ci-fix.md [PR_NUMBER] § 1-6 → § 5.1 tail`. ci-fix pushes, re-confirms the § 4 gate at the new head, and only then re-verifies CI. Record its gate re-confirmation as the § 4 result (skip when `GATE_MODE` is `off`), treat its final CI result as the § 5 result, and re-route through the table above. A returned `comments` or `changes_requested` routes through the § 4 step-1 table first, then re-enters § 5.

Keep routing failures back into ci-fix until CI passes or `MAX_CYCLES` is spent. At the cap, go to § 6 with a failure report that names the checks still failing, quotes ci-fix's last error summary, and lists what each cycle attempted — never a bare "CI is failing".

---

## 6. Merge Gates And Summary

### 6.1 Merge Gates

A PR merges on exactly four deterministic gates. Gates 2 and 4 **verify results already recorded** by § 5 and § 4 — do not re-run the waits; gate 3 is a final live check.

| # | Gate | Check |
|---|------|-------|
| 1 | Internal review verdict recorded | Managed: `review-pr.md` completed with verdict `pass`. Standalone: `json_paths` is non-empty |
| 2 | CI green | The § 5 result is `status=complete` with `verdict=pass`, or `verdict=none` (satisfied with a `CI: none configured` note in the summary) |
| 3 | Zero unresolved review comments | `pr-threads` reports `unresolved_count == 0` AND every actionable PR-level bot comment has a reply (tracked in `pr_comment_review.replied`) |
| 4 | Reviewer-gate verdict | `approval`: § 4 ended `approved`. `review`: § 4 ended `reviewed`. Either mode is also met by a recorded `pr_approval.forced` or `pr_approval.reviewer_down`. `off`: not applicable |

**Gate 1** — standalone only:

```bash
.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '{json_paths: (.json_paths // []), cycles: (.cycles // 0)}'
```

Empty `json_paths` means no internal review is recorded: report the unmet gate and recommend `orch review-pr [PR_NUMBER]`.

**Gate 2** = the recorded § 5 result — do not re-run ci-wait, and raw `gh pr checks` output is never the gate. On a `pr-merge --check` refusal run `.agents/skills/github/scripts/github.sh ci-classify-refusal [PR_NUMBER]` and route on its `cause:` line: `threads` → gate 3; anything else → report the cause with its printed detail (for `ci_failed` that includes the `fail:` and `superseded:` run ids) rather than forcing or abandoning the merge.

**Gate 3** — final live check:

```bash
.agents/skills/github/scripts/github.sh pr-threads [PR_NUMBER] --unresolved
```

`unresolved_count > 0` runs ONE triage pass (`⤵ workflows/review-pr-comments.md [PR_NUMBER] § 1-8 → § 6.1 gate 3`, managed, bounded by the same `REVIEW_MAX_EXTERNAL_ROUNDS` cap on `pr_comment_review.iterations`). If that pass pushed commits, re-confirm the § 4 gate through its Restart check with a short wait (skip when `GATE_MODE` is `off`), then re-run § 5:

```bash
.agents/skills/orch/scripts/approval-wait [PR_NUMBER] 15 300 --json --mode [GATE_MODE]
```

Re-run the gate-3 command once; if threads remain, present them and ask: `Triage again` | `Force merge` | `Stop here`.

**Gate 4** — verify the recorded § 4 result. Read the recorded mode:

```bash
.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '.pr_review.mode // ""'
```

`MERGE_READY = true` only when all four gates are met.

### 6.2 Standalone Summary

**Skip if** managed → § 7.

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

<output_format>

### ✅ PR SUBMITTED — #[PR_NUMBER]

| Metric | Value |
|--------|-------|
| PR | #[PR_NUMBER] |
| CI | ✅ passing / ❌ failing |
| Review gate | ✅ approved / ✅ reviewed / ⏳ pending / forced / off (no reviewer policy) |
| Unresolved threads | [N] |
| Comment iterations | [N] |
| Fixes applied | [N] |
| Issues created | [N] |

</output_format>

**Merge** — skip unless `MERGE_READY`.

```bash
.agents/skills/orch/scripts/orch-env ORCH_MERGE_AUTONOMY ask
```

`auto` → merge without asking: `⤵ workflows/merge-pr.md [PR_NUMBER] § 1-7 → workflows/lane-postmerge.md → end`. Anything else → ask `orch merge-pr [PR_NUMBER]` | `Skip`, and on merge run the same workflows. `MERGE_READY = false` never auto-merges.

---

## 7. Return

**Managed**: return to the parent workflow's next section with the § 6.1 gate results (`MERGE_READY`, the § 4 gate mode and status, the unresolved thread count, the § 5 CI verdict). **Standalone**: session complete.
