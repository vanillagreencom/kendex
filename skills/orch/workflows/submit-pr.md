# Submit PR Workflow

Run a local pre-PR review, push changes, create/update the PR with CI running immediately, triage review comments asynchronously, and verify merge gates.

## Inputs

| Command | Behavior |
|---------|----------|
| `submit-pr` | Submit current branch as PR |
| `submit-pr [PR#]` | Manage existing PR |
| (from start-worktree) | Managed lifecycle with caller context |

**Caller context parameters** (via `⤵`): `worktree`, `lifecycle` (`"managed"` → return at § 7 | `"self"` default), `issue_id` (extracted from branch if absent).

**If PR# provided:**
```bash
.agents/skills/github/scripts/github.sh pr-issue [PR_NUMBER] --format=text
.agents/skills/worktree/scripts/worktree exists [ISSUE_ID]
.agents/skills/worktree/scripts/worktree path [ISSUE_ID]
```
Use the first output as `ISSUE_ID`. If the worktree exists, use the path output as `WT_PATH`; otherwise ask before creating or use the current directory when already inside the PR checkout.

Resolve `TRACKER` per [Tracker Resolution](../SKILL.md#tracker-resolution).

**If no argument:** Set `WT_PATH` to current directory.

**Standalone init** (`lifecycle: "self"` only):
```bash
.agents/skills/orch/scripts/git-context issue-from-branch .
.agents/skills/worktree/scripts/worktree exists [ISSUE_ID]
.agents/skills/worktree/scripts/worktree path [ISSUE_ID]
.agents/skills/orch/scripts/workflow-state exists --json [ISSUE_ID]
```
Use the first output as `ISSUE_ID`. For no-arg standalone flow, prefer the current directory as `WT_PATH`; use the worktree path output only when `worktree exists` confirms it. If `.exists` is `false`, initialize:

```bash
.agents/skills/orch/scripts/git-context branch "$WT_PATH"
.agents/skills/orch/scripts/workflow-state init [ISSUE_ID] --worktree "$WT_PATH" --branch "[BRANCH_FROM_PREVIOUS_COMMAND]"
```

---

## 1. Preflight and Local Review

### 1.1 Preflight Committed Work

```bash
.agents/skills/orch/scripts/resolve-base-branch "[WORKTREE_PATH]"
.agents/skills/orch/scripts/git-context branch "[WORKTREE_PATH]"
git -C "[WORKTREE_PATH]" status --porcelain
git -C "[WORKTREE_PATH]" diff "origin/[BASE_BRANCH_FROM_PREVIOUS_COMMAND]"...HEAD --stat
```

Stop before pushing if any condition is true:
- The current branch output is empty (detached HEAD).
- The current branch output equals the base branch output.
- `git status --porcelain` is not empty.
- The committed diff against the base branch output is empty.

In managed lifecycle, return to the caller with the failed preflight so the dev agent can normalize the branch and commit or clean the worktree. Do not create a PR from dirty or detached state.

### 1.2 Local Pre-PR Review

Bot reviews are **asynchronous** in this workflow: GitHub review bots post on their own timeline and never block submission. Drain what a bot would surface *before* the PR exists — review the branch diff locally via the second-opinion skill and fix findings at local speed, with no bot round-trip latency or provider quota coupling.

**Skip if** any of:
- `lifecycle` is `"managed"` — the caller's review cycle (`review-pr.md` § 2.1-2.2) already ran the external second-opinion review of this branch diff.
- A PR number argument was provided — the PR already exists; arrived comments are triaged in § 3.
- `.agents/skills/second-opinion/scripts/second-opinion` does not exist (skill not installed).

1. **Check pass budget** (max 2 local review passes per submission):
   ```bash
   .agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '.pr_local_review.passes // 0'
   ```
   Use the output as `LOCAL_PASSES`. If `LOCAL_PASSES >= 2` → § 2.

2. **Run the local review** (advisory — on script failure, report and continue to § 2):
   ```bash
   mkdir -p [WORKTREE_PATH]/tmp
   .agents/skills/orch/scripts/git-context timestamp compact
   # Use [WORKTREE_PATH]/tmp/review-local-[TIMESTAMP_FROM_PREVIOUS_COMMAND].json as LOCAL_OUTPUT.
   .agents/skills/second-opinion/scripts/second-opinion review \
     --cwd [WORKTREE_PATH] \
     --output "$LOCAL_OUTPUT"
   ```

3. **Validate the artifact**:
   ```bash
   .agents/skills/orch/scripts/review-artifact-check --file "$LOCAL_OUTPUT"
   ```
   Count the pass:
   ```bash
   .agents/skills/orch/scripts/workflow-state increment [ISSUE_ID] pr_local_review.passes
   ```
   If `ok == false`, report the `reason` and continue to § 2 — local review is advisory, never a submission blocker.

4. **Route findings** from the JSON (`../../reviewer/schemas/review-finding.md` schema):
   - No `blockers[]` and no `suggestions[]` with `category: "fix"` → § 2 (diff drained).
   - `blockers[]` and `suggestions[]` with `category: "fix"` → delegate now:

     **Run Workflow**: `⤵ workflows/dev-fix.md § 1-3 → § 1.2 step 5` with context:
     - `worktree`: [WORKTREE_PATH]
     - `lifecycle`: `"managed"`
     - `issue_id`: [ISSUE_ID]
     - `items`: formatted blockers + fix-category suggestions
     - `source`: `local-review`
   - `suggestions[]` with `category: "issue"` → build the audit-input file and invoke `⤵ .agents/skills/project-management/workflows/audit-issues.md --issues [FILE_PATH] § 1-9 → § 1.2 step 5` (same path as `review-pr-comments.md` § 6.2). Include created issue IDs in the PR body (§ 2 step 3).

5. **Re-verify after fixes**: if dev-fix applied commits, return to step 1 for one confirming pass over the updated diff. If nothing was applied, → § 2.

---

## 2. Push and Submit PR

1. **Push branch**:
   ```bash
   .agents/skills/worktree/scripts/worktree push "[WORKTREE_PATH]" --set-upstream
   ```

2. **Check for existing PR**:
   ```bash
   .agents/skills/orch/scripts/pr-view-json "[WORKTREE_PATH]" --json number,state
   ```
   Use the JSON output as `PR_VIEW`. If `status` is `no_pr`, create a new PR in step 4. For auth, token, timeout, or unparseable errors, stop and report the JSON error.

3. **Build PR body** from current workflow state using the template below (omit empty sections).

   **PR body MUST be written to a file** — inline bodies with backticks or fenced code blocks corrupt under shell command substitution. Prefer your harness's file-write tool:

   ```bash
   mkdir -p [WORKTREE_PATH]/tmp
   .agents/skills/orch/scripts/git-context timestamp compact
   ```
   Write the PR body to `[WORKTREE_PATH]/tmp/pr-body-[ISSUE_ID]-[TIMESTAMP_FROM_PREVIOUS_COMMAND].md` with the harness file-write/edit tool or `apply_patch`, then use that path as `BODY_FILE`. Do not use shell redirection or heredocs to create the file.

   ```markdown
   ## Summary
   [1-3 bullets describing changes]

   ## Context
   [For each matching decision from `.agents/skills/decider/scripts/decisions search --issue [ISSUE_ID]` (decider skill):]
   - **[DECISION_ID]**: [ONE_LINE_SUMMARY] — `[DECISION_FILE_PATH]`
   [For each research file linked to the issue:]
   - **Research**: [TITLE] — `[RESEARCH_FILE_PATH]`

   ## Completed Issues
   - Closes [ISSUE_ID] - [TITLE]
     - Closes [SUB_ISSUE_1] - [SUB_TITLE]
     - Closes [SUB_ISSUE_2] - [SUB_TITLE]

   ## Created Issues
   - [ISSUE_ID] - [TITLE] — Project: [PROJECT]

   ## QA Metrics
   [QA_METRICS] — project-configurable. Include results from QA agents that ran during review.

   ## Test Plan
   [validation steps]
   ```

   - **Completed Issues**: Use `Closes` keyword for issue tracker linkage. Indent sub-issues.
   - **Created Issues**: Include if issues created during local review or comment triage.
   - **QA Metrics**: Include if QA agents ran. Format is project-configurable based on which QA agent types are active.

4. **Create or update PR**. CI runs immediately from the moment the PR exists — never defer, queue, or gate it behind bot review activity.

   **No existing PR** → create. Always pass the body via `--body-file`:
   ```bash
   # Linear
   .agents/skills/linear/scripts/linear.sh cache issues get [ISSUE_ID]
   # Read `.title` from the JSON output and use it as ISSUE_TITLE.
   # GitHub
   gh issue view [N] --json title --jq '.title'
   # Use the output as ISSUE_TITLE.

   .agents/skills/github/scripts/github.sh -C "[WORKTREE_PATH]" pr-create \
     --title "[PREFIX]([ISSUE_ID]): $ISSUE_TITLE" \
     --body-file "$BODY_FILE"
   ```

   **Existing PR** (`$PR_NUM` set) → update body:
   ```bash
   .agents/skills/github/scripts/github.sh -C "[WORKTREE_PATH]" pr-edit-body "$PR_NUM" --body-file "$BODY_FILE"
   ```
   If the command fails because the PR no longer exists, report the failure and continue only when the state is understood.

---

## 3. Async Comment Triage

Bot reviews are asynchronous: review bots may post minutes or hours after the PR opens. **Bot prose is never a gate signal** — emoji reactions, sticky comments, and checklist text are never parsed for gating. Triage whatever review comments exist right now and move on; the merge gates (§ 6.1) later require every comment replied to and resolved plus a GitHub-native approval verdict, and findings that arrive after merge get an immediate follow-up fix or an explicit tracking issue. Every bot comment still gets a reply and resolution — the hygiene standard is unchanged.

### 3.1 Opportunistic Triage

1. **Check what has already arrived**:
   ```bash
   .agents/skills/github/scripts/github.sh pr-threads [PR_NUMBER] --unresolved
   ```
   Read `.unresolved_count` from the JSON output and use it as `UNRESOLVED_FROM_PREVIOUS_COMMAND`. If it is `0` → § 3.5 (nothing to triage yet — later arrivals are handled at the § 6.1 gate).

2. **Run Workflow**: `⤵ workflows/review-pr-comments.md [PR_NUMBER] § 1-8 → § 3.1 step 3` with context:
   - `lifecycle`: `"managed"`
   - `issue_id`: `[ISSUE_ID]`
   - `worktree`: `[WORKTREE_PATH]`

3. **Update state** — run each block as its own tool call; the appends run once per item, so they can't be folded into a single expression:
   ```bash
   # For each fixed item:
   .agents/skills/orch/scripts/workflow-state append [ISSUE_ID] pr_comment_review.fixes '{"description":"[DESC]","location":"[LOC]","commit":"[SHA]","source":"[SOURCE]"}'
   ```
   ```bash
   # For each issue created:
   .agents/skills/orch/scripts/workflow-state append [ISSUE_ID] pr_comment_review.issues_created "[CREATED_ISSUE_ID]"
   ```
   ```bash
   # For each skipped item:
   .agents/skills/orch/scripts/workflow-state append [ISSUE_ID] pr_comment_review.skipped '{"description":"[DESC]","reason":"[REASON]"}'
   ```
   ```bash
   # Increment iteration count
   .agents/skills/orch/scripts/workflow-state increment [ISSUE_ID] pr_comment_review.iterations
   ```

4. **Route**:

   **If issues created** → § 3.2

   **Otherwise** → § 3.5. Fixes pushed during triage were already replied to and their threads resolved by `review-pr-comments.md`. Do not wait for a bot re-review round — any re-review comments land in existing or new threads and are caught at the § 6.1 gate.

### 3.2 Implement Created Issues

Sub-issues created during local review or comment triage need implementation before merge.

1. **Check cycle count**:
   ```bash
   .agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '.submit_cycles // 0'
   ```
   Use the output as `SUBMIT_CYCLES`.
   **If** `SUBMIT_CYCLES >= 2` → § 3.5 with note: "Max re-submit cycles reached, created issues may need manual implementation."

2. **Increment**:
   ```bash
   .agents/skills/orch/scripts/workflow-state increment [ISSUE_ID] submit_cycles
   ```

3. **Implement**: `⤵ workflows/dev-start.md § 1-4 → § 3.2 step 4` with context:
   - `worktree`: [WORKTREE_PATH]
   - `lifecycle`: `"managed"`
   - `issue_id`: [ISSUE_ID]

4. **Review**: `⤵ workflows/review-pr.md § 1-11 → § 3.2 step 5` with context:
   - `worktree`: [WORKTREE_PATH]
   - `lifecycle`: `"managed"`
   - `dev_agent`: from dev-start return
   - `issue_id`: [ISSUE_ID]

5. **Re-submit** → § 2 (push updated code, update PR body with new `Closes` lines)

---

## 3.5. Update Golden Baselines

**Skip if** the issue does not have the `design` label.

```bash
.agents/skills/linear/scripts/linear.sh cache issues get "[ISSUE_ID]" --format=compact
```
Read `.labels[]` from the JSON output and use it as `LABELS`. For GitHub items, read labels with `gh issue view [N] --json labels --jq '.labels[].name'`.

If `design` label present:

1. **Capture baselines in worktree**: Use visual QA skills as necessary to capture golden baselines in the worktree. If the project has no baseline-capable target, skip this step and report why.

2. **Commit and push** (without retriggering CI). Baselines are platform-specific:
   ```bash
   git -C [WT_PATH] add [BASELINE_PATH]/
   git -C [WT_PATH] commit -m "chore: update golden baselines [skip ci]"
   .agents/skills/worktree/scripts/worktree push [WT_PATH] --no-rebase
   ```

3. **Report**: `Golden baselines: updated (N scenarios)` or if capture fails, include failure reason from baseline report.

---

## 4. Verify CI

CI has been running since the PR was created or updated in § 2 — there is no bot gate in front of it.

1. **Wait for CI**:
   ```bash
   .agents/skills/orch/scripts/ci-wait [PR_NUMBER] --json
   ```
   The result is a JSON object: `status` (`complete`/`timeout`/`error`) plus `verdict` (`pass`/`fail`/`pending`). ci-wait always emits it — no silent completion.

2. **Handle CI result**:

   | Result | Action |
   |--------|--------|
   | ✅ `status=complete`, `verdict=pass` | → § 6 |
   | ❌ `status=complete`, `verdict=fail` | → § 5 |
   | ⏱ `status=timeout` or `status=error` | Re-run step 1 once; if it repeats → Ask user: `Skip CI` \| `Retry` \| `Abort` |

---

## 5. CI Failure Recovery

1. **Run Workflow**: `⤵ workflows/ci-fix.md [PR_NUMBER] § 1-7 → § 5 step 2`

2. **After ci-fix returns**:
   - If fix applied → ci-fix already pushed and re-verified CI (its § 5); treat its final CI result as the § 4 result and re-route via the § 4 step 2 table.
   - If fix not possible → Ask user: `Skip CI` | `Retry` | `Abort`

3. **Max 2 ci-fix cycles** per PR submission.

4. **After max cycles** → § 6 with note: "CI failing, may need manual intervention"

---

## 6. Merge Gates and Standalone Summary

### 6.1 Merge Gates

A PR merges on exactly four gates — all deterministic. Bot-SPECIFIC signals (emoji reactions, sticky-comment prose, checklist text) are never parsed for gating; the approval gate reads only GitHub-native review verdicts, from any reviewer — human or bot.

| # | Gate | Check |
|---|------|-------|
| 1 | Internal review verdict recorded | Managed: `review-pr.md` completed with verdict `pass` before this workflow. Standalone: workflow state `json_paths` is non-empty |
| 2 | CI green | § 4 result is `status=complete`, `verdict=pass` (equivalently: `gh pr checks [PR_NUMBER]` shows all checks passing) |
| 3 | Zero unresolved review comments | `pr-threads` reports `unresolved_count == 0` AND every actionable PR-level bot comment has a reply (tracked in `pr_comment_review.replied`) |
| 4 | GitHub-native approval verdict | `reviewDecision == "APPROVED"`, or — when `reviewDecision` is empty (no required-review protection) — at least one reviewer whose latest review is APPROVED and none whose latest review is CHANGES_REQUESTED |

1. **Gate 1** — standalone only (managed callers reach this workflow only after `review-pr.md` passed):
   ```bash
   .agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '{json_paths: (.json_paths // []), cycles: (.cycles // 0)}'
   ```
   If `json_paths` is empty, no internal review is recorded: report the unmet gate and recommend `orch review-pr [PR_NUMBER]` before merge.

2. **Gate 2** — from § 4: met when the final CI result was `status=complete`, `verdict=pass`.

3. **Gate 3**:
   ```bash
   .agents/skills/github/scripts/github.sh pr-threads [PR_NUMBER] --unresolved
   ```
   Read `.unresolved_count` from the JSON output.

   | `unresolved_count` | Action |
   |--------------------|--------|
   | `0` | Gate met |
   | `> 0` | → step 4's triage row — the approval wait loop owns comment routing from here |

4. **Gate 4 — approval wait loop.** Poll for a GitHub-native approval verdict and new review comments together:
   ```bash
   .agents/skills/orch/scripts/approval-wait [PR_NUMBER] 30 900 --json
   ```
   The result is a JSON object: `status` (`approved`/`changes_requested`/`comments`/`timeout`/`error`) plus `review_decision`, `approvals`, `changes_requested`, and `unresolved_count`. approval-wait always emits it — no silent completion. Detection uses `gh pr view --json reviewDecision,latestReviews` (either signal: the branch-protection aggregate, or the latest-review-per-reviewer fallback when no protection is configured); any reviewer counts, human or bot.

   Route on `status`:

   | `status` | Action |
   |----------|--------|
   | `approved`, `unresolved_count == 0` | Gates 3 and 4 met → step 5 |
   | `approved`, `unresolved_count > 0` | Approval recorded; run the triage pass below to clear gate 3, then re-run the gate 3 command once — do not re-wait for approval |
   | `changes_requested` or `comments` | New review feedback: run the triage pass below, then restart step 4 |
   | `timeout` | No approval verdict after 15 min → Ask user: "No approval verdict on PR #[PR_NUMBER] after [ELAPSED] min" — `Force merge` \| `Keep waiting` \| `Stop here` |
   | `error` | Re-run step 4 once; if it repeats, report the error and ask user: `Keep waiting` \| `Stop here` |

   **Triage pass** (bounded by `pr_comment_review.iterations`, max 5 — read it before each pass; at the cap, present the remaining feedback and ask user: `Triage again` \| `Force merge` \| `Stop here`):
   - `⤵ workflows/review-pr-comments.md [PR_NUMBER] § 1-8 → § 6.1 step 4` with managed context — fixes real findings, replies to and resolves every comment. Pushed fix commits re-trigger CI and reviewer re-review automatically.
   - If the pass pushed new commits, re-run § 4 to re-verify gate 2 before restarting the approval wait.

   **User choices on `timeout`:**
   - `Keep waiting` → restart step 4.
   - `Force merge` → record the override, then treat gate 4 as met (gates 1-3 must still hold):
     ```bash
     .agents/skills/orch/scripts/workflow-state set [ISSUE_ID] pr_approval.forced true
     ```
   - `Stop here` → § 6.2 with gate 4 unmet (`MERGE_READY = false`); the PR stays open awaiting approval.

5. **Record results**: `MERGE_READY = true` only when all four gates are met (gate 4 by verdict or recorded force).

### 6.2 Standalone Summary

**If managed**: Skip → § 7

**If standalone**:

1. **Reconcile fixes**:

   Run Workflow: `⤵ workflows/fix-reconcile.md § 1-9 → § 6.2 step 2` with context:
   - `issue_id`: [ISSUE_ID]
   - `pr_number`: [PR_NUMBER]

2. **Post summary** — skip if no fixes AND no issues created. Write to a file first (same backtick hazard as PR body):
   ```bash
   mkdir -p [WORKTREE_PATH]/tmp
   .agents/skills/orch/scripts/git-context timestamp compact
   # Write SUMMARY_CONTENT to [WORKTREE_PATH]/tmp/submit-summary-[ISSUE_ID]-[TIMESTAMP_FROM_PREVIOUS_COMMAND].md with the harness file-write/edit tool or apply_patch.
   .agents/skills/github/scripts/github.sh post-comment [PR_NUMBER] --body-file "$SUMMARY_FILE"
   ```
   Use the summary file path as `SUMMARY_FILE`.

   Linear only — GitHub items get linkage via `Closes #N` in the PR body:

   ```bash
   .agents/skills/linear/scripts/linear.sh comments create [ISSUE_ID] --body-file "$SUMMARY_FILE"
   ```

   **Summary content template** (omit empty sections):

   ```markdown
   ## Recommendations Processed

   ### Fixed in PR
   - [SOURCE]: [ITEM] — [SHA]

   ### Issues Created
   - [ISSUE_ID] - [TITLE] — [PROJECT]

   ### Skipped
   - [SOURCE]: [ITEM] — [REASON]
   ```

3. **Output result**:

   <output_format>

   ### ✅ PR SUBMITTED — #[PR_NUMBER]

   | Metric | Value |
   |--------|-------|
   | PR | #[PR_NUMBER] |
   | CI | ✅ passing / ❌ failing |
   | Approval | ✅ approved / ⏳ pending / forced |
   | Unresolved threads | [N] |
   | Local review passes | [N] |
   | Comment iterations | [N] |
   | Fixes applied | [N] |
   | Issues created | [N] |

   </output_format>

4. **Offer merge** — skip unless `MERGE_READY` (§ 6.1):

   → Ask user: `orch merge-pr [PR_NUMBER]` | `Skip`

   | Choice | Action |
   |--------|--------|
   | Merge | `⤵ workflows/merge-pr.md [PR_NUMBER] § 1-8 → end` |
   | Skip | → end |

---

## 7. Return State

**If managed**: Return to the parent workflow's next section with the § 6.1 gate results (`MERGE_READY`, approval status, unresolved thread count, CI verdict).

**If standalone**: Session complete — PR submitted. Summary presented in § 6.2.
