# CI Fix Workflow

Analyze CI failures and route to appropriate agents for fixing.

## Inputs

| Command | Flow |
|---------|------|
| `ci-fix` | § 1.1 → § 2 → § 3 → § 5 |
| `ci-fix [PR_NUMBER]` | § 1.1 → § 2 → § 3 → § 5 |
| `ci-fix queue` | § 1.2 → § 2 → § 4 → § 5 |

## 1. Identify Failures

### 1.1 Individual PR Flow

```bash
# If PR number provided, use it; otherwise list user's failing PRs
.agents/skills/github/scripts/github.sh pr-list-failing
```

If multiple failures and no argument, present:

<output_format>

### CI FAILURES

| # | PR | Title | Job | Error |
|---|-----|-------|-----|-------|
| 1 | #42 | Add user auth | build | lint |
| 2 | #43 | API endpoint | build | test |
</output_format>

→ Ask user: `Fix #1`, `Fix #2`, `Fix all`

**→ Jump to § 2**

### 1.2 Merge Queue Flow (if using GitHub merge queue)

```bash
.agents/skills/github/scripts/github.sh pr-list-failing --all
```

**→ Jump to § 2**

## 2. Fetch Error Details

```bash
.agents/skills/github/scripts/github.sh ci-logs [PR_NUMBER]
```

Returns: job name, error type (fmt/lint/test/build, auto-classified), run ID, last 100 lines of failure output.

## 3. Classify & Route

Classify error and route to appropriate flow:

| Error Type | Flow |
|------------|------|
| Formatting, obvious lint, missing import | § 3.1 |
| Test failure, build error, non-obvious lint | § 3.2 |

### 3.1 Handle Simple Failures

| Error Type | Fix |
|------------|-----|
| Formatting check | Run formatter |
| Lint warning (obvious) | Apply suggested fix |
| Missing import | Add import |

1. **Get or create worktree**:
   ```bash
   .agents/skills/github/scripts/github.sh pr-issue [PR_NUMBER] --format=text
   .agents/skills/worktree/scripts/worktree exists [ISSUE_FROM_PREVIOUS_COMMAND]
   .agents/skills/worktree/scripts/worktree path [ISSUE_FROM_PREVIOUS_COMMAND]
   ```
   Use the first output as `ISSUE`. If the worktree is missing, run `.agents/skills/worktree/scripts/worktree create [ISSUE] --pr [PR_NUMBER]`; otherwise use the path output as `WT_PATH`.

2. **Apply fix**.

3. **Commit**: `git -C "[WORKTREE_PATH]" commit -am "fix([ISSUE_ID]): Resolve CI failure ([ERROR_TYPE])"`

4. **Push**: `git -C "[WORKTREE_PATH]" push`

5. **Report**: "Fixed [TYPE] on PR #[PR_NUMBER], CI rerunning"

**→ Jump to § 4** (if merge queue) or **§ 5** (otherwise)

### 3.2 Delegate Complex Failures

| Error Type | Agent |
|------------|-------|
| Test failure | [AGENT_TYPE] |
| Non-obvious lint | [AGENT_TYPE] |
| Build error | [AGENT_TYPE] |

Infer agent type from component paths or issue labels.

**Flaky test detection**: If test failure involves concurrent/threading code and passes locally, check project testing conventions for common patterns (missing barriers, iteration-based waits, static mutable state).

**Detect team context**:

```bash
.agents/skills/orch/scripts/workflow-state exists --json [ISSUE_ID]
```

If `.exists` is `true`, read `.team_name`:

```bash
.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] .team_name
```

