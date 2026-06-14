# Submit PR Workflow

Push changes, create/update PR, handle bot review, triage PR comments, and trigger CI.

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

## 1. Push and Submit PR

1. **Preflight committed work**:
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

2. **Push branch**:
   ```bash
   .agents/skills/worktree/scripts/worktree push "[WORKTREE_PATH]" --set-upstream
   ```

3. **Check for existing PR**:
   ```bash
   .agents/skills/orch/scripts/pr-view-json "[WORKTREE_PATH]" --json number,state
   ```
   Use the JSON output as `PR_VIEW`. If `status` is `no_pr`, create a new PR in step 5. For auth, token, timeout, or unparseable errors, stop and report the JSON error.

4. **Build PR body** from current workflow state using the template below (omit empty sections).

   **PR body MUST be written to a file** — inline bodies with backticks or fenced code blocks corrupt under shell command substitution. Prefer your harness's file-write tool:

   ```bash
   mkdir -p [WORKTREE_PATH]/tmp
   .agents/skills/orch/scripts/git-context timestamp compact
   ```
   Write the PR body to `[WORKTREE_PATH]/tmp/pr-body-[ISSUE_ID]-[TIMESTAMP_FROM_PREVIOUS_COMMAND].md` and use that path as `BODY_FILE`.

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
   - **Created Issues**: Include if issues created during review.
   - **QA Metrics**: Include if QA agents ran. Format is project-configurable based on which QA agent types are active.

5. **Create or update PR**:

   **No existing PR** → create with `defer-ci` label. Always pass the body via `--body-file`:
   ```bash
   # Linear
   .agents/skills/linear/scripts/linear.sh cache issues get [ISSUE_ID]
   # Read `.title` from the JSON output and use it as ISSUE_TITLE.
   # GitHub
   gh issue view [N] --json title --jq '.title'
   # Use the output as ISSUE_TITLE.

   .agents/skills/github/scripts/github.sh -C "[WORKTREE_PATH]" pr-create \
     --title "[PREFIX]([ISSUE_ID]): $ISSUE_TITLE" \
     --body-file "$BODY_FILE" \
     --label defer-ci
   ```

   **Existing PR** (`$PR_NUM` set) → update body and ensure label:
   ```bash
   .agents/skills/github/scripts/github.sh -C "[WORKTREE_PATH]" pr-edit-body "$PR_NUM" --body-file "$BODY_FILE"
   .agents/skills/github/scripts/github.sh -C "[WORKTREE_PATH]" label-add "$PR_NUM" defer-ci --reason "queue for bot review before CI"
   ```
   If either command fails because the PR no longer exists or the label is already present, report the failure and continue only when the state is understood.

---

## 2. Wait for Bot Review

Wait for bot review to complete (sticky comment with verdict). CI is deferred via label.

```bash
.agents/skills/orch/scripts/bot-review-wait [PR_NUMBER] 15 600 --json --reviewers "$BOT_REVIEWERS"
```
Use the returned JSON fields as `BOT_STATUS`, `BOT_VERDICT`, and `PENDING_REVIEWERS`.

Waits for all configured bot reviewers (`$BOT_REVIEWERS`). Auto-detects if not configured. Max wait 600s. Understands Claude-style (formal review + sticky verdict comment) and Codex-style (reactions + inline threads) signaling. Unrelated automation comments do not block. `status=complete` only when no reviewer is pending. If sticky prose is stale but GitHub reports `reviewDecision=APPROVED`, any configured `BOT_CHECK_NAME` has passed, and no unresolved review threads remain, `bot-review-wait` returns approved with `pr_review_decision:approved` and `pr_threads:clear` signals without waiting on the stale checklist. To ignore a reviewer: `--skip "bot-login"` or `BOT_SKIPPED_REVIEWERS`.

**Route result**:

| `status` | `verdict` | Action |
|----------|-----------|--------|
| `complete` | `approved` or `changes` | → § 3 |
| `timeout` | `approved` or `changes` | → § 3 (terminal verdict, safe) |
| `timeout` | `pending` | Show `pending_reviewers`; extended poll below, then ask user `Wait` \| `Skip pending bot` \| `Abort` |
| `checklist_timeout` | `approved` or `changes` | Ask user (see below) |
| `no_reviewers` | `pending` | No bot signal at all — ask user `Wait` \| `Proceed without bot review` |

