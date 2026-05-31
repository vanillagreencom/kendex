# Workflow: `pre-pr-review` — Master-Side Pre-PR Reviewer Fan-out

Master-side review loop invoked from GitHub or Plan handle-prompt on the `pre-pr-ready-for-review` tag. The child has pushed commits and is waiting for approval before opening a PR. Master fans out `reviewer-*` agents against the diff, hands findings back to the child for fixes, and re-runs the loop until approval. The configured round cap is an audit boundary, not a user questionnaire.

**Inputs**: `<ENTRY_ID>`, `<DOMAIN_KEY>` (`github_issue` or `plan_item`).

**Pre-conditions**:
- Entry has `domain.<KEY>.worktree` and a pushed branch (`issue-<N>` or item branch).
- `FLIGHTDECK_PRE_PR_REVIEW != 0` (default `1`). When `0`, the caller skips this workflow and signals the child to open the PR directly.

**Post-condition**: one of
- `domain.<KEY>.review_status = "pre-pr-approved"` and child instructed to open PR; or
- `domain.<KEY>.review_status = "pre-pr-fixing"` and child instructed to apply round-N findings; or
- `paused_for_user.reason = "pre-pr-review-error"` / `"pre-pr-review-empty-diff"` set for actual workflow failure and no pane response.

This workflow is the sole owner of `domain.<KEY>.review_rounds`. Lane handlers must not increment it.

---

## § 1: Round setup and autonomy caps

1. If `domain.<KEY>.review_rounds` is null/unset, set it to `1`.
2. Read `MAX = FLIGHTDECK_PRE_PR_REVIEW_MAX_ROUNDS` (default `3`) and `HARD_CAP = FLIGHTDECK_PRE_PR_REVIEW_HARD_CAP` (default `MAX + 2`). Clamp `HARD_CAP >= MAX`.
3. Do not set `paused_for_user` solely because `review_rounds > MAX`. A ready signal after the soft cap is deterministic:
   - Log decision `pre-pr-review autonomous-override round=<N> max=<MAX> hard_cap=<HARD_CAP>`.
   - Continue to § 2 and run another reviewer round so current evidence decides approve vs fix.
4. When `review_rounds > MAX`, enter repeated-loop severity mode: only `category == "fix"` items with `priority ∈ {"P1","P2"}` or explicit safety-critical language remain blocking. `P3` / `P4` fix items are downgraded to non-blocking suggestions for approval/audit purposes.
5. When `review_rounds > HARD_CAP`, still do not ask the user if concrete high-priority evidence exists. Continue to § 2 for one more verification round, then § 7 routes a focused blocker/follow-up path instead of broad re-review churn. Only set `paused_for_user.reason="pre-pr-review-error"` if prior/current reports cannot be parsed or persisted and no deterministic fix/approve path can be derived.
6. The current round number is referenced as `<N>` in subsequent steps.

---

## § 2: Resolve scope

1. Read `entry.domain.<KEY>.worktree` and `entry.cwd`. Branch is `issue-<N>` for GitHub, item branch for Plan.
2. Compute the diff range. On any non-zero exit, set `paused_for_user = {entry_id:<ID>, reason:"pre-pr-review-error", prompt_text:"<command>\n<stderr>"}`, log activity `pre-pr-review-error round=<N> step=scope command=<cmd>`, and return:
   ```bash
   BASE=$(git -C <WT> symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
   [ -n "$BASE" ] || BASE=main
   git -C <WT> fetch origin "$BASE" "<BRANCH>" --quiet
   DIFF_RANGE="origin/${BASE}...origin/<BRANCH>"
   ```
3. If `git -C <WT> diff $DIFF_RANGE --stat` is empty, set `paused_for_user = {entry_id:<ID>, reason:"pre-pr-review-empty-diff", prompt_text:"branch has no commits vs $BASE"}` and return.

---

## § 3: Select reviewers

Default reviewer list: `reviewer-arch`, `reviewer-correctness`, `reviewer-error`, `reviewer-quality`, `reviewer-safety`, `reviewer-security`, `reviewer-structure`, `reviewer-test`, `reviewer-doc`, `reviewer-perf`. Override with `FLIGHTDECK_PRE_PR_REVIEWERS` (CSV).

Filter the default list by changed paths:

| File set signal | Drop reviewers |
|-----------------|----------------|
| No `*.rs` and no native source | `reviewer-perf`, `reviewer-safety` |
| No tests touched and no test-bearing dirs added | `reviewer-test` (only if no production code changed either) |
| Only `*.md` / docs | keep `reviewer-doc`, `reviewer-arch`; drop the rest |

