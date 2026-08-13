# CI Fix Workflow

Analyze CI failures and route them to the right agent.

| Command | Flow |
|---------|------|
| `ci-fix` \| `ci-fix [PR_NUMBER]` | § 1 → § 2 → § 3 → § 5 |
| `ci-fix queue` | § 1 → § 2 → § 4 → § 5 |

## 1. Identify Failures

```bash
.agents/skills/github/scripts/github.sh pr-list-failing
```

`ci-fix queue` uses `pr-list-failing --all`. With several failures and no argument, present them and ask which to fix:

<output_format>

### CI FAILURES

| # | PR | Title | Job | Error |
|---|-----|-------|-----|-------|
| 1 | #42 | Add user auth | build | lint |

</output_format>

## 2. Fetch Error Details

```bash
.agents/skills/github/scripts/github.sh ci-logs [PR_NUMBER]
```

Returns the job name, an auto-classified error type (fmt/lint/test/build), the run id, and the last 100 lines of failure output.

## 3. Classify And Route

Formatting, obvious lint, and a missing import are fixed directly; a test failure, a build error, or non-obvious lint is delegated.

### 3.1 Direct Fixes

Resolve the worktree (`github.sh pr-issue [PR_NUMBER] --format=text`, then `worktree exists`/`worktree path`, creating with `--pr [PR_NUMBER]` when missing), apply the fix, then:

```bash
git -C "[WORKTREE_PATH]" commit -am "fix([ISSUE_ID]): Resolve CI failure ([ERROR_TYPE])"
git -C "[WORKTREE_PATH]" push
```

→ § 4 for a merge queue, otherwise § 5.

### 3.2 Delegated Fixes

Infer the agent from the component paths or issue labels. A test failure in concurrent code that passes locally is a flaky-test candidate — check the project's testing conventions for the usual patterns (missing barriers, iteration-based waits, static mutable state) before treating it as a real regression.

Stamp the round as separate tool calls immediately before delegating, and arm the watchdog per [SKILL.md § Round Closure](../SKILL.md#round-closure):

```bash
.agents/skills/orch/scripts/workflow-state set-now [ISSUE_ID] dev_delegated_at
```
```bash
.agents/skills/orch/scripts/workflow-state new-round-id [ISSUE_ID] dev_round_id
```

This agent pushes its fix directly and writes **no** dev-return artifact, so the round-mode check for this fresh token is *expected* to report `ok == false`. Minting a fresh token anyway is exactly what guarantees a leftover artifact from an earlier round — still on disk under the previous token — can never be mis-accepted here. Accept this round on the agent's return message plus the pushed fix commit, and on a genuinely absent return follow the escalation ladder.

<delegation_format>
CI failure on PR #[PR_NUMBER] ([BRANCH_NAME]).

Job: [job name]
Error type: [fmt/lint/test/build]

Error output:
[truncated error logs]

Worktree: [WORKTREE_PATH]

1. Analyze the error; if it is a test failure in concurrent code, check for flaky-test patterns first.
2. Fix the issue.
3. Run the project's validation command.
4. If the target failure is fixed but OTHER failures remain: still commit, and note them in the message.
5. Commit: "fix([ISSUE_ID]): [DESCRIPTION]", appending `[validate: FAILING_CHECK]` when other failures remain.
6. Push to the branch.

Report: what was fixed, the validate status, and any unrelated failures.
</delegation_format>

→ § 4 for a merge queue, otherwise § 5.

## 4. Merge Queue Integration

For `ci-fix queue`, the failure is in a draft merge-group PR that may need dequeuing while it is fixed.

```bash
gh pr view [DRAFT_PR] --json commits --jq '.commits[].oid'
```

Cross-reference those commits with the original PRs to identify which file failed, which commit introduced it, and which PR that commit belongs to. A single identifiable PR routes to that PR's agent; a genuine cross-PR integration issue routes to the architecture reviewer for analysis; an unclear source goes to the user.

For an integration issue, create a worktree from the draft branch (`worktree create [ISSUE_ID] "[DRAFT_BRANCH]" --pr [DRAFT_PR_NUMBER]`) and delegate analysis:

<delegation_format>
Merge queue CI failure — integration issue across stacked PRs.

Draft PR: #[PR_NUMBER]
Worktree: [WORKTREE_PATH]
Stack: [PRs in the stack with their domains]

Error output:
[error logs]

1. Analyze which PRs interact to cause this failure.
2. Identify the root cause.
3. Recommend which PR(s) need changes.
4. If it is fixable, give specific fix instructions.

Report findings for a user decision.
</delegation_format>

## 5. Verify

A fix push moved the head, so the review gate is re-confirmed at the new head **before** CI is waited on — the same review-before-CI ordering as `submit-pr.md`, applied universally with no repo detection. On approval-gated repos CI for the new head starts only after exact-head review evidence exists, so waiting on CI first would deadlock or watch an intentionally red gate run; on always-on repos CI has been running since the push and the re-confirmation costs nothing.

```bash
.agents/skills/orch/scripts/approval-wait --resolve-mode
```

`off` skips to the CI wait. Otherwise run the short exact-head re-confirmation:

```bash
.agents/skills/orch/scripts/approval-wait [PR_NUMBER] 15 300 --json --mode [GATE_MODE]
```

- `approved` / `reviewed` / `proceeded` → wait for CI. `proceeded` is the reviewer-down degrade: this workflow returns it rather than persisting it, so the caller records it under its own gate bookkeeping and ci-fix stays correct when invoked standalone or from merge-pr, neither of which keeps workflow state. The proceed is a LOCAL verdict — orch posts no status, so on a repo whose CI gates on review evidence the CI wait below may sit against a gate that will not converge; that posture is the engine's to govern, not orch's.
- `comments` / `changes_requested` → new feedback on the fix push. Managed: return it to the caller's review-gate handling. Standalone: run that triage pass, then re-run this step.
- `timeout` → no exact-head evidence yet. On repos whose CI is gated on review evidence, CI cannot have started, so a missing or red run here is not a fix failure. Report the unconfirmed gate, then re-run this step once or hand back.

```bash
.agents/skills/orch/scripts/ci-wait [PR_NUMBER]
```

**Linear only** — post the short status to the tracker; a GitHub item's PR conversation already records the fix:

```bash
.agents/skills/linear/scripts/linear.sh comments create "$ISSUE" --body "CI Fix: [ERROR_TYPE] → [FIX_DESCRIPTION]"
```

<output_format>

### ✅ CI FIXED — PR #[N]

| Field | Value |
|-------|-------|
| Error | [ERROR_TYPE] |
| Fix | [FIX_DESCRIPTION] |
| Status | ✅ CI passing |

</output_format>

Still failing:

<output_format>

### ⚠️ CI STILL FAILING — PR #[N]

| Field | Value |
|-------|-------|
| Original | [ERROR_TYPE] ✅ (fixed) |
| New failure | [NEW_ERROR_TYPE] |
| Next | Run `orch ci-fix [PR_NUMBER]` again |

</output_format>

## 6. Return

**Managed**: return to the parent workflow's next section. **Standalone**: session complete.