**`checklist_timeout` with terminal verdict** — the bot submitted its review but is still posting inline threads. Prompt the user:

> Ask user: "Bot review verdict is **[BOT_VERDICT]** but it is still posting inline threads (checklist items unchecked). Options:"
> - **Wait 5 min** — poll again for up to 300s, then re-route
> - **Proceed** — skip remaining threads and move to comment triage now (may miss late threads)

```bash
# "Wait 5 min" path: extend checklist wait
.agents/skills/orch/scripts/bot-review-wait [PR_NUMBER] 30 300 --json --reviewers "$BOT_REVIEWERS"
```
Use the returned JSON status and pending reviewer fields to re-route. If it still reports checklist timeout or pending reviewers, ask the user `Wait` | `Skip pending bot` | `Abort`; otherwise continue to § 3.

**Extended poll** (timeout + pending only):
```bash
# Re-run multi-reviewer wait every 30s for up to 300s more.
BOT_WAIT_ARGS=([PR_NUMBER] 30 300 --json)
if [[ -n "${BOT_REVIEWERS:-}" ]]; then
  BOT_WAIT_ARGS+=(--reviewers "$BOT_REVIEWERS")
fi
if [[ -n "${BOT_SKIPPED_REVIEWERS:-}" ]]; then
  BOT_WAIT_ARGS+=(--skip "$BOT_SKIPPED_REVIEWERS")
fi
.agents/skills/orch/scripts/bot-review-wait "${BOT_WAIT_ARGS[@]}"
# Proceed to § 3 if complete/terminal; otherwise ask with pending reviewers.
```
Use the returned JSON fields as `BOT_STATUS`, `BOT_VERDICT`, and `PENDING_REVIEWERS`.

---

## 3. Comment Triage

### 3.1 Initial Triage

1. **Bot completion pre-check** — ensure all configured/detected bot reviewers have terminal status before triaging:
   ```bash
   BOT_WAIT_ARGS=([PR_NUMBER] 30 180 --json)
   if [[ -n "${BOT_REVIEWERS:-}" ]]; then
     BOT_WAIT_ARGS+=(--reviewers "$BOT_REVIEWERS")
   fi
   if [[ -n "${BOT_SKIPPED_REVIEWERS:-}" ]]; then
     BOT_WAIT_ARGS+=(--skip "$BOT_SKIPPED_REVIEWERS")
   fi
   .agents/skills/orch/scripts/bot-review-wait "${BOT_WAIT_ARGS[@]}"
   # Proceed if complete/terminal; if still pending, include PENDING_REVIEWERS in triage notes.
   ```
   Use the returned JSON fields as `BOT_STATUS`, `BOT_VERDICT`, and `PENDING_REVIEWERS`.

2. **Run Workflow**: `⤵ workflows/review-pr-comments.md [PR_NUMBER] § 1-8 → § 3.1` with context:
   - `lifecycle`: `"managed"`
   - `issue_id`: `[ISSUE_ID]`
   - `worktree`: `[WORKTREE_PATH]`

3. **Update state**:
   ```bash
   # For each fixed item:
   .agents/skills/orch/scripts/workflow-state append [ISSUE_ID] pr_comment_review.fixes '{"description":"[DESC]","location":"[LOC]","commit":"[SHA]","source":"[SOURCE]"}'

   # For each issue created:
   .agents/skills/orch/scripts/workflow-state append [ISSUE_ID] pr_comment_review.issues_created "[CREATED_ISSUE_ID]"

   # For each skipped item:
   .agents/skills/orch/scripts/workflow-state append [ISSUE_ID] pr_comment_review.skipped '{"description":"[DESC]","reason":"[REASON]"}'

   # Increment iteration count
   .agents/skills/orch/scripts/workflow-state increment [ISSUE_ID] pr_comment_review.iterations
   ```