Never drop `reviewer-arch`, `reviewer-correctness`, `reviewer-error`, `reviewer-quality`, or `reviewer-security` for code changes.

If the resulting reviewer list is empty (env override set to empty, or every default reviewer dropped by the filter) set `paused_for_user = {entry_id:<ID>, reason:"pre-pr-review-error", prompt_text:"no reviewers selected for round <N>; check FLIGHTDECK_PRE_PR_REVIEWERS and § 3 filter"}` and return. Never approve a round with zero reviewer returns.

---

## § 4: Delegate

The master-side delegation mechanism is whichever subagent-launching tool the supervising harness exposes (`subagent` on Pi; harness-equivalent multi-task launch elsewhere). Issue one parallel call with one task per reviewer in the selected list. Per reviewer, the task is:

<reviewer_task_format>
Review the diff on branch `<BRANCH>` in worktree `<WT_ABS>` vs `origin/<BASE>`.

Diff range: `<DIFF_RANGE>`
Round: <ROUND_N>
Prior rounds report dir: `<WT_ABS>/tmp/pre-pr-review/`

Read changed files in the worktree, apply the reviewer skill's General Review Ethos and Reviewer Scope Boundaries, evaluate against your review domain only, and return JSON in `<output_format>` tags:

<output_format>
{
  "verdict": "pass" | "action_required",
  "items": [
    { "category": "fix" | "issue", "priority": "P1" | "P2" | "P3" | "P4", "location": "<stable file path plus symbol/name; no line number>", "description": "<one line; include line or diff-hunk evidence here when useful>", "recommendation": "<one line>" }
  ]
}
</output_format>

Do not modify the worktree. Do not open PRs. Do not call other agents.
</reviewer_task_format>

Set `agentScope: "project"`. Reviewers carry `deny-tools: subagent,…` and are leaf agents.

---

## § 5: Collect

For each reviewer in the selected list, exactly one task must return. For each return:

1. Parse the `<output_format>` JSON.
   - On parse failure or empty output, retry that reviewer once with the same task and a one-line reminder to return valid `<output_format>` JSON.
   - If the retry also fails, set `paused_for_user = {entry_id:<ID>, reason:"pre-pr-review-error", prompt_text:"reviewer <NAME> returned unparseable output after retry"}`, log activity `pre-pr-review-error round=<N> step=collect reviewer=<NAME>`, and return. Do NOT synthesize reviewer infrastructure failures as `category:"fix"` code blockers and do not send them to the child fix path.
2. If the launcher reports a launch failure (non-zero exit, missing return, harness error), retry that reviewer once. If the retry also fails, set `paused_for_user = {entry_id:<ID>, reason:"pre-pr-review-error", prompt_text:"reviewer <NAME> launch failed: <stderr>"}`, log activity `pre-pr-review-error round=<N> step=delegate reviewer=<NAME>`, and return. Do NOT silently treat a missing reviewer as `pass`, and do NOT route launcher failures to the child as code blockers.
3. Persist raw validated reviewer output to `<WT_ABS>/tmp/pre-pr-review/round-<N>-<REVIEWER>.json`. If the write fails, set `paused_for_user = {entry_id:<ID>, reason:"pre-pr-review-error", prompt_text:"failed to persist round-<N>-<REVIEWER>.json: <stderr>"}` and return.
4. Append to `entry.domain.<KEY>.review_reports[]`: `{round:<N>, reviewer:<NAME>, verdict:<V>, path:<JSON_PATH>, item_count:<C>}`.

Aggregate verdict:

- `pass` when no item with `category == "fix"` exists across reviewers, regardless of per-reviewer verdict. A reviewer that returned `action_required` but produced only `category == "issue"` items is non-blocking; the items are recorded as non-blocking suggestions in the approval marker.
- `action_required` before or at the soft cap when any item has `category == "fix"`. Reviewers that return non-pass verdicts without any items are also treated as blocking (their items list is empty, but the verdict signals a failure mode the reviewer could not enumerate).
- Repeated-loop severity mode (`<N> > MAX`): `action_required` only when a `category == "fix"` item has `priority == "P1"`, `priority == "P2"`, or explicit safety-critical language in `description` / `recommendation` (`safety-critical`, `security`, `data loss`, `data corruption`, `race`, `deadlock`, `panic`, `crash`, `auth bypass`, `secret leak`). Convert downgraded `P3` / `P4` fix items into aggregate `category:"issue"` entries with `original_category:"fix"`, original priority, reviewer, location, description, and recommendation preserved. Include them in the approval marker; they do not prevent `pre-pr-approved` or opening a PR.

---

## § 6: Approve path

When aggregate is `pass`:

