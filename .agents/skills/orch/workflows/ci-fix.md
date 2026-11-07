# CI Fix Workflow

Analyze CI failures and route them to the right agent.

| Command | Flow |
|---------|------|
| `ci-fix` \| `ci-fix [PR_NUMBER]` | § 1 → § 2 → § 3 → § 5, with § 4 first for a merge-group run |

**Caller context** (via `⤵`): managed `lifecycle` uses the caller's `issue_id`; standalone is the default.

## 1. Identify Failures

```bash
.agents/skills/github/scripts/github.sh pr-list-failing
```

With several failures and no argument, present them and ask which to fix:

Output: [Lane Output](../references/skill-rules.md#lane-output).

<output_format>

### CI FAILURES

| # | PR | Title | Job | Error |
|---|-----|-------|-----|-------|
| 1 | #42 | Add user auth | build | lint |

</output_format>

Standalone only: use the extracted issue as `[STATE_KEY]`, or `pr-[PR_NUMBER]` when empty. Run `init` only when `exists` is false:

```bash
.agents/skills/github/scripts/github.sh pr-issue [PR_NUMBER] --format=text
env -u GH_REPO -u GITHUB_REPOSITORY gh pr view [PR_NUMBER] --json headRefName --jq .headRefName
.agents/skills/orch/scripts/orch-runtime state exists --item [STATE_KEY]
.agents/skills/orch/scripts/orch-runtime state init --item [STATE_KEY] --branch [PR_BRANCH]
.agents/skills/orch/scripts/orch-runtime state set --item [STATE_KEY] /post_pr_stop null
```

## 2. Fetch Error Details

```bash
.agents/skills/github/scripts/github.sh ci-logs [PR_NUMBER]
```

`ci-logs` reads the pull request head's checks alone; a merge-group run's failed logs are § 4's read.

## 3. Classify And Route

Formatting, obvious lint, and a missing import are fixed directly; a test failure, a build error, or non-obvious lint is delegated. A failure in a merge-group run takes § 4 first, which names the PR whose commits caused it.

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

→ § 5.

### 3.2 Delegated Fixes

Infer the agent from the component paths or issue labels. Apply [Delegation](../references/skill-rules.md#delegation) before each dev or integration-analysis delegation. A test failure in concurrent code that passes locally is a flaky-test candidate — check the project's testing conventions (missing barriers, iteration-based waits, static mutable state) before treating it as a real regression.

Stamp the round as separate tool calls immediately before delegating. Apply the cleanup condition and arm the watchdog per [references/skill-rules.md § Round Closure](../references/skill-rules.md#round-closure). Each command takes the one state key as `[ISSUE_ID]`: the caller's `issue_id` when managed, § 1's `[STATE_KEY]` standalone. The mint stores the token at `ci_round_id` and answers it as `result.value`:

```bash
.agents/skills/orch/scripts/orch-runtime state new-round-id --item [ISSUE_ID] /ci_round_id
```

Apply [Round Closure](../references/skill-rules.md#round-closure)'s cleanup condition to this helper call:

```bash
.agents/skills/orch/scripts/round-prune --ci [ISSUE_ID]
```

```bash
.agents/skills/orch/scripts/orch-runtime state set-now --item [ISSUE_ID] /dev_delegated_at
```

Fill `Worktree:` from `git -C "[DIR]" rev-parse --show-toplevel`.

This route uses `ci_round_id` for CI fixes and integration analysis. Apply the [Round Closure exception](../references/skill-rules.md#round-closure) to its watchdog. Accept this round on the agent's return message plus the pushed fix commit; on an absent return follow the escalation ladder.

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

A merge-group run, the one [merge-pr.md § 5](merge-pr.md#5-execute-the-merge) Recovery cycle step 1 points this workflow at as `[RUN_ID]`, runs on GitHub's temporary queue branch and carries no pull request. Its head carries this PR's commits on top of those of the PRs queued ahead of it. Read that head as `[GROUP_HEAD]`, the PR's base branch as `[BASE_REF]`, the commits the head carries past that base, then the run's failed logs, the error output every route below carries:

```bash
env -u GH_REPO -u GITHUB_REPOSITORY gh run view [RUN_ID] --json headSha --jq .headSha
env -u GH_REPO -u GITHUB_REPOSITORY gh pr view [PR_NUMBER] --json baseRefName --jq .baseRefName
env -u GH_REPO -u GITHUB_REPOSITORY gh api "repos/{owner}/{repo}/compare/[BASE_REF]...[GROUP_HEAD]" --jq '.commits[] | [.sha, .commit.message] | @tsv'
env -u GH_REPO -u GITHUB_REPOSITORY gh run view [RUN_ID] --log-failed
```

Cross-reference those commits with the original PRs to identify which file failed, which commit introduced it, and which PR that commit belongs to. A failure this PR's own commits cause takes § 3. Another single identifiable PR routes to that PR's agent; a genuine cross-PR integration issue routes to the architecture reviewer for analysis, delegated from this PR's worktree. When the source stays unclear after that analysis, `auto-recommended` records `ci-source-unclear`; `ask` presents the evidence to the user.

Fill `Worktree:` from `git -C "[DIR]" rev-parse --show-toplevel`. `[DIR]` is this PR's worktree, resolved as § 3.1 resolves it.

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

Re-confirm the review gate at the new head **before** waiting on CI, on every repo with no repo detection.

Bind `[REVIEW_BASE_CHECKOUT]` per [Gate-mode routing](../references/gates.md#gate-mode-routing). Write [the review call](../references/gates.md#the-review-call)'s request file from `[WORKTREE_PATH]`, `[MARK_READY]` `false`, and run the short exact-head re-confirmation through its review wait with the shorter period:

```bash
env PR_REVIEW_WAIT_SECS=300 .agents/skills/orch/scripts/orch-runtime op --item [STATE_KEY] --request "[WORKTREE_PATH]/tmp/verify-review-request-[STATE_KEY].json"
```

Its reply's `mode` is `GATE_MODE`, the item's recorded one. Under the `off` gate mode the wait ends at its first reply: a `complete` verdict `off`, or a `pending copilot-pending` reply while Copilot's work runs on the head, which merge-pr § 5 step 1's call holds before the merge call, goes to the CI wait. A `blocked` verdict under either mode takes the `blocked` row below. A refusal is no mode, so report it and stop. On `approval` its `request` says what the new head's record holds, whatever the verdict: route it by [Copilot requests](../references/gates.md#copilot-requests) before the verdict. Route the verdict:

- `approved` / `proceeded` → wait for CI. ci-fix writes no `pr_approval.reviewer_down` for `proceeded`; the caller records it. It is a LOCAL verdict — orch posts no status.
- `comments` / `changes_requested` → new feedback on the fix push. Managed: return it to the caller's review-gate handling. Standalone: run that triage pass, then re-run this step.
- `blocked` → a regression-against-main blocker stands open on the item, its location in `reason`. Managed: return the unmet gate to the caller. Standalone: report the location and stop. Never treat it as a met gate.
- `copilot-error` → route as [Copilot requests](../references/gates.md#copilot-requests) says. Managed: return the unmet gate to the caller. Standalone: re-run this step once for the overseer approval. If the gate stays unmet, use the `timeout` stop route below.
- `timeout` → no exact-head evidence yet; a missing or red CI run here is not a fix failure. Re-run this step once. If it repeats, `auto-recommended` records `ci-gate-unconfirmed`; under `ask`, hand back the unconfirmed gate.
- `unreadable` → re-run the call once. If it repeats, take the `timeout` route's stop.

For a merge-group failure, first run the failing job's command locally on the fix head: `DEV_VALIDATE_CMD` through `.agents/skills/orch/scripts/dev-validate-run --worktree [WORKTREE_PATH] --reproduce`, which never defers the run to CI, or the suite the failing job named. Only a completed local pass lets the caller re-arm; every other outcome stops here and never reaches the wait below:

- A red local run is the fix's failure; report it and stop.
- A run that ends `validate=no-verdict`, or a start refused with exit 2, leaves the reproduction unproved. For a `run-live` refusal, take the wait or stop route of [dev-implement.md § 5](../../dev/workflows/dev-implement.md#5-validate), then start the reproduction again. Report any other unproved reproduction and stop.

The pull-request wait below proves nothing about the fix under the harness-ci queue-only default, where the pull-request run reports `CI` with no lane. The caller re-arms only under [merge-pr.md § 5](merge-pr.md#5-execute-the-merge) Recovery cycle's re-queue rule.

The wait is the runtime's `verify-pr` operation over the pull request's current head, run through [Waiter launch](../references/waiter-launch.md) and repeated while `result.status` is `pending` or `unreadable`, as [submit-pr.md § 5](submit-pr.md#5-verify-ci) runs it, its merge-state read first; `[OWNER/REPO]` is the repository as `gh repo view --json nameWithOwner --jq .nameWithOwner` answers it from the checkout. A `pr-not-open` refusal says the pull request is closed or merged: report its `state` and stop.

```bash
jq -cn --arg repo "[OWNER/REPO]" --argjson pr [PR_NUMBER] \
  '{op: "verify-pr", repo: $repo, pr: $pr, required_only: true}' \
  > "[WORKTREE_PATH]/tmp/verify-pr-request-[STATE_KEY].json"
.agents/skills/orch/scripts/orch-runtime op --item [STATE_KEY] --request "[WORKTREE_PATH]/tmp/verify-pr-request-[STATE_KEY].json"
```

On `status=complete` with `verdict=fail`, a transient runner failure is rerun once per head before the result goes anywhere, as [submit-pr.md § 5.1](submit-pr.md#51-ci-failure-recovery) One rerun per head reads and records it, with `[STATE_KEY]` as the key: where the recorded `ci_rerun.head` is not the verdict's `result.head`, record the rerun, then ask for it, and on `rerun run=[RUN_ID]` record the run and repeat the wait after the interval submit-pr.md § 5 keeps between calls, never at once, since GitHub registers the new attempt after the verb answers:

```bash
.agents/skills/orch/scripts/orch-runtime state set --item [STATE_KEY] /ci_rerun '{"head": "[HEAD]", "run": null, "at": "[NOW]"}'
env -u GH_REPO -u GITHUB_REPOSITORY .agents/skills/github/scripts/github.sh ci-rerun [PR_NUMBER] --required-only
```

A passing or unconfigured CI result, `status=complete` with `verdict=pass` or `verdict=none`, clears the standalone CI-fix budget:

```bash
.agents/skills/orch/scripts/orch-runtime state set --item [STATE_KEY] /post_pr_budgets/ci_fix null
```

**Linear only** — post the short status to the tracker:

Write the status body with the harness file-write tool to `tmp/ci-fix-status-[STATE_KEY].md` and bind that path as `[BODY_FILE]`:

```markdown
CI Fix: [ERROR_TYPE] → [FIX_DESCRIPTION]
```

```bash
.agents/skills/linear/scripts/linear.sh comments create "$ISSUE" --body-file [BODY_FILE]
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

Still failing:

Output: [Lane Output](../references/skill-rules.md#lane-output).

<output_format>

### ⚠️ CI STILL FAILING — PR #[N]

| Field | Value |
|-------|-------|
| Original | [ERROR_TYPE] ✅ (fixed) |
| New failure | [NEW_ERROR_TYPE] |
| Next | Run `orch ci-fix [PR_NUMBER]` again |

</output_format>

Managed failures return to the caller, which owns `CI_FIX_MAX_CYCLES`. Standalone `auto-recommended` spends a cycle of the PR's budget. The count runs across the heads these cycles push, because each cycle pushes its own fix; only the passing-CI clear in this section resets it:

```bash
env -u GH_REPO -u GITHUB_REPOSITORY gh pr view [PR_NUMBER] --json headRefOid --jq .headRefOid
.agents/skills/orch/scripts/orch-runtime state head-budget take --item [STATE_KEY] --kind ci-fix --head [CI_HEAD]
```

Its reply's `verdict`: `continue` reruns § 1. `at-cap` records and returns `ci-fix-cap`, and no cycle starts past the cap until the overseer, judging with the reply's `attempts` and `limit`, has appended one `ruling` row for the item through `orch-runtime state log append --fleet` ([oversee-events.md § Judgement rules](../references/oversee-events.md#judgement-rules)):

```bash
.agents/skills/orch/scripts/orch-runtime state post-pr-stop record --item [STATE_KEY] --name ci-fix-cap --gate ci --remaining "[REMAINING_CHECKS_AND_ATTEMPTS]" --comment-file [WORKTREE_PATH]/tmp/post-pr-stop-[STATE_KEY].md
.agents/skills/github/scripts/github.sh post-comment [PR_NUMBER] --body-file [WORKTREE_PATH]/tmp/post-pr-stop-[STATE_KEY].md
```

Under `ask`, present `Run ci-fix again` | `Stop`; continuation clears the stop.

## 6. Return

**Managed**: return to the parent workflow's next section with the `GATE_MODE` § 5 read at the new head. That mode is the caller's from here. **Standalone**: return `.post_pr_stop` when present; otherwise the CI-fix session is complete.