**Stamp the round, then delegate** to `[AGENT]`. Like every dev/QA delegation, this one MUST mint a fresh `dev_round_id` immediately before delegating (SKILL § Wait for Agent Return invariant) — even though this agent writes **no** dev-return artifact (it pushes its fix directly, not via `dev-fix.md`). Minting a fresh token is exactly what guarantees a leftover artifact from an earlier dev-implement/dev-fix round (still on disk at its own round-scoped path, and still referenced by the *previous* `dev_round_id`) can never be mis-accepted for this CI fix by the idle-recovery rule: the round-mode check now looks for THIS round's token, which no prior artifact carries. `dev_delegated_at` stays as the watchdog deadline. Run each as its own tool call; fill placeholders, omit empty lines/sections.

```bash
.agents/skills/orch/scripts/workflow-state set-now [ISSUE_ID] dev_delegated_at
```
```bash
.agents/skills/orch/scripts/workflow-state new-round-id [ISSUE_ID] dev_round_id
```

<delegation_format>
CI failure on PR #[PR_NUMBER] ([BRANCH_NAME]).

Job: [job name]
Error type: [fmt/lint/test/build]

Error output:
[truncated error logs]

Worktree: [WORKTREE_PATH]

1. Analyze the error (if test failure in concurrent code, check for flaky test patterns)
2. Fix the issue
3. Run the project's validation command
4. If target issue fixed but OTHER failures exist: still commit, note in message
5. Commit: "fix([ISSUE_ID]): [DESCRIPTION]" (append `[validate: FAILING_CHECK]` if other failures)
6. Push to branch

Report: what was fixed, validate status, any unrelated failures.
</delegation_format>