4. **Route**:

   **If issues created** → § 3.3

   **If fixes applied** (no issues) → § 3.2 (re-review loop)

   **If no items fixed** AND no issues created → § 4

### 3.2 Re-Review Loop

After fixes pushed, wait for bot re-review (CI still deferred). Re-run `workflows/review-pr-comments.md` until approved or stable.

1. **Check iteration count**:
   ```bash
   .agents/skills/orch/scripts/workflow-state get [ISSUE_ID] .pr_comment_review.iterations
   # Max 3 iterations
   ```
   Use the output as `ITERATIONS`. If `ITERATIONS >= 3`, go to § 4.

2. **Wait for bot re-review** after fixes pushed:
   ```bash
   # 1. Wait for bot to update review
   .agents/skills/orch/scripts/bot-review-wait [PR_NUMBER]

   # 2. Read baseline from state
   .agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '.pr_review_baseline.last_ts // empty'
   .agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '.pr_review_baseline.last_threads // 0'
   # Use the outputs as LAST_TS and LAST_THREADS.

   # 3. Check status against baseline
   .agents/skills/github/scripts/github.sh pr-review-status [PR_NUMBER] --baseline-ts "$LAST_TS" --baseline-threads "$LAST_THREADS"
   # Save output to tmp/pr_status_[PR_NUMBER].json with the harness file-write tool.
   ```

3. **Route based on status**:

   | `needs_action` | `reason` | Action |
   |----------------|----------|--------|
   | `false` | `no_sticky` | Ask user: `Wait` \| `Skip` |
   | `false` | `no_change` | → § 4 (nothing new) |
   | `false` | `approved_clean` | → § 4 (success) |
   | `true` | `has_threads` | `⤵ workflows/review-pr-comments.md [PR_NUMBER] § 1-8 → § 3.2` with managed context, then update state, repeat |
   | `true` | `verdict_not_approved` | `⤵ workflows/review-pr-comments.md [PR_NUMBER] § 1-8 → § 3.2` with managed context, then update state, repeat |

4. **Update state** after `workflows/review-pr-comments.md` — if no fixes applied → § 4. Otherwise:
   ```bash
   # Increment iteration count
   .agents/skills/orch/scripts/workflow-state increment [ISSUE_ID] pr_comment_review.iterations

   # Add fixes/issues/skipped (same as § 3.1 step 3)

   # Update baseline
   jq -r '.sticky_updated_at' tmp/pr_status_[PR_NUMBER].json
   jq -r '.unresolved_threads' tmp/pr_status_[PR_NUMBER].json
   .agents/skills/orch/scripts/workflow-state set [ISSUE_ID] pr_review_baseline "{\"last_ts\":\"$NEW_TS\",\"last_threads\":$NEW_THREADS}"
   ```
   Use the two `jq` outputs as `NEW_TS` and `NEW_THREADS`.

5. **Max iterations exceeded**: Report to user with status, recommendation, and proceed to § 4.

### 3.3 Implement Created Issues

Sub-issues created during comment triage need implementation before CI.

1. **Check cycle count**:
   ```bash
   .agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '.submit_cycles // 0'
   ```
   Use the output as `SUBMIT_CYCLES`.
   **If** `SUBMIT_CYCLES >= 2` → § 4 with note: "Max re-submit cycles reached, created issues may need manual implementation."

2. **Increment**:
   ```bash
   .agents/skills/orch/scripts/workflow-state increment [ISSUE_ID] submit_cycles
   ```

3. **Implement**: `⤵ workflows/dev-start.md § 1-4 → § 3.3 step 4` with context:
   - `worktree`: [WORKTREE_PATH]
   - `lifecycle`: `"managed"`
   - `issue_id`: [ISSUE_ID]

4. **Review**: `⤵ workflows/review-pr.md § 1-11 → § 3.3 step 5` with context:
   - `worktree`: [WORKTREE_PATH]
   - `lifecycle`: `"managed"`
   - `dev_agent`: from dev-start return
   - `issue_id`: [ISSUE_ID]

5. **Re-submit** → § 1 (push updated code, update PR body with new `Closes` lines, re-trigger bot review)

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

