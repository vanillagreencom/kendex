# CI Fix Workflow

Analyze CI failures and route them to the right agent.

| Command | Flow |
|---------|------|
| `ci-fix` \| `ci-fix [PR_NUMBER]` | § 1 → § 2 → § 3 → § 5 |
| `ci-fix queue` | § 1 → § 2 → § 4 → § 5 |

**Caller context** (via `⤵`): managed `lifecycle` uses the caller's `issue_id`; standalone is the default.

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

Standalone only: use the extracted issue as `[STATE_KEY]`, or
`pr-[PR_NUMBER]` when empty. Run `init` only when `exists` is false:

```bash
.agents/skills/github/scripts/github.sh pr-issue [PR_NUMBER] --format=text
env -u GH_REPO -u GITHUB_REPOSITORY gh pr view [PR_NUMBER] --json headRefName --jq .headRefName
.agents/skills/orch/scripts/workflow-state exists --json [STATE_KEY]
.agents/skills/orch/scripts/workflow-state init [STATE_KEY] --branch [PR_BRANCH]
.agents/skills/orch/scripts/workflow-state update [STATE_KEY] '.post_pr_stop = null'
```

## 2. Fetch Error Details

```bash
.agents/skills/github/scripts/github.sh ci-logs [PR_NUMBER]
```

## 3. Classify And Route

Formatting, obvious lint, and a missing import are fixed directly; a test failure, a build error, or non-obvious lint is delegated.