**Wait for completion.** This agent writes **no** dev-return artifact, so the round-mode `dev-artifact-check` for THIS fresh `dev_round_id` is *expected* to report `ok == false` (`missing` — no artifact exists at this round's path). That is the normal path: accept the completion from the agent's return message (what was fixed, validate status) plus the pushed fix commit, and on a genuinely absent return follow the [SKILL escalation](../SKILL.md#wait-for-agent-return-before-acting) ladder. The fresh round token (not the check itself) is the fail-closed guarantee — a prior round's leftover artifact carries the *previous* token, so it can never satisfy this round's check:

```bash
.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '.dev_round_id // empty'
```
```bash
.agents/skills/orch/scripts/dev-artifact-check --worktree [WORKTREE_PATH] --issue [ISSUE_ID] --round-id [DEV_ROUND_ID_FROM_PREVIOUS_COMMAND]
```

**→ Jump to § 4** (if merge queue) or **§ 5** (otherwise)

## 4. Handle Merge Queue Integration (if `queue` argument)

For `queue` argument (merge queue failures). May need to dequeue PR while fixing.

1. **Get draft PR commits**:
   ```bash
   gh pr view [DRAFT_PR] --json commits --jq '.commits[].oid'
   ```

2. **Cross-reference with original PRs** to identify:
   - Which file(s) failed
   - Which commit introduced the issue
   - Which original PR that commit belongs to

3. **Route by scenario**:

   | Scenario | Action |
   |----------|--------|
   | Single PR identifiable | Route to that PR's agent |
   | Integration issue (cross-PR) | Route to architecture review agent for analysis |
   | Unclear source | Present to user for decision |

4. **Create worktree from draft branch** (integration issues only):
   ```bash
   .agents/skills/worktree/scripts/worktree create [ISSUE_ID] "[DRAFT_BRANCH]" --pr [DRAFT_PR_NUMBER]
   ```
   Use the output as `WT_PATH`.

5. **Delegate to architecture review agent**: Fill placeholders, omit empty lines/sections.

<delegation_format>
Merge queue CI failure - integration issue across stacked PRs.

Draft PR: #[PR_NUMBER]
Worktree: [WORKTREE_PATH]
Stack: [list PRs in stack with domains]

Error output:
[error logs]

1. Analyze which PRs interact to cause this failure
2. Identify the root cause
3. Recommend which PR(s) need changes
4. If fixable, provide specific fix instructions

Report findings for user decision.
</delegation_format>

## 5. Verify

A fix push moved the PR head, so the review gate is re-confirmed at the new head **before** CI is waited on — the same review-before-CI ordering as `submit-pr.md` § 4 → § 5, applied universally with no repo detection (vstack#726). On approval-gated repos CI for the new head starts only after exact-head review evidence exists, so waiting on CI first would deadlock or watch an intentionally red gate run; on always-on repos CI has been running since the push, so the short re-confirmation costs nothing.

1. **Re-confirm the review gate at the new head** — resolve the mode through the existing gate vocabulary, never by detection:
   ```bash
   .agents/skills/orch/scripts/approval-wait --resolve-mode
   ```
   The printed value is `GATE_MODE`. Skip to step 2 when it is `off`. Otherwise run the short exact-head re-confirmation:
   ```bash
   .agents/skills/orch/scripts/approval-wait [PR_NUMBER] 15 300 --json --mode [GATE_MODE]
   ```
   - `approved` / `reviewed` / `proceeded` → step 2. (`proceeded` is the `PR_REVIEW_ON_TIMEOUT=proceed` reviewer-down degrade — the re-confirm deadline passed with zero unresolved threads and no reviewer evidence; treat it as a met gate. ci-fix returns this result rather than persisting it — the caller records the § 4 result, a reviewer-down proceed included, per its own gate-4 bookkeeping, so ci-fix stays correct when invoked standalone or from `merge-pr`, which keep no workflow-state.) **Exception — `outage_marker: "failed"` in the JSON** (the repo set `PR_REVIEW_OUTAGE_CONTEXT` but orch's status POST was rejected, e.g. no `statuses: write`): the repo-side CI gate got no outage signal and cannot recover, so do NOT fall into step 2's ci-wait against it — surface the failed marker and re-run this step once, or stop and hand back. `outage_marker: "posted"` (or absent) proceeds to step 2 normally.
   - `comments` / `changes_requested` → new review feedback on the fix push. Managed: return it to the caller's review-gate handling (`submit-pr.md` § 4 step 1 triage pass). Standalone: run that triage pass, then re-run this step.
   - `timeout` → no exact-head review evidence yet (only when `PR_REVIEW_ON_TIMEOUT` is `block`/unset — `proceed` returns `proceeded` above). On repos whose CI is gated on review evidence, CI cannot have started — a missing or red gate run here is not a fix failure. Report the unconfirmed gate, then re-run this step once or stop and hand back.

2. **Wait for CI**:
   ```bash
   .agents/skills/orch/scripts/ci-wait [PR_NUMBER]
   ```

3. **Post to issue tracker** — **Linear only** (GitHub items: the PR conversation already records the fix):
   ```bash
   .agents/skills/github/scripts/github.sh pr-issue [PR_NUMBER] --format=text
   ```
   Use the output as `ISSUE`.

   If `ISSUE` is non-empty, determine tracker:

   ```bash
   .agents/skills/orch/scripts/tracker-for-issue "$ISSUE"
   ```
   Use the output as `TRACKER`.

   If `TRACKER` is `linear`, post the short status:

   ```bash
   .agents/skills/linear/scripts/linear.sh comments create "$ISSUE" --body "CI Fix: [ERROR_TYPE] → [FIX_DESCRIPTION]"
   ```

## 6. Present Results

| CI Result | Output |
|-----------|--------|
| ✅ Pass | Success format below |
| ❌ Fail | Failure format below |

**If CI passes:**

<output_format>

### ✅ CI FIXED — PR #42

| Field | Value |
|-------|-------|
| Error | [ERROR_TYPE] |
| Fix | [FIX_DESCRIPTION] |
| Status | ✅ CI passing |
</output_format>

**If CI still failing:**

<output_format>

### ⚠️ CI STILL FAILING — PR #42

| Field | Value |
|-------|-------|
| Original | [ERROR_TYPE] ✅ (fixed) |
| New failure | [NEW_ERROR_TYPE] |
| Next | Run `orch ci-fix [PR_NUMBER]` again |
</output_format>

## 7. Return State

**If managed**: Return to the parent workflow's next section.

**If standalone**: Session complete.