1. Write `<WT_ABS>/tmp/pre-pr-approved.md` (atomic write through a `.tmp` rename) containing:
   ```text
   Pre-PR review passed at round <N> on <ISO8601>.
   Reviewers: <CSV>
   Issue suggestions (non-blocking): <C items in <WT_ABS>/tmp/pre-pr-review/round-<N>-*.json with category="issue">
   Downgraded late-loop suggestions: <C P3/P4 fix items treated as non-blocking when <N> > MAX>
   ```
   On write failure set `paused_for_user.reason = "pre-pr-review-error"` and return; do not pane-respond.
2. `pane-respond` to the child pane with the approval instruction:
   ```text
   Pre-PR review passed. Open the PR now with `Fixes #<N>` in the body (or the plan-item PR body for plan mode). Print the PR URL as the LAST line of your final message.
   ```
   On `pane-respond` failure set `paused_for_user.reason = "pre-pr-review-error"` and return.
3. Only after both writes succeed, set `entry.domain.<KEY>.review_status = "pre-pr-approved"`. On state-write failure set `paused_for_user.reason = "pre-pr-review-error"` and return.
4. Log decision `pre-pr-review pass round=<N> reviewers=<CSV>`. If `<N> > MAX`, include `autonomous-override-passed-soft-cap=true`. Log failure is non-blocking; the next compaction recovery re-reads `review_status` from the persisted entry. Return to caller.

---

## § 7: Fix path and hard-cap policy

When aggregate is `action_required`:

1. Write `<WT_ABS>/tmp/pre-pr-review/round-<N>.md` (atomic write through a `.tmp` rename) concatenating all blocking `category=="fix"` items and all non-blocking `category=="issue"` / downgraded late-loop `P3` / `P4` fix items across reviewers:
   ```markdown
   # Pre-PR review round <N>

   ## Blockers / Fix
   - [<REVIEWER>] <location>: <description>
     - Recommendation: <recommendation>

   ## Issue suggestions / Downgraded late-loop nits (non-blocking)
   - [<REVIEWER>] <location>: <description>
     - Recommendation: <recommendation>
   ```
   On write failure set `paused_for_user.reason = "pre-pr-review-error"` and return; do not pane-respond.
2. If `<N> > MAX`, log decision `pre-pr-review autonomous-override action-required round=<N> max=<MAX> blockers=<count>`. This audit row replaces the old routine user decision.
3. If `<N> >= HARD_CAP` or the same normalized blocking `category == "fix"` (`P1` / `P2` / safety-critical) blocker repeats unchanged from the prior round, also write `<WT_ABS>/tmp/pre-pr-review/focused-blocker-round-<N>.md` with the single highest-priority repeated blocker and a `Follow-up issue suggestion` section for separable non-blocking `category == "issue"` plus downgraded `P3` / `P4` late-loop nits. Normalization key: `priority + location + lowercase(description without line numbers)`. This is deterministic routing, not approval.
4. `pane-respond` to the child pane with the fix instruction:
   ```text
   Pre-PR review round <N> found blockers. Read `tmp/pre-pr-review/round-<N>.md`, apply the fix items (issue suggestions are non-blocking), push to `<BRANCH>`, then print `PRE-PR-REVIEW-READY: tmp/ready-for-review.txt` again as the LAST line.
   ```
   If the focused blocker file exists, use this narrower instruction instead:
   ```text
   Pre-PR review reached the hard-cap/focused-blocker policy. Read `tmp/pre-pr-review/focused-blocker-round-<N>.md`, fix the focused blocker first, push to `<BRANCH>`, then print `PRE-PR-REVIEW-READY: tmp/ready-for-review.txt` again as the LAST line. Do not ask the user for routine approval.
   ```
   On `pane-respond` failure set `paused_for_user.reason = "pre-pr-review-error"` and return.
5. Only after all required writes and the pane response succeed, increment `entry.domain.<KEY>.review_rounds` and set `entry.domain.<KEY>.review_status = "pre-pr-fixing"`. On either state-write failure set `paused_for_user.reason = "pre-pr-review-error"` and return; the next entry resumes the same round.
6. Log decision `pre-pr-review action-required round=<N> blockers=<count>` (plus `focused-blocker=true` when used). Log failure is non-blocking.
7. Return to caller. The next `pre-pr-ready-for-review` from the child re-enters this workflow at round `<N+1>`; § 1 treats the soft cap as autonomous audit and § 7 applies focused routing at the hard cap.

## Returns

To `github/handle-prompt.md` § 3 (`pre-pr-ready-for-review` handler) or `plan/handle-prompt.md` § 3 (`pre-pr-ready-for-review` handler).
