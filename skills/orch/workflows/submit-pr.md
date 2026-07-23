# Submit PR Workflow

Run a local pre-PR review, push changes, create/update the PR, triage review comments asynchronously, wait for the GitHub-native reviewer-gate verdict, verify CI, and confirm merge gates. The review gate (§ 4) runs before CI verification (§ 5) so repos that start CI only after a review verdict never deadlock.

## Inputs

| Command | Behavior |
|---------|----------|
| `submit-pr` | Submit current branch as PR |
| `submit-pr [PR#]` | Manage existing PR |
| (from start-worktree) | Managed lifecycle with caller context |

**Caller context parameters** (via `⤵`): `worktree`, `lifecycle` (`"managed"` → return at § 7 | `"self"` default), `issue_id` (workflow-state key — the normalized issue ID, e.g. `issue-N` for GitHub, never the bare GitHub issue number; extracted from branch if absent).

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

2. **Run the local review** (advisory — on script failure, report and continue to § 2). Capture an epoch freshness boundary *before* the review writes the artifact so step 3 can reject a stale or misdated file the way glob mode does:
   ```bash
   mkdir -p [WORKTREE_PATH]/tmp
   .agents/skills/orch/scripts/git-context timestamp epoch
   # Use the output as LOCAL_STARTED_AT (delegated-at boundary for the freshness check).
   .agents/skills/orch/scripts/git-context timestamp compact
   # Use [WORKTREE_PATH]/tmp/review-local-[TIMESTAMP_FROM_PREVIOUS_COMMAND].json as LOCAL_OUTPUT.
   .agents/skills/second-opinion/scripts/second-opinion review \
     --cwd [WORKTREE_PATH] \
     --output "$LOCAL_OUTPUT"
   ```

