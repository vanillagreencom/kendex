# Workflow: `pre-pr-review` — Master-Side Pre-PR Reviewer Fan-out

Master-side review loop invoked from GitHub or Plan handle-prompt on the `pre-pr-ready-for-review` tag. The child has pushed commits to its branch and is waiting for approval before opening a PR. Master fans out `reviewer-*` agents against the diff, hands findings back to the child for fixes, and re-runs the loop until approval or round-cap.

**Inputs**: `<ENTRY_ID>`, `<DOMAIN_KEY>` (`github_issue` or `plan_item`).

**Pre-conditions**:
- Entry has `domain.<KEY>.worktree` and a pushed branch (`issue-<N>` or item branch).
- `FLIGHTDECK_PRE_PR_REVIEW != 0` (default `1`). When `0`, the caller skips this workflow and signals the child to open the PR directly.

**Post-condition**: one of
- `domain.<KEY>.review_status = "pre-pr-approved"` and child instructed to open PR; or
- `domain.<KEY>.review_status = "pre-pr-fixing"` and child instructed to apply round-N findings; or
- `paused_for_user.reason = "pre-pr-review-loop-stalled"` after `FLIGHTDECK_PRE_PR_REVIEW_MAX_ROUNDS` (default `3`).

---

## § 1: Resolve scope

1. Read `entry.domain.<KEY>.worktree` and `entry.cwd`. Branch is `issue-<N>` for GitHub, item branch for Plan.
2. Compute the diff range:
   ```bash
   BASE=$(git -C <WT> symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
   [ -n "$BASE" ] || BASE=main
   git -C <WT> fetch origin "$BASE" "<BRANCH>" --quiet
   DIFF_RANGE="origin/${BASE}...origin/<BRANCH>"
   ```
3. If `git diff $DIFF_RANGE --stat` is empty, set `paused_for_user = {entry_id:<ID>, reason:"pre-pr-review-empty-diff", prompt_text:"branch has no commits vs $BASE"}` and return.

---

## § 2: Select reviewers

Default reviewer list: `reviewer-arch`, `reviewer-error`, `reviewer-safety`, `reviewer-security`, `reviewer-structure`, `reviewer-test`, `reviewer-doc`, `reviewer-perf`. Override with `FLIGHTDECK_PRE_PR_REVIEWERS` (CSV).

Filter the default list by changed paths:

| File set signal | Drop reviewers |
|-----------------|----------------|
| No `*.rs` and no native source | `reviewer-perf`, `reviewer-safety` |
| No tests touched and no test-bearing dirs added | `reviewer-test` (only if no production code changed either) |
| Only `*.md` / docs | keep `reviewer-doc`, `reviewer-arch`; drop the rest |

Never drop `reviewer-arch`, `reviewer-error`, `reviewer-security` for code changes.

---

## § 3: Delegate

Run one `subagent` call with `tasks: [...]` so reviewers run in parallel. Per reviewer, the task is:

<reviewer_task_format>
Review the diff on branch `<BRANCH>` in worktree `<WT_ABS>` vs `origin/<BASE>`.

Diff range: `<DIFF_RANGE>`
Round: <ROUND_N>
Prior rounds report dir: `<WT_ABS>/tmp/pre-pr-review/`

Read changed files in the worktree, evaluate against your review domain only, and return JSON in `<output_format>` tags:

<output_format>
{
  "verdict": "pass" | "action_required",
  "items": [
    { "category": "fix" | "issue", "priority": "P1" | "P2" | "P3" | "P4", "location": "<file>:<line>", "description": "<one line>", "recommendation": "<one line>" }
  ]
}
</output_format>

Do not modify the worktree. Do not open PRs. Do not call other agents.
</reviewer_task_format>

Set `agentScope: "project"`. Reviewers carry `deny-tools: subagent,…` and are leaf agents.

---

## § 4: Collect

For each reviewer return:

1. Parse the `<output_format>` JSON. On parse failure, treat as `verdict=action_required` with a single synthetic item `{category:"fix", priority:"P2", location:"-", description:"reviewer <NAME> returned unparseable output", recommendation:"rerun"}`.
2. Append to `<WT_ABS>/tmp/pre-pr-review/round-<N>-<REVIEWER>.json`.
3. Persist to `entry.domain.<KEY>.review_reports[]`: `{round:<N>, reviewer:<NAME>, verdict:<V>, path:<JSON_PATH>, item_count:<C>}`.

Aggregate verdict is `pass` only when every reviewer returned `pass` and no `category=="fix"` items exist anywhere.

---

## § 5: Approve path

When aggregate is `pass`:

1. Write `<WT_ABS>/tmp/pre-pr-approved.md` containing:
   ```text
   Pre-PR review passed at round <N> on <ISO8601>.
   Reviewers: <CSV>
   Issue suggestions (non-blocking): <N items in <WT_ABS>/tmp/pre-pr-review/round-<N>-*.json with category="issue">
   ```
2. `pane-respond` to the child pane with the approval instruction:
   ```text
   Pre-PR review passed. Open the PR now with `Fixes #<N>` in the body (or the plan-item PR body for plan mode). Print the PR URL as the LAST line of your final message.
   ```
3. Set `entry.domain.<KEY>.review_status = "pre-pr-approved"`, log decision `pre-pr-review pass round=<N> reviewers=<CSV>`, and return to caller.

---

## § 6: Fix path

When aggregate is `action_required`:

1. Concatenate all `category=="fix"` and `category=="issue"` items across reviewers into `<WT_ABS>/tmp/pre-pr-review/round-<N>.md`:
   ```markdown
   # Pre-PR review round <N>

   ## Blockers / Fix
   - [<REVIEWER>] <location>: <description>
     - Recommendation: <recommendation>

   ## Issue suggestions (non-blocking)
   - [<REVIEWER>] <location>: <description>
     - Recommendation: <recommendation>
   ```
2. `pane-respond` to the child pane with the fix instruction:
   ```text
   Pre-PR review round <N> found blockers. Read `tmp/pre-pr-review/round-<N>.md`, apply the fix items (issue suggestions are non-blocking), push to `<BRANCH>`, then print `PRE-PR-REVIEW-READY: tmp/ready-for-review.txt` again as the LAST line.
   ```
3. Increment `entry.domain.<KEY>.review_rounds`. Set `entry.domain.<KEY>.review_status = "pre-pr-fixing"`. Log decision `pre-pr-review action-required round=<N> blockers=<count>`.
4. Return to caller. The next `pre-pr-ready-for-review` from the child re-enters this workflow at round `<N+1>`.

---

## § 7: Round-cap escalation

If `entry.domain.<KEY>.review_rounds >= FLIGHTDECK_PRE_PR_REVIEW_MAX_ROUNDS` (default `3`) and aggregate is still `action_required`:

1. Set `paused_for_user = {entry_id:<ID>, reason:"pre-pr-review-loop-stalled", prompt_text:"round <N> still has <count> blockers; see tmp/pre-pr-review/round-<N>.md"}`.
2. Do not pane-respond. Yield.

## Returns

To `github/handle-prompt.md` § (pre-pr-ready-for-review handler) or `plan/handle-prompt.md` § (pre-pr-ready-for-review handler).