## 4. Trigger CI

All bot review comments resolved (or max iterations). Verify no late-arriving threads, then remove `defer-ci` label to trigger CI.

1. **Thread propagation delay** — bot may still be posting inline threads after sticky verdict:
   ```bash
   # Wait for late-arriving threads (bot posts inline comments after sticky update)
   sleep 15
   .agents/skills/github/scripts/github.sh pr-threads [PR_NUMBER] --unresolved
   # Read `.unresolved_count` from the JSON output and use it as UNRESOLVED.
   # If UNRESOLVED is 0, sleep 15 and run the same command again to double-check.
   .agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '.pr_comment_review.ci_gate_rerouted // false'
   ```
   Use the workflow-state output as `CI_GATE_REROUTED`.

   | `UNRESOLVED` | `CI_GATE_REROUTED` | Action |
   |--------------|---------------------|--------|
   | `0` | any | → step 2 (remove label) |
   | `>0` | `false` | Set `ci_gate_rerouted=true`, → § 3.1 (one triage pass) |
   | `>0` | `true` | Ask user: "Bot posted N unresolved threads after iteration limit" — `Triage now` \| `Skip and trigger CI` \| `Abort` |

   ```bash
   if [ "$UNRESOLVED" -gt 0 ]; then
     if [ "$CI_GATE_REROUTED" = "false" ]; then
       .agents/skills/orch/scripts/workflow-state set [ISSUE_ID] pr_comment_review.ci_gate_rerouted true
       # → § 3.1
     else
       # Ask user with 3 options
     fi
   fi
   ```

2. **Remove label**:
   ```bash
   .agents/skills/github/scripts/github.sh -C "[WORKTREE_PATH]" label-remove [PR_NUMBER] defer-ci --reason "bot review approved; running CI"
   ```

3. **Wait for CI**:
   ```bash
   .agents/skills/orch/scripts/ci-wait [PR_NUMBER]
   ```

4. **Handle CI result**:

   | Result | Action |
   |--------|--------|
   | ✅ Pass | → § 6 |
   | ❌ Fail | → § 5 |

---

## 5. CI Failure Recovery

1. **Run Workflow**: `⤵ workflows/ci-fix.md [PR_NUMBER] § 1-7 → § 5`

2. **After ci-fix returns**:
   - If fix applied → add `defer-ci` label, push, wait for bot re-review (§ 3.2 with iteration check)
   - If fix not possible → Ask user: `Skip CI` | `Retry` | `Abort`

3. **Max 2 ci-fix cycles** per PR submission.

4. **After max cycles** → § 6 with note: "CI failing, may need manual intervention"

---

## 6. Standalone Summary

**If managed**: Skip → § 7

**If standalone**:

1. **Reconcile fixes**:

   Run Workflow: `⤵ workflows/fix-reconcile.md § 1-9 → § 6 step 2` with context:
   - `issue_id`: [ISSUE_ID]
   - `pr_number`: [PR_NUMBER]

2. **Post summary** — skip if no fixes AND no issues created. Write to a file first (same backtick hazard as PR body):
   ```bash
   mkdir -p [WORKTREE_PATH]/tmp
   .agents/skills/orch/scripts/git-context timestamp compact
   # Write SUMMARY_CONTENT to [WORKTREE_PATH]/tmp/submit-summary-[ISSUE_ID]-[TIMESTAMP_FROM_PREVIOUS_COMMAND].md
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
   | Bot | ✅ approved / ⚠️ changes |
   | Comment iterations | [N] |
   | Fixes applied | [N] |
   | Issues created | [N] |

   </output_format>

4. **Offer merge** — skip if CI not passing:

   → Ask user: `orch merge-pr [PR_NUMBER]` | `Skip`

   | Choice | Action |
   |--------|--------|
   | Merge | `⤵ workflows/merge-pr.md [PR_NUMBER] § 1-8 → end` |
   | Skip | → end |

---

## 7. Return State

**If managed**: Return to the parent workflow's next section.

**If standalone**: Session complete — PR submitted. Summary presented in § 6.