3. **Validate the artifact** — pass `LOCAL_STARTED_AT` so existence, freshness (`mtime >= LOCAL_STARTED_AT`), and `jq -e '.verdict'` are all checked:
   ```bash
   .agents/skills/orch/scripts/review-artifact-check --file "$LOCAL_OUTPUT" [LOCAL_STARTED_AT]
   ```
   Count the pass:
   ```bash
   .agents/skills/orch/scripts/workflow-state increment [ISSUE_ID] pr_local_review.passes
   ```
   If `ok == false`, report the `reason` and continue to § 2 — local review is advisory, never a submission blocker. This includes reason `no_review` (the artifact self-reports no review happened), reason `incomplete` (the artifact declares `qa_metadata` but lost its `blockers[]`/`suggestions[]` arrays), and script exits 3 (no diff scope) / 4 (model reported no review, or the response stayed schema-incomplete after the one-shot retry): none of these is a pass.

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

   **Rebase-map reconciliation (required).** `worktree push` auto-rebases the branch onto the updated base; that legitimately rewrites every branch commit, and the push then prints one `rebase-map: [OLD_SHA] [NEW_SHA]` line per rewritten commit (`[NEW_SHA]` is the literal word `dropped` when the replayed commit vanished because its patch was already upstream). Commit SHAs recorded before the push — `fixed_items`, `pr_comment_review.fixes`, a perf QA `benchmark_commit` — now name commits that no longer exist on the branch. When the push output contains any `rebase-map:` lines, reconcile before anything publishes them; publication (PR body, § 6.2 summary, `post-summary.md`) with unreconciled pre-rebase SHAs is forbidden (vstack#728):

   1. Record the map so later sessions can still resolve artifact-sourced SHAs — one command per mapping line, `dropped` stored literally:
      ```bash
      .agents/skills/orch/scripts/workflow-state update [ISSUE_ID] '.rebase_map = (.rebase_map // {}) + {"[OLD_SHA]": "[NEW_SHA]"}'
      ```
   2. Rewrite every stored fix commit that matches a mapped old SHA. A recorded short SHA matches when it is a prefix of `[OLD_SHA]`; replace it with `[NEW_SHA]` truncated to the recorded length (one command per matching item):
      ```bash
      .agents/skills/orch/scripts/workflow-state update [ISSUE_ID] '(.fixed_items[]? | select(.commit == "[RECORDED_SHA]") | .commit) = "[MAPPED_SHA]"'
      ```
      ```bash
      .agents/skills/orch/scripts/workflow-state update [ISSUE_ID] '(.pr_comment_review.fixes[]? | select(.commit == "[RECORDED_SHA]") | .commit) = "[MAPPED_SHA]"'
      ```
   3. Regenerate any already-drafted publication text from the reconciled state, and resolve every SHA sourced from a review/QA artifact rather than state (e.g. perf QA `benchmark_commit`) through `.rebase_map` before publishing it — follow the chain until no key matches, since a later rebase maps new → newer.

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
   [For each matching decision from `.agents/skills/decider/scripts/decisions search --issue [ISSUE_ID]` (decider skill) — paths come from that JSON output only, never from memory, and each is verified with `test -f [DECISION_FILE_PATH]` (one command per path); omit entries whose path fails (vstack#696):]
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
   - **Commit SHAs**: every SHA published in the body (fix commits, perf `benchmark_commit`) must be post-reconciliation — resolve through the step 1 rebase map when one was recorded (vstack#728).

4. **Create or update PR**. CI configured on `pull_request` runs from the moment the PR exists — orch never defers, queues, or gates it behind bot review activity. Approval-gated repos start their heavy CI only after the § 4 review-gate verdict instead; that is repo-side configuration (see orch `DEVELOPMENT.md` § CI Triggering Patterns) and needs no detection here.

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

Bot reviews are asynchronous: review bots may post minutes or hours after the PR opens. **Bot prose is never a gate signal** — emoji reactions, sticky comments, and checklist text are never parsed for gating. Triage whatever review comments exist right now and move on; the review gate (§ 4) polls for the GitHub-native gate verdict and new comments together, the merge gates (§ 6.1) require every comment replied to and resolved, and findings that arrive after merge get an immediate follow-up fix or an explicit tracking issue. Every bot comment still gets a reply and resolution — the hygiene standard is unchanged.

### 3.1 Opportunistic Triage

1. **Check what has already arrived**:
   ```bash
   .agents/skills/github/scripts/github.sh pr-threads [PR_NUMBER] --unresolved
   ```
   Read `.unresolved_count` from the JSON output and use it as `UNRESOLVED_FROM_PREVIOUS_COMMAND`. If it is `0` → § 3.5 (nothing to triage yet — later arrivals are handled by the § 4 review gate).

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

   **Otherwise** → § 3.5. Fixes pushed during triage were already replied to and their threads resolved by `review-pr-comments.md`. Do not wait for a bot re-review round — any re-review comments land in existing or new threads and are caught by the § 4 review gate or the § 6.1 gate 3 final check.

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

## 4. Review Gate

The review gate runs **before** CI verification — universally, with no repo detection. Consuming repos may configure CI to start only after a review verdict exists (approval-gated jobs or a merge queue; see orch `DEVELOPMENT.md` § CI Triggering Patterns), so waiting on CI first would deadlock those repos. On repos whose CI runs immediately from § 2, verifying CI after the gate (§ 5) simply returns quickly.

**Gate mode.** Read the project's reviewer-gate policy first:

```bash
.agents/skills/orch/scripts/approval-wait --resolve-mode
```

The printed value is `GATE_MODE` — `approval`, `review`, or `off`. The resolution order is implemented once in approval-wait, never re-derived here: `PR_REVIEW_GATE` when set; otherwise the legacy `PR_APPROVAL_GATE` maps `on` → `approval` and `off` → `off`; both unset defaults to `approval`. Set either key in `vstack.settings.toml` `[env]`.

- **`approval`** — wait for a GitHub-native approval verdict (`reviewDecision == "APPROVED"`, or the latest-review-per-reviewer fallback when no required-review protection exists).
- **`review`** — wait for a formal review of the **current head commit** from any non-author reviewer, in any state: COMMENTED counts, and an approval is also a review. This is the correct mode for commenting-only review bots (Devin- or Codex-style reviewers) that never mark PRs APPROVED — under `approval` mode their COMMENTED reviews would idle every PR to timeout. The mode carries an obligation: once the review arrives, triage every reviewer comment, reply to each thread, and resolve all threads — the gate passes only at reviewed-at-head with zero unresolved threads, and only then does § 5 Verify CI run. While waiting, approval-wait itself nudges a reviewer that stays silent past `PR_REVIEW_NUDGE_SECS` (see Nudging below). Some review bots submit a review object only when they have findings, so a clean re-analysis would leave this predicate unsatisfiable (vstack#654): set `PR_REVIEW_CHECK` to the exact name the trusted review bot publishes on analyzed heads (e.g. `Devin Review`) and a `success` signal of that name on the current head also satisfies the review-received predicate — matched on either evidence surface, a check-run conclusion or a commit-status context (vstack#681: some bots publish statuses, not check-runs) — every other condition (no standing CHANGES_REQUESTED, zero unresolved threads) still applies, and the JSON result names the satisfying signal in `review_evidence` (`"review"` or `"check"`; with `"check"`, `review_evidence_surface` reports `"check_run"` or `"status"`). Both surfaces are matched by name/context, so the setting must name a signal produced by the trusted review bot — the same user-configured trust model as `PR_REVIEW_NUDGE`. Note that a status-only reviewer's `success` cannot re-fire the repo's CI by itself — repos gating CI on review evidence need the status re-fire bridge (orch `DEVELOPMENT.md` § CI Triggering Patterns); without it, one bounded manual rerun-in-place of the failed gate run after evidence success is the documented fallback.
- **`off`** — no reviewer gate (repos with NO review bots and no reviewer policy). Skip the wait loop entirely and go straight to § 5 — the internal review (gate 1), CI (gate 2), and comment-hygiene (gate 3) gates still apply in full.

Record the resolved mode; for `off`, also record the legacy gate field the § 6.1 gate 4 check reads. Pass the value as a bare word — `workflow-state set` stores plain strings raw, so a pre-quoted value like `'"off"'` would store literal quote characters and break the gate 4 comparison (vstack#705):

```bash
.agents/skills/orch/scripts/workflow-state set [ISSUE_ID] pr_review.mode [GATE_MODE]
```

```bash
# off mode only:
.agents/skills/orch/scripts/workflow-state set [ISSUE_ID] pr_approval.gate off
```

The mode is explicit configuration by design — no auto-detection. An empty requested-reviewer list proves nothing (review bots never appear as requested reviewers before their first review), so only the project settings can state "this repo has no reviewers" or "this repo's reviewers comment but never approve."

Bot-SPECIFIC signals (emoji reactions, sticky-comment prose, checklist text) are never parsed for gating; this gate reads only GitHub-native review state, from any reviewer — human or bot.

**Nudging.** approval-wait nudges silent reviewers itself: when the mode's signal has not arrived within `PR_REVIEW_NUDGE_SECS` (default 600s, `0` disables) of the wait starting or of the head last changing, it posts the user-configured `PR_REVIEW_NUDGE` comment body on the PR — or, when that setting is empty, falls back to a GitHub-native re-review request to the PR's requested and past reviewers (silence when there is nobody to re-request). Each head SHA is nudged at most once; a push restarts the nudge clock and re-arms the nudge for the new head. Both keys live in `vstack.settings.toml` `[env]` next to the gate mode — the nudge text is project configuration, no bot names are built in.

**Reviewer-down flexibility.** `PR_REVIEW_ON_TIMEOUT` (default `block`) controls the deadline when a reviewer never posts — the "credits ran out" case. `block` reports `timeout` and step 1 prompts as above. `proceed` instead reports `proceeded` (routed above) so a dead reviewer does not stall the fleet. This is safe because the deadline is only reachable with **zero unresolved threads**: an open thread returns `comments` long before the wait expires, so `proceed` can never bypass an actual comment, only the *absence* of a review. It also carries no risk of skipping a live reviewer — evidence from **any** non-author reviewer satisfies the gate, so on a multi-reviewer repo `proceeded` only fires when *every* bot is silent. A `changes_requested` verdict is a real signal, not silence, and always blocks regardless of this setting.

The full cycle after any fix-up push is: push fixes → the head changes → wait for a NEW review of the new head (approval-wait nudges after `PR_REVIEW_NUDGE_SECS` if the reviewer stays silent) → triage, reply to, and resolve every thread → § 5 Verify CI (→ § 5.2 ci-fix cycles, bounded by `CI_FIX_MAX_CYCLES`, when red — each ci-fix push re-confirms this gate at its new head before re-verifying CI, vstack#726) → § 6 merge gates.

1. **Review wait loop.** Poll for the gate verdict and new review comments together (skip when `GATE_MODE` is `off`):
   ```bash
   .agents/skills/orch/scripts/approval-wait [PR_NUMBER] 30 900 --json --mode [GATE_MODE]
   ```
   The result is a JSON object: `status` (`approved`/`reviewed`/`changes_requested`/`comments`/`timeout`/`proceeded`/`error`) plus `review_decision`, `approvals`, `changes_requested`, and `unresolved_count`. approval-wait always emits it — no silent completion. In `approval` mode detection uses `gh pr view --json reviewDecision,latestReviews` (either signal: the branch-protection aggregate `reviewDecision == "APPROVED"`, or the latest-review-per-reviewer fallback when no protection is configured); any reviewer counts, human or bot. In `review` mode detection pins reviews to the current head SHA (re-read every poll, so a force-push resets the wait), excludes DISMISSED reviews and the PR author's own, blocks on a standing CHANGES_REQUESTED, and requires zero unresolved threads; with `PR_REVIEW_CHECK` set, a `success` signal of that trusted name on the current head — a check-run conclusion or a commit-status context (vstack#681) — counts as review evidence too, and `review_evidence` in the JSON reports which signal passed (`review_evidence_surface` names the surface for check evidence).

   Route on `status`:

   | `status` | Action |
   |----------|--------|
   | `approved`, `unresolved_count == 0` | Approval verdict recorded → step 2 |
   | `approved`, `unresolved_count > 0` | Approval recorded; run the triage pass below to clear the comments. If the pass pushed no commits, the approval stands → step 2 (thread hygiene is re-confirmed at the § 6.1 gate 3 final check); if it pushed commits, restart step 1 |
   | `reviewed` | Review of the current head recorded with zero unresolved threads → step 2 |
   | `proceeded` | Reviewer-down degrade (`PR_REVIEW_ON_TIMEOUT=proceed`): the deadline passed with **zero unresolved threads** and no reviewer evidence — every configured reviewer stayed silent (e.g. credits exhausted). Record it under its own state field (kept distinct from a user Force merge so provenance is preserved) so the § 6.1 gate 4 check reads it as an automated reviewer-down proceed, then → step 2. CI (§ 5) and the comment-hygiene gate (§ 6.1 gate 3) still apply in full: `.agents/skills/orch/scripts/workflow-state set [ISSUE_ID] pr_approval.reviewer_down true`. **If the JSON carries `outage_marker: "failed"`** (the repo configured `PR_REVIEW_OUTAGE_CONTEXT` but orch's status POST was rejected — e.g. no `statuses: write`), the repo-side CI gate got no signal and cannot recover on its own: do NOT proceed to idle § 5 against it — surface the failure and re-run step 1 once, or stop and hand back. `outage_marker: "posted"` (or absent) proceeds normally. |
   | `changes_requested` or `comments` | New review feedback: run the triage pass below, then restart step 1. In `review` mode this is the normal path — each reviewer comment lands as a thread (`comments`), the triage pass replies to and resolves every one, and the restarted wait returns `reviewed` once the head has a review and zero threads remain |
   | `timeout` | No gate verdict after 15 min (only when `PR_REVIEW_ON_TIMEOUT` is `block`/unset — with `proceed` a no-evidence deadline arrives as `proceeded` above) → Ask user: "No [GATE_MODE]-gate verdict on PR #[PR_NUMBER] after [ELAPSED] min" — `Force merge` \| `Keep waiting` \| `Stop here` |
   | `error` | Re-run step 1 once; if it repeats, report the error and ask user: `Keep waiting` \| `Stop here` |

   **Triage pass** (bounded by `pr_comment_review.iterations`, max 5 — read it before each pass; at the cap, present the remaining feedback and ask user: `Triage again` \| `Force merge` \| `Stop here`):
   - `⤵ workflows/review-pr-comments.md [PR_NUMBER] § 1-8 → § 4 step 1` with managed context — fixes real findings, replies to and resolves every comment.
   - Pushes made by a triage pass may dismiss or refresh existing reviewer approvals (stale-review dismissal), move the head past the reviewed commit, and re-trigger reviewer re-review — restarting step 1 already handles re-approval and re-review; no separate re-check is needed.

   **User choices on `timeout`:**
   - `Keep waiting` → restart step 1.
   - `Force merge` → record the override, then treat the review gate as met and continue to step 2 (the § 6.1 gates still apply):
     ```bash
     .agents/skills/orch/scripts/workflow-state set [ISSUE_ID] pr_approval.forced true
     ```
   - `Stop here` → § 6 with the review gate unmet (`MERGE_READY = false`); the PR stays open awaiting review. Skip § 5 — on approval-gated repos CI cannot start until the review verdict lands.

2. **Record the result** for the § 6.1 gate 4 check — gate status (`approved` or `reviewed` per mode, a user Force merge via `pr_approval.forced`, or a `proceeded` reviewer-down degrade via `pr_approval.reviewer_down`) and the `unresolved_count` at verdict time — then → § 5.

---

## 5. Verify CI

On always-on repos CI has been running since the PR was created or updated in § 2. On approval-gated repos, checks register only after the § 4 review gate completes — which is why this section runs after § 4. Neither case needs detecting: ci-wait treats "no checks yet" as pending within its registration grace window (`CI_WAIT_NO_CHECKS_GRACE`, default 180s), keeps a stale pre-approval aggregate failure pending while the current-head approved run is active, holds a concurrency-cancelled run's failure pending while any same-head substantive run — including a rerun attempt of an older run, which keeps its original run id and creation time — is queued or running, and fails closed when the fresh run fails or never publishes its replacement status. One exception needs repo-side wiring: when the § 4 evidence arrived as a commit status (a status-only reviewer), no PR workflow trigger fires on it, so a gate run that failed while that status was pending only recovers via the repo's status re-fire bridge (orch `DEVELOPMENT.md` § CI Triggering Patterns) — or, absent the bridge, via one bounded manual rerun-in-place of the failed gate run after the evidence success.

### 5.1 Wait for CI

1. **Wait for CI**:
   ```bash
   .agents/skills/orch/scripts/ci-wait [PR_NUMBER] --json
   ```
   The result is a JSON object: `status` (`complete`/`timeout`/`error`) plus `verdict` (`pass`/`fail`/`pending`). ci-wait always emits it — no silent completion.

2. **Handle CI result**:

   | Result | Action |
   |--------|--------|
   | ✅ `status=complete`, `verdict=pass` | → § 6 |
   | ❌ `status=complete`, `verdict=fail` | → § 5.2 |
   | ⏱ `status=timeout` or `status=error` | Re-run step 1 once; if it repeats → Ask user: `Skip CI` \| `Retry` \| `Abort` |

### 5.2 CI Failure Recovery

On first entry, read the ci-fix cycle budget:

```bash
.agents/skills/orch/scripts/orch-env CI_FIX_MAX_CYCLES 6
```

The printed value is `MAX_CYCLES` — the effective `CI_FIX_MAX_CYCLES` (process env > `vstack.settings.toml` `[env]` > default 6; non-numeric falls back to 6).

A rerun-in-place (`gh run rerun` / rerun-failed-jobs) re-executes the workflow definition and verifier state pinned at the original triggering event — a PR that changes gate or CI workflow behavior only exhibits its new behavior on a fresh head (new push → attempt-1 run), never via a rerun of an old attempt. Reruns are for flakes and re-gating on unchanged workflows; behavior changes need a new commit and push.

1. **Run Workflow**: `⤵ workflows/ci-fix.md [PR_NUMBER] § 1-7 → § 5.2 step 2`

2. **After ci-fix returns**:
   - If fix applied → ci-fix already pushed, re-confirmed the § 4 gate at the new head, and only then re-verified CI (its § 5). The ordering is deliberate (vstack#726): a recovery push dismisses or outdates exact-head review evidence, and on approval-gated repos CI for the new head starts only after the renewed evidence exists — re-confirming the review gate after ci-wait would deadlock those repos or read an intentionally red gate run as a fix failure. Record ci-fix's gate re-confirmation result as the § 4 result for the § 6.1 gate 4 check (skip the record when `GATE_MODE` is `off`), treat its final CI result as the § 5.1 result, and re-route via the § 5.1 step 2 table. If ci-fix instead returned a gate re-confirmation of `comments` or `changes_requested` (new review feedback on the fix push, no CI result yet), route that status through the § 4 step 1 table first, then re-enter § 5.1.
   - If fix not possible → Ask user: `Skip CI` | `Retry` | `Abort`

3. **Max [MAX_CYCLES] ci-fix cycles** per PR submission — keep routing CI failures back into step 1 until CI passes or the budget is spent.

4. **After max cycles** → § 6 with a failure report, never a bare "CI is failing": name the checks still failing (from the last ci-wait/ci-fix result), quote ci-fix's last error summary, and list what each cycle attempted, then note "CI failing after [MAX_CYCLES] ci-fix cycles, may need manual intervention".

---

## 6. Merge Gates and Standalone Summary

### 6.1 Merge Gates

A PR merges on exactly four gates — all deterministic. Bot-SPECIFIC signals (emoji reactions, sticky-comment prose, checklist text) are never parsed for gating; the review gate reads only GitHub-native review state, from any reviewer — human or bot. Gates 2 and 4 **verify results already recorded** by § 5 and § 4 — do not re-run the waits here; gate 3 is a final live check.

| # | Gate | Check |
|---|------|-------|
| 1 | Internal review verdict recorded | Managed: `review-pr.md` completed with verdict `pass` before this workflow. Standalone: workflow state `json_paths` is non-empty |
| 2 | CI green | § 5 result is `status=complete`, `verdict=pass` (equivalently: `gh pr checks [PR_NUMBER]` shows all checks passing) |
| 3 | Zero unresolved review comments | `pr-threads` reports `unresolved_count == 0` AND every actionable PR-level bot comment has a reply (tracked in `pr_comment_review.replied`) |
| 4 | Reviewer-gate verdict | Mode-aware per the § 4 `GATE_MODE`. `approval`: § 4 ended `approved` — `reviewDecision == "APPROVED"`, or, when `reviewDecision` is empty (no required-review protection), at least one reviewer whose latest review is APPROVED and none whose latest review is CHANGES_REQUESTED. `review`: § 4 ended `reviewed` — a non-author review of the current head with zero unresolved threads. Either mode: also met when `pr_approval.forced` (user Force merge) or `pr_approval.reviewer_down` (`PR_REVIEW_ON_TIMEOUT=proceed` reviewer-down degrade) is recorded. `off` (`pr_review.mode == "off"`, recorded alongside the legacy `pr_approval.gate == "off"`): not applicable for this repo |

1. **Gate 1** — standalone only (managed callers reach this workflow only after `review-pr.md` passed):
   ```bash
   .agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '{json_paths: (.json_paths // []), cycles: (.cycles // 0)}'
   ```
   If `json_paths` is empty, no internal review is recorded: report the unmet gate and recommend `orch review-pr [PR_NUMBER]` before merge.

2. **Gate 2** — verify the recorded § 5 result: met when the final CI result was `status=complete`, `verdict=pass`. Do not re-run ci-wait.

3. **Gate 3 — final live check**:
   ```bash
   .agents/skills/github/scripts/github.sh pr-threads [PR_NUMBER] --unresolved
   ```
   Read `.unresolved_count` from the JSON output.

   | `unresolved_count` | Action |
   |--------------------|--------|
   | `0` | Gate met |
   | `> 0` | Run ONE triage pass: `⤵ workflows/review-pr-comments.md [PR_NUMBER] § 1-8 → § 6.1 step 3` with managed context (bounded by `pr_comment_review.iterations`, max 5). If that pass pushed commits, re-confirm the § 4 gate with a short approval-wait (`approval-wait [PR_NUMBER] 15 300 --json --mode [GATE_MODE]`; skip when `GATE_MODE` is `off`), then re-run § 5 — review before CI holds after every push (vstack#726). Then re-run the gate 3 command once; if threads remain, present them and ask user: `Triage again` \| `Force merge` \| `Stop here` |

4. **Gate 4** — verify the recorded § 4 result: met when the wait ended `approved` (approval mode) or `reviewed` (review mode), when `pr_approval.forced` was recorded (explicit user Force merge) or `pr_approval.reviewer_down` was recorded (a `proceeded` reviewer-down degrade under `PR_REVIEW_ON_TIMEOUT=proceed`), or when the mode is `off` (`pr_review.mode` / legacy `pr_approval.gate` — reviewer-less repo, gate not applicable). Read the recorded mode with:
   ```bash
   .agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '(.pr_review.mode // .pr_approval.gate // "") | gsub("\"";"")'
   ```
   The `gsub` strips literal quote characters — state files written by the pre-vstack#705 docs stored the mode as `"\"off\""`, and this read compares equal to `off` for both forms. Do not re-run the wait here — the gate 3 escape hatch above already re-confirms the gate after any late pushes.

5. **Record results**: `MERGE_READY = true` only when all four gates are met (gate 4 by verdict or recorded force).

### 6.2 Standalone Summary

**If managed**: Skip → § 7

**If standalone**:

1. **Reconcile fixes**:

   Run Workflow: `⤵ workflows/fix-reconcile.md § 1-9 → § 6.2 step 2` with context:
   - `issue_id`: [ISSUE_ID]
   - `pr_number`: [PR_NUMBER]

2. **Post summary** — skip if no fixes AND no issues created. Fix SHAs come from workflow state, which § 2 step 1 reconciled after any rebase; resolve artifact-sourced SHAs (perf `benchmark_commit`) through `.rebase_map` — publishing a stale pre-rebase SHA is forbidden (vstack#728). Write to a file first (same backtick hazard as PR body):
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
   | Review gate | ✅ approved / ✅ reviewed / ⏳ pending / forced / off (no reviewer policy) |
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

**If managed**: Return to the parent workflow's next section with the § 6.1 gate results (`MERGE_READY`, the § 4 gate mode and status, unresolved thread count, the § 5 CI verdict).

**If standalone**: Session complete — PR submitted. Summary presented in § 6.2.