Resolve the decision mode once for this post-PR workflow. Named stops use [SKILL.md § The Cycle](../SKILL.md#the-cycle).

```bash
.agents/skills/orch/scripts/orch-env ORCH_DECISION_MODE auto-recommended
```

### 3.1 Direct Fixes

Resolve the worktree (`github.sh pr-issue [PR_NUMBER] --format=text`, then `worktree exists`/`worktree path`, creating with `--pr [PR_NUMBER]` when missing) as `[DIR]`; `WORKTREE_PATH` is `git-context repo-root "[DIR]"`. Apply the fix, then:

```bash
git -C "[WORKTREE_PATH]" commit -am "fix([ISSUE_ID]): Resolve CI failure ([ERROR_TYPE])"
git -C "[WORKTREE_PATH]" push
```

→ § 4 for a merge queue, otherwise § 5.

### 3.2 Delegated Fixes

Infer the agent from the component paths or issue labels. A test failure in concurrent code that passes locally is a flaky-test candidate — check the project's testing conventions (missing barriers, iteration-based waits, static mutable state) before treating it as a real regression.

Stamp the round as separate tool calls immediately before delegating, and arm the watchdog per [SKILL.md § Round Closure](../SKILL.md#round-closure):

```bash
.agents/skills/orch/scripts/workflow-state set-now [ISSUE_ID] dev_delegated_at
```
```bash
.agents/skills/orch/scripts/workflow-state new-round-id [ISSUE_ID] dev_round_id
```

Fill `Worktree:` from `git -C "[DIR]" rev-parse --show-toplevel`.

This agent pushes its fix directly and writes **no** dev-return artifact; the round-mode check for this token reports `ok == false`, which is expected. Accept this round on the agent's return message plus the pushed fix commit; on an absent return follow the escalation ladder.

<delegation_format>
CI failure on PR #[PR_NUMBER] ([BRANCH_NAME]).

Job: [job name]
Error type: [fmt/lint/test/build]

Error output:
[truncated error logs]

Worktree: [WORKTREE_PATH]

1. Analyze the error; if it is a test failure in concurrent code, check for flaky-test patterns first.
2. Fix the issue, editing files under `[WORKTREE_PATH]` by absolute path.
3. Run the project's validation command from `[WORKTREE_PATH]`.
4. If the target failure is fixed but OTHER failures remain: still commit, and note them in the message.
5. Stage and commit: `git -C [WORKTREE_PATH] add -A`, then `git -C [WORKTREE_PATH] commit -m "fix([ISSUE_ID]): [DESCRIPTION]"`, appending `[validate: FAILING_CHECK]` to the message when other failures remain.
6. Push: `git -C [WORKTREE_PATH] push`.

Report: what was fixed, the validate status, and any unrelated failures.
</delegation_format>

→ § 4 for a merge queue, otherwise § 5.

## 4. Merge Queue Integration

For `ci-fix queue`, the failure is in a draft merge-group PR that may need dequeuing while it is fixed.

```bash
gh pr view [DRAFT_PR] --json commits --jq '.commits[].oid'
```

Cross-reference those commits with the original PRs to identify which file failed, which commit introduced it, and which PR that commit belongs to. A single identifiable PR routes to that PR's agent; a genuine cross-PR integration issue routes to the architecture reviewer for analysis. When the source stays unclear after that analysis, `auto-recommended` records `ci-source-unclear`; `ask` presents the evidence to the user.

For an integration issue, create a worktree from the draft branch (`worktree create [ISSUE_ID] "[DRAFT_BRANCH]" --pr [DRAFT_PR_NUMBER]`) and delegate analysis.

Fill `Worktree:` from `git -C "[DIR]" rev-parse --show-toplevel`.
`[DIR]` is the worktree just created from the draft branch.

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

Re-confirm the review gate at the new head **before** waiting on CI, on every repo with no repo detection.

```bash
.agents/skills/orch/scripts/approval-wait --resolve-mode
```

`off` skips to the CI wait. Otherwise run the short exact-head re-confirmation:

```bash
.agents/skills/orch/scripts/approval-wait [PR_NUMBER] 15 300 --json --mode [GATE_MODE]
```

- `approved` / `reviewed` / `proceeded` → wait for CI. `proceeded` is returned to the caller, not persisted here; it is a LOCAL verdict — orch posts no status.
- `comments` / `changes_requested` → new feedback on the fix push. Managed: return it to the caller's review-gate handling. Standalone: run that triage pass, then re-run this step.
- `timeout` → no exact-head evidence yet; a missing or red CI run here is not a fix failure. Re-run this step once. If it repeats, `auto-recommended` records `ci-gate-unconfirmed`; under `ask`, hand back the unconfirmed gate.

```bash
.agents/skills/orch/scripts/ci-wait [PR_NUMBER]
```

A passing or unconfigured CI result clears the head-bound standalone budget:

```bash
.agents/skills/orch/scripts/workflow-state update [STATE_KEY] '.post_pr_budgets.ci_fix = null'
```

**Linear only** — post the short status to the tracker:

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

Managed failures return to the caller, which owns `CI_FIX_MAX_CYCLES`.
Standalone `auto-recommended` spends a cycle of the PR's budget. The count runs
across the heads these cycles push, because each cycle pushes its own fix; only
the passing-CI clear in this section resets it:

```bash
env -u GH_REPO -u GITHUB_REPOSITORY gh pr view [PR_NUMBER] --json headRefOid --jq .headRefOid
.agents/skills/orch/scripts/workflow-state head-budget take [STATE_KEY] ci-fix [CI_HEAD]
```

`continue` reruns § 1. `at-cap` records and returns `ci-fix-cap`:

```bash
.agents/skills/orch/scripts/workflow-state post-pr-stop record [STATE_KEY] ci-fix-cap ci "[REMAINING_CHECKS_AND_ATTEMPTS]" [WORKTREE_PATH]/tmp/post-pr-stop-[STATE_KEY].md
.agents/skills/github/scripts/github.sh post-comment [PR_NUMBER] --body-file [WORKTREE_PATH]/tmp/post-pr-stop-[STATE_KEY].md
```

Under `ask`, present `Run ci-fix again` | `Stop`; continuation clears the stop.

## 6. Return

**Managed**: return to the parent workflow's next section. **Standalone**: return `.post_pr_stop` when present; otherwise the CI-fix session is complete.
