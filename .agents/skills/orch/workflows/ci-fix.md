# CI Fix Workflow

Analyze a pull request's CI failure. Fix it directly or route it to the right agent, then confirm the review gate and CI at the new head.

| Command | Flow |
|---------|------|
| `ci-fix` \| `ci-fix [PR_NUMBER]` | § 1 → § 2 → § 3 → § 5, with § 4 first for a merge-group run |

**Caller context** (via `⤵`): a managed `lifecycle` uses the caller's `issue_id` as the state key. Standalone is the default.

## 1. Identify Failures

```bash
.agents/skills/github/scripts/github.sh pr-list-failing
```

With several failures and no argument, present them and ask which to fix.

Output: [Lane Output](../references/skill-rules.md#lane-output).

<output_format>

### CI FAILURES

| # | PR | Title | Job | Error |
|---|-----|-------|-----|-------|
| 1 | #42 | Add user auth | build | lint |

</output_format>

**Standalone state.** `[STATE_KEY]` is the pull request's issue, or `pr-[PR_NUMBER]` where the pull request names none. Run each command as its own tool call:

```bash
.agents/skills/github/scripts/github.sh pr-issue [PR_NUMBER] --format=text
```

```bash
env -u GH_REPO -u GITHUB_REPOSITORY gh pr view [PR_NUMBER] --json headRefName --jq .headRefName
```

```bash
.agents/skills/orch/scripts/orch-runtime state exists --item [STATE_KEY]
```

Only where the reply's `exists` is `false`, create the state with the branch the second command printed:

```bash
.agents/skills/orch/scripts/orch-runtime state init --item [STATE_KEY] --branch [PR_BRANCH]
```

Then lift any standing post-PR stop:

```bash
.agents/skills/orch/scripts/orch-runtime state post-pr-stop clear --item [STATE_KEY]
```

Managed, `[STATE_KEY]` is the caller's `issue_id`. Every `[ISSUE_ID]` below is this key.

## 2. Fetch Error Details

```bash
.agents/skills/github/scripts/github.sh ci-logs [PR_NUMBER]
```

`ci-logs` reads only the pull request head's checks. § 4 reads a merge-group run's failed logs.

## 3. Classify And Route

- Fix formatting, obvious lint and a missing import directly (§ 3.1).
- Delegate a test failure, a build error or non-obvious lint (§ 3.2).
- A merge-group failure takes § 4 first, which names the pull request whose commits caused it.

Read the decision mode once for this workflow. Named stops follow [SKILL.md § The Cycle](../SKILL.md#the-cycle).

```bash
.agents/skills/orch/scripts/orch-env ORCH_DECISION_MODE ask
```

### 3.1 Direct Fixes

1. Resolve the pull request's worktree as `[DIR]`. Read its issue with `github.sh pr-issue [PR_NUMBER] --format=text`, then run `.agents/skills/worktree/scripts/worktree exists` and `worktree path` for that issue.
2. Where the worktree is missing, create it with `--pr [PR_NUMBER]`.
3. `[WORKTREE_PATH]` is `.agents/skills/orch/scripts/git-context repo-root "[DIR]"`.
4. Apply the fix, then commit and push:

```bash
git -C "[WORKTREE_PATH]" commit -am "fix([ISSUE_ID]): Resolve CI failure ([ERROR_TYPE])"
```

```bash
git -C "[WORKTREE_PATH]" push
```

→ § 5.

### 3.2 Delegated Fixes

- Infer the agent from the component paths or the issue's labels.
- Apply [Delegation](../references/skill-rules.md#delegation) before each dev or integration-analysis delegation.
- A test failure in concurrent code that passes locally may be flaky. Check the project's testing conventions (missing barriers, iteration-based waits, static mutable state) before treating it as a regression.

Stamp the round immediately before delegating, each command as its own tool call. Apply the cleanup condition and arm the watchdog per [Round Closure](../references/skill-rules.md#round-closure).

1. Mint the CI token. The runtime stores it at `ci_round_id`; the reply's `.result.report.round_id` is the token.

   ```bash
   .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"begin-round","kind":"ci"}'
   ```

2. Where the cleanup condition applies, prune under the CI token: write `[WORKTREE_PATH]/tmp/prune-round-[ISSUE_ID].json` with the harness file tool as `{"op": "prune-round", "field": "ci"}`, then run it:

   ```bash
   .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request [WORKTREE_PATH]/tmp/prune-round-[ISSUE_ID].json
   ```

3. Record the delegation time:

   ```bash
   .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-round","step":"delegated","round":"ci"}'
   ```

Arm the watchdog with the CI token and accept the round as [Round Closure](../references/skill-rules.md#round-closure) states for CI rounds. `[WORKTREE_PATH]` is § 3.1's.

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
5. Stage and commit: `git -C [WORKTREE_PATH] add -A`, then `git -C [WORKTREE_PATH] commit -m "fix([ISSUE_ID]): [DESCRIPTION]"`, adding `-m "[validate: FAILING_CHECK]"` as the body, never to the header, when other failures remain.
6. Push: `git -C [WORKTREE_PATH] push`.

Report: what was fixed, the validate status, and any unrelated failures.
</delegation_format>

→ § 5.

## 4. Merge-Group Failures

The Recovery cycle of [merge-pr.md § 5](merge-pr.md#5-execute-the-merge) step 1 hands this workflow a merge-group run as `[RUN_ID]`. The run has no pull request; it runs on GitHub's temporary queue branch. Its head carries this pull request's commits on top of those of the pull requests queued ahead. Read each of these as its own tool call:

1. The group's head, `[GROUP_HEAD]`:

   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY gh run view [RUN_ID] --json headSha --jq .headSha
   ```

2. The pull request's base branch, `[BASE_REF]`:

   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY gh pr view [PR_NUMBER] --json baseRefName --jq .baseRefName
   ```

3. The commits the head carries past that base:

   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY gh api "repos/{owner}/{repo}/compare/[BASE_REF]...[GROUP_HEAD]" --jq '.commits[] | [.sha, .commit.message] | @tsv'
   ```

4. The run's failed logs, which every route below carries as its error output:

   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY gh run view [RUN_ID] --log-failed
   ```

Match those commits to their pull requests. Find the failed file, the commit that introduced the failure, and the pull request that holds that commit:

- This pull request's own commits caused it: § 3.
- One other identifiable pull request caused it: route it to that pull request's agent.
- A cross-PR integration issue: delegate the analysis to the architecture reviewer from this pull request's worktree, with the brief below. `[WORKTREE_PATH]` is this pull request's, resolved as in § 3.1.

Where the source stays unclear after that analysis, `auto-recommended` records the named stop `ci-source-unclear`. Under `ask`, present the evidence to the user.

<delegation_format>
Merge queue CI failure — integration issue across the PRs of one merge group.

PR: #[PR_NUMBER]
Merge-group run: [RUN_ID]
Worktree: [WORKTREE_PATH]
Group: [the PRs in the group with their domains]

Error output:
[error logs]

1. Analyze which PRs interact to cause this failure.
2. Identify the root cause.
3. Recommend which PR(s) need changes.
4. If it is fixable, give specific fix instructions.

Report findings for a user decision.
</delegation_format>

## 5. Verify

### 5.1 Review gate

On every repository, confirm the review gate at the new head **before** waiting on CI:

1. Bind `[REVIEW_BASE_CHECKOUT]` per [Gate-mode routing](../references/gates.md#gate-mode-routing).
2. Write [the review call](../references/gates.md#the-review-call)'s request file from `[WORKTREE_PATH]` with `[MARK_READY]` `false`.
3. Run the exact-head confirmation with the shorter review period:

```bash
env PR_REVIEW_WAIT_SECS=300 .agents/skills/orch/scripts/orch-runtime op --item [STATE_KEY] --request "[WORKTREE_PATH]/tmp/verify-review-request-[STATE_KEY].json"
```

- The reply's `mode` is `GATE_MODE`, the item's recorded mode.
- A refusal carries no mode: report it and stop.
- Under the `off` gate mode the wait ends at its first reply. A `complete` verdict `off`, or a `pending` reply with reason `copilot-pending`, goes to the CI wait; merge-pr § 5 step 1's call holds that Copilot work before the merge ([gates.md § Copilot requests](../references/gates.md#copilot-requests)).
- Under `approval`, route the reply's `request` by [Copilot requests](../references/gates.md#copilot-requests) before the verdict.

Route the verdict:

- `approved` / `proceeded` → wait for CI (§ 5.3). For `proceeded`, the caller records `pr_approval.reviewer_down`; this workflow does not.
- `comments` / `changes_requested` → new feedback on the fix push. Managed: return it to the caller's review-gate handling. Standalone: run that triage pass, then run § 5.1 again.
- `blocked` → a regression-against-main blocker stands open on the item; `reason` names its location. Managed: return the `blocked` verdict to the caller. Standalone: report the location and stop. Never treat it as a met gate.
- `copilot-error` → route as [Copilot requests](../references/gates.md#copilot-requests) says. Managed: return the unmet gate to the caller. Standalone: run § 5.1 once more for the overseer approval. If the gate stays unmet, take the `timeout` stop below.
- `timeout` → no exact-head evidence yet. A missing or red CI run here is not a fix failure. Run § 5.1 once more. If it repeats, `auto-recommended` records `ci-gate-unconfirmed`; under `ask`, hand back the unconfirmed gate.
- An `unreadable` reply → run the call once more. If it repeats, take the `timeout` stop.

### 5.2 Merge-group reproduction

For a merge-group failure, run the failing job's command locally on the fix head before any wait. That is `DEV_VALIDATE_CMD` through the validation entry with `--reproduce`, which never defers the run to CI, or the suite the failing job named.

```bash
.agents/skills/orch/scripts/orch-runtime validate entry --worktree [WORKTREE_PATH] --reproduce
```

- Exit 3 with `state=running` is no outcome. Follow the run to its verdict with `orch-runtime validate entry --wait --run-dir [RUN_DIR]`.
- Only a completed local pass lets the caller re-arm.

Every other outcome stops here and never reaches the wait below:

- A red local run is the fix's failure: report it and stop.
- A run that ends `validate=no-verdict`, or a start refused with exit 2, leaves the reproduction unproved. On a `run-live` refusal, take the wait or stop route of [dev-implement.md § 5](../../dev/workflows/dev-implement.md#5-validate), then start the reproduction again. Report any other unproved reproduction and stop.

The pull-request wait proves nothing about a merge-group fix. The caller re-arms only under the re-queue rule of the Recovery cycle in [merge-pr.md § 5](merge-pr.md#5-execute-the-merge).

### 5.3 CI wait

The wait is the runtime's `verify-pr` operation over the pull request's current head.

- Run it as [submit-pr.md § 5](submit-pr.md#5-verify-ci) does: merge-state read first, through [Waiter launch](../references/waiter-launch.md), repeated while `result.status` is `pending` or `unreadable`.
- `[OWNER/REPO]` is what `gh repo view --json nameWithOwner --jq .nameWithOwner` prints from the checkout.
- Write the request to `[WORKTREE_PATH]/tmp/verify-pr-request-[STATE_KEY].json` with the harness file tool as `{"op": "verify-pr", "repo": "[OWNER/REPO]", "pr": [PR_NUMBER], "required_only": true}`, then run it:

```bash
.agents/skills/orch/scripts/orch-runtime op --item [STATE_KEY] --request "[WORKTREE_PATH]/tmp/verify-pr-request-[STATE_KEY].json"
```

A `pr-not-open` refusal means the pull request is closed or merged: report its `state` and stop.

**One rerun per head.** On `status=complete` with `verdict=fail`, rerun a transient runner failure once on the pull request's head before routing the result.

- Follow One rerun per head in [submit-pr.md § 5.1](submit-pr.md#51-ci-failure-recovery), with `[STATE_KEY]` as the key.
- Never rerun a merge group's run; a same-head re-queue under the re-queue rule of [merge-pr.md § 5](merge-pr.md#5-execute-the-merge) takes its place.
- Where the recorded `ci_rerun.head` is not the verdict's `result.head`, record the rerun, then request it:

```bash
.agents/skills/orch/scripts/orch-runtime op --item [STATE_KEY] --request-json '{"op":"record-pr-progress","step":"ci-rerun","head":"[HEAD]"}'
```

```bash
env -u GH_REPO -u GITHUB_REPOSITORY .agents/skills/github/scripts/github.sh ci-rerun [PR_NUMBER] --required-only
```

On `rerun run=[RUN_ID]`, record the run. Repeat the wait after submit-pr.md § 5's interval between calls, never at once.

```bash
.agents/skills/orch/scripts/orch-runtime op --item [STATE_KEY] --request-json '{"op":"record-pr-progress","step":"ci-rerun-run","head":"[HEAD]","run":[RUN_ID]}'
```

**Passing CI.** `status=complete` with `verdict=pass` or `verdict=none` clears the standalone CI-fix budget:

```bash
.agents/skills/orch/scripts/orch-runtime state head-budget reset --item [STATE_KEY] --kind ci-fix
```

### 5.4 Report a fix

**Linear only**, where the state key is a Linear issue. Write the status body to `[WORKTREE_PATH]/tmp/ci-fix-status-[STATE_KEY].md` with the harness file tool, then post it:

```markdown
[What the correction restores for the person, and what proof remains.]

CI Fix: [ERROR_TYPE] → [FIX_DESCRIPTION]

**Evidence**: [The check or run that read the failure and its verdict]

**Next**: [Remaining proof, such as the required merge-group run, or nothing]
```

```bash
.agents/skills/linear/scripts/linear.sh comments create [STATE_KEY] --body-file [WORKTREE_PATH]/tmp/ci-fix-status-[STATE_KEY].md
```

Output: [Lane Output](../references/skill-rules.md#lane-output).

<output_format>

### ✅ CI FIXED — PR #[N]

| Field | Value |
|-------|-------|
| Error | [ERROR_TYPE] |
| Fix | [FIX_DESCRIPTION] |
| Status | ✅ CI passing |

</output_format>

### 5.5 Still failing

Output: [Lane Output](../references/skill-rules.md#lane-output).

<output_format>

### ⚠️ CI STILL FAILING — PR #[N]

| Field | Value |
|-------|-------|
| Original | [ERROR_TYPE] ✅ (fixed) |
| New failure | [NEW_ERROR_TYPE] |
| Next | Run `orch ci-fix [PR_NUMBER]` again |

</output_format>

- A managed failure returns to the caller, which owns `CI_FIX_MAX_CYCLES`.
- A standalone `auto-recommended` run spends one cycle of the pull request's budget, which counts as [settings.md § Review and CI](../references/settings.md#review-and-ci) states for `CI_FIX_MAX_CYCLES`. Read the head, then take the cycle:

```bash
env -u GH_REPO -u GITHUB_REPOSITORY gh pr view [PR_NUMBER] --json headRefOid --jq .headRefOid
```

```bash
.agents/skills/orch/scripts/orch-runtime state head-budget take --item [STATE_KEY] --kind ci-fix --head [CI_HEAD]
```

The reply's `verdict`:

- `continue`: run § 1 again.
- `at-cap`: record and return the named stop `ci-fix-cap`.
  - Start no cycle past the cap until the overseer appends one `ruling` row for the item through `orch-runtime state log append --fleet [RULING_FILE]` ([oversee-events.md § Judgement rules](../references/oversee-events.md#judgement-rules)).
  - The overseer judges with the reply's `attempts` and `limit`. When the ruling authorizes another cycle, the overseer runs `orch-runtime state head-budget reset --item [STATE_KEY] --kind ci-fix` before the next take.
  - A remaining failure caused by a concern other than the pull request's goal, which can land apart, gets its own item with its owner in the same pass. The work the goal needs continues.

  ```bash
  .agents/skills/orch/scripts/orch-runtime state post-pr-stop record --item [STATE_KEY] --name ci-fix-cap --gate ci --remaining "[REMAINING_CHECKS_AND_ATTEMPTS]" --comment-file [WORKTREE_PATH]/tmp/post-pr-stop-[STATE_KEY].md
  ```

  ```bash
  .agents/skills/github/scripts/github.sh post-comment [PR_NUMBER] --body-file [WORKTREE_PATH]/tmp/post-pr-stop-[STATE_KEY].md
  ```

  Under `ask`, present `Run ci-fix again` | `Stop`; continuing clears the stop.

## 6. Return

**Managed**: return to the parent workflow's next section with the `GATE_MODE` § 5.1 read at the new head. The caller uses that mode from here. **Standalone**: return `.post_pr_stop` where one stands; otherwise the CI-fix session is complete.
