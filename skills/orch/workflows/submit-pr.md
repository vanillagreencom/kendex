# Submit PR Workflow

Run a local pre-PR review, push, create or update the PR, triage review comments, wait for the reviewer-gate verdict, verify CI, and confirm the merge gates. The review gate (§ 4) runs before CI verification (§ 5) so repos that start CI only after a review verdict never deadlock.

| Command | Behavior |
|---------|----------|
| `submit-pr` | Submit the current branch as a PR |
| `submit-pr [PR#]` | Manage an existing PR |
| (from start-worktree) | Managed lifecycle with caller context |

**Caller context** (via `⤵`): `worktree`; `lifecycle` — `"managed"` (return at § 7) or `"self"` (default); `issue_id` — the workflow-state key, the normalized issue ID, never the bare GitHub issue number.

**With a PR number**: `github.sh pr-issue [PR_NUMBER] --format=text` gives `ISSUE_ID`; `worktree exists`/`worktree path` give `WT_PATH`, or ask before creating one when already inside the PR checkout. Resolve `TRACKER` per [Tracker Resolution](../SKILL.md#tracker-resolution). With no argument, `WT_PATH` is the current directory.

**Standalone init** (`lifecycle: "self"`): resolve `ISSUE_ID` with `git-context issue-from-branch .`, then `workflow-state exists --json [ISSUE_ID]`; when absent, initialize with `git-context branch [WT_PATH]` and `workflow-state init`.

---

## 1. Preflight And Local Review

### 1.1 Preflight

```bash
.agents/skills/orch/scripts/resolve-base-branch "[WORKTREE_PATH]"
.agents/skills/orch/scripts/git-context branch "[WORKTREE_PATH]"
git -C "[WORKTREE_PATH]" status --porcelain
git -C "[WORKTREE_PATH]" diff "origin/[BASE_BRANCH_FROM_PREVIOUS_COMMAND]"...HEAD --stat
```

Stop before pushing when the branch is empty (detached HEAD), equals the base branch, the working tree is dirty, or the committed diff against the base is empty. In managed lifecycle, return the failed preflight to the caller so the dev agent can normalize the branch and clean the worktree. Never create a PR from dirty or detached state.

### 1.2 Local Pre-PR Review

Review bots post on their own timeline and never block submission, so drain what one would surface *before* the PR exists — locally, at local speed, with no bot round-trip.

**Skip if** any holds: `lifecycle` is `"managed"` (the caller's `review-pr.md` cycle already ran the external review of this diff); a PR number argument was provided (arrived comments are triaged in § 3); or `.agents/skills/second-opinion/scripts/second-opinion` does not exist.

```bash
mkdir -p [WORKTREE_PATH]/tmp
.agents/skills/orch/scripts/git-context timestamp epoch
.agents/skills/orch/scripts/git-context timestamp compact
.agents/skills/second-opinion/scripts/second-opinion review --cwd [WORKTREE_PATH] --output [WORKTREE_PATH]/tmp/review-local-[TIMESTAMP_FROM_PREVIOUS_COMMAND].json
```

Use the epoch output as `LOCAL_STARTED_AT` — captured *before* the review writes, so a stale or misdated artifact is rejected the way glob mode rejects one:

```bash
.agents/skills/orch/scripts/review-artifact-check --file "$LOCAL_OUTPUT" [LOCAL_STARTED_AT]
```

`ok == false`, or any non-zero exit, → report the `reason` and continue to § 2. Local review is advisory, never a submission blocker, and none of those outcomes is a pass.

Route the findings per the `review-finding` schema. No blockers and no `category: "fix"` suggestions → § 2, the diff is drained. Otherwise delegate: `⤵ workflows/dev-fix.md § 1-3 → § 1.2 tail` with context `worktree`, `lifecycle: "managed"`, `issue_id`, `items` (blockers plus fix-category suggestions), `source: local-review`. `category: "issue"` suggestions that clear the filing bar ([references/finding-disposition.md](../references/finding-disposition.md)) go through `⤵ .agents/skills/project-management/workflows/audit-issues.md --issues [FILE_PATH] § 1-9`, with the created IDs listed in the PR body.

**The loop is bounded at one confirming pass.** If dev-fix applied commits, run the review once more over the updated diff, then go to § 2 regardless of what it found. If nothing was applied, → § 2.

---

## 2. Push And Submit

1. **Push**:

   ```bash
   .agents/skills/worktree/scripts/worktree push "[WORKTREE_PATH]" --set-upstream
   ```

   **Rebase-map reconciliation (required).** `worktree push` auto-rebases onto the updated base, which legitimately rewrites every branch commit, and prints one `rebase-map: [OLD_SHA] [NEW_SHA]` line per rewritten commit (`[NEW_SHA]` is the literal word `dropped` when the replayed commit vanished because its patch was already upstream). SHAs recorded before the push — `fixed_items`, `pr_comment_review.fixes`, a perf QA `benchmark_commit` — now name commits that no longer exist. When the push output carries any `rebase-map:` lines, reconcile before anything publishes them. Publishing an unreconciled pre-rebase SHA is forbidden.

   Record the map, one command per mapping line, storing `dropped` literally:

   ```bash
   .agents/skills/orch/scripts/workflow-state update [ISSUE_ID] '.rebase_map = (.rebase_map // {}) + {"[OLD_SHA]": "[NEW_SHA]"}'
   ```

   Then rewrite every stored fix commit that matches a mapped old SHA — a recorded short SHA matches when it is a prefix of `[OLD_SHA]`, and is replaced by `[NEW_SHA]` truncated to the recorded length, one command per matching item:

   ```bash
   .agents/skills/orch/scripts/workflow-state update [ISSUE_ID] '(.fixed_items[]? | select(.commit == "[RECORDED_SHA]") | .commit) = "[MAPPED_SHA]"'
   ```
   ```bash
   .agents/skills/orch/scripts/workflow-state update [ISSUE_ID] '(.pr_comment_review.fixes[]? | select(.commit == "[RECORDED_SHA]") | .commit) = "[MAPPED_SHA]"'
   ```

   Regenerate any already-drafted publication text from the reconciled state, and resolve every SHA sourced from a review or QA artifact through `.rebase_map` before publishing it — follow the chain until no key matches, since a later rebase maps new → newer.

2. **Check for an existing PR**:

   ```bash
   .agents/skills/orch/scripts/pr-view-json "[WORKTREE_PATH]" --json number,state
   ```

   `status` of `no_pr` means create one in step 4. Stop and report auth, token, timeout, or parse errors.

3. **Build the PR body.** Write it to a file — inline bodies with backticks or fenced blocks corrupt under shell command substitution. Use the harness file-write tool or `apply_patch`, never redirection or a heredoc, at `[WORKTREE_PATH]/tmp/pr-body-[ISSUE_ID]-[TIMESTAMP].md` (`git-context timestamp compact`), and use that path as `BODY_FILE`.

   ```markdown
   ## Summary
   [1-3 bullets describing the changes]

   ## Context
   - **[DECISION_ID]**: [ONE_LINE_SUMMARY] — `[DECISION_FILE_PATH]`
   - **Research**: [TITLE] — `[RESEARCH_FILE_PATH]`

   ## Completed Issues
   - Closes [ISSUE_ID] - [TITLE]
     - Closes [SUB_ISSUE_1] - [SUB_TITLE]

   ## Created Issues
   - [ISSUE_ID] - [TITLE] — Project: [PROJECT]

   ## QA Metrics
   [Results from the QA agents that ran — project-configurable.]

   ## Test Plan
   [validation steps]
   ```

   Omit empty sections. Decision paths come only from `decisions search --issue [ISSUE_ID]`, each verified with `test -f [DECISION_FILE_PATH]` (one command per path) and omitted on failure. Every published SHA must be post-reconciliation.

4. **Create or update the PR.** CI configured on `pull_request` runs from the moment the PR exists — orch never defers, queues, or gates it behind bot review activity. Approval-gated repos start their heavy CI only after the § 4 verdict; that is repo-side configuration (`DEVELOPMENT.md` § CI Triggering Patterns) and needs no detection here.

   ```bash
   .agents/skills/github/scripts/github.sh -C "[WORKTREE_PATH]" pr-create --title "[PREFIX]([ISSUE_ID]): [ISSUE_TITLE]" --body-file "$BODY_FILE"
   ```

   With an existing PR, update the body instead:

   ```bash
   .agents/skills/github/scripts/github.sh -C "[WORKTREE_PATH]" pr-edit-body "$PR_NUM" --body-file "$BODY_FILE"
   ```

   `[ISSUE_TITLE]` comes from `linear.sh cache issues get [ISSUE_ID]` or `gh issue view [N] --json title --jq '.title'`.

---

## 3. Async Comment Triage

Review bots may post minutes or hours after the PR opens. **Bot prose is never a gate signal** — emoji reactions, sticky comments, and checklist text are never parsed for gating. Triage what exists now and move on: the § 4 gate polls for the verdict and new comments together, the § 6.1 gates require every comment replied to and resolved, and anything arriving after merge gets a follow-up fix or an explicit tracking issue. Every bot comment still gets a reply and a resolution.

```bash
.agents/skills/github/scripts/github.sh pr-threads [PR_NUMBER] --unresolved
```

`.unresolved_count == 0` → § 3.2. Otherwise **Run Workflow**: `⤵ workflows/review-pr-comments.md [PR_NUMBER] § 1-8 → § 3 tail` with managed context, then record the results — one tool call per block, since each append runs per item:

```bash
.agents/skills/orch/scripts/workflow-state append [ISSUE_ID] pr_comment_review.fixes '{"description":"[DESC]","location":"[LOC]","commit":"[SHA]","source":"[SOURCE]"}'
```
```bash
.agents/skills/orch/scripts/workflow-state append [ISSUE_ID] pr_comment_review.issues_created "[CREATED_ISSUE_ID]"
```
```bash
.agents/skills/orch/scripts/workflow-state append [ISSUE_ID] pr_comment_review.skipped '{"description":"[DESC]","reason":"[REASON]"}'
```
```bash
.agents/skills/orch/scripts/workflow-state increment [ISSUE_ID] pr_comment_review.iterations
```

Fixes pushed during triage were already replied to and resolved by that workflow. Do not wait for a bot re-review round — late comments land in threads the § 4 gate or the § 6.1 gate-3 check catches.

Issues created during triage need implementing before merge, bounded at two re-submit cycles:

```bash
.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '.submit_cycles // 0'
```

At 2 or more → § 3.2 with the note "max re-submit cycles reached, created issues may need manual implementation". Otherwise increment `submit_cycles`, implement via `⤵ workflows/dev-start.md § 1-4`, review via `⤵ workflows/review-pr.md § 1-9` (both managed, same `worktree` and `issue_id`), then re-enter § 2 to push and update the PR body with the new `Closes` lines.

### 3.2 Golden Baselines

**Skip if** the issue does not carry the `design` label (`linear.sh cache issues get [ISSUE_ID] --format=compact`, or `gh issue view [N] --json labels`).

Capture golden baselines in the worktree with the project's visual QA tooling; if the project has no baseline-capable target, skip and report why. Baselines are platform-specific, so commit and push without retriggering CI:

```bash
git -C [WT_PATH] add [BASELINE_PATH]/
git -C [WT_PATH] commit -m "chore: update golden baselines [skip ci]"
.agents/skills/worktree/scripts/worktree push [WT_PATH] --no-rebase
```

---

## 4. Review Gate

The review gate runs **before** CI verification, universally, with no repo detection: consuming repos may configure CI to start only after a review verdict, so waiting on CI first would deadlock them. On always-on repos, verifying CI afterwards simply returns quickly.

```bash
.agents/skills/orch/scripts/approval-wait --resolve-mode
```

The printed value is `GATE_MODE` — `approval`, `review`, or `off`. The resolution order is implemented once in approval-wait and never re-derived here; full semantics in [references/gates.md](../references/gates.md). The mode is explicit configuration by design — no auto-detection. Bot-specific signals are never parsed; this gate reads only GitHub-native review state, from any reviewer, human or bot.

Record the resolved mode, passing the value as a bare word (`workflow-state set` stores plain strings raw, so a pre-quoted `'"off"'` would store literal quotes and break the gate-4 comparison):

```bash
.agents/skills/orch/scripts/workflow-state set [ISSUE_ID] pr_review.mode [GATE_MODE]
```

For `off` also record the legacy field the gate-4 check reads, then skip the wait entirely and go to § 5 — the internal review, CI, and comment-hygiene gates still apply in full:

```bash
.agents/skills/orch/scripts/workflow-state set [ISSUE_ID] pr_approval.gate off
```

1. **Wait.** Poll for the verdict and new comments together:

   ```bash
   .agents/skills/orch/scripts/approval-wait [PR_NUMBER] 30 --json --mode [GATE_MODE]
   ```

   No `max_wait` positional, deliberately: the budget resolves through `PR_REVIEW_WAIT_SECS`, the per-repo review quiet-period knob. approval-wait always emits a JSON result and nudges a silent reviewer itself after `PR_REVIEW_NUDGE_SECS`, once per head SHA, with the clock restarting on every push.

   | `status` | Action |
   |----------|--------|
   | `approved`, `unresolved_count == 0` | → step 2 |
   | `approved`, `unresolved_count > 0` | Approval recorded; run the triage pass below. Pushed no commits → the approval stands, → step 2 (thread hygiene is re-confirmed at gate 3). Pushed commits → restart step 1 |
   | `reviewed` | Review of the current head with zero unresolved threads → step 2 |
   | `proceeded` | Reviewer-down degrade under `PR_REVIEW_ON_TIMEOUT=proceed`: the deadline passed with zero unresolved threads and no reviewer evidence. Record it under its own field so provenance stays distinct from a user force, then → step 2. CI and gate 3 still apply in full. The proceed is a LOCAL verdict — orch posts no status and manufactures no review evidence, so a repo whose CI independently gates on review evidence stays blocked unless its gate is disabled or an operator posts the engine's override |
   | `changes_requested` or `comments` | New feedback: run the triage pass, then restart step 1. In `review` mode this is the normal path — each comment lands as a thread, triage replies and resolves, and the restarted wait returns `reviewed` |
   | `timeout` | No verdict within the budget → ask the user: `Force merge` \| `Keep waiting` \| `Stop here` |
   | `error` | Re-run step 1 once; if it repeats, report and ask: `Keep waiting` \| `Stop here` |

   ```bash
   .agents/skills/orch/scripts/workflow-state set [ISSUE_ID] pr_approval.reviewer_down true
   ```

   **Triage pass**, bounded by `pr_comment_review.iterations` (max 5; at the cap present the remaining feedback and ask `Triage again` | `Force merge` | `Stop here`): `⤵ workflows/review-pr-comments.md [PR_NUMBER] § 1-8 → § 4 step 1` with managed context. A push made during triage may dismiss approvals and move the head past the reviewed commit; restarting step 1 already handles that.

   **On `timeout`**: `Keep waiting` restarts step 1; `Force merge` records the override and continues to step 2 with the § 6.1 gates still applying; `Stop here` goes to § 6 with `MERGE_READY = false` and skips § 5, since an approval-gated repo cannot start CI without the verdict.

   ```bash
   .agents/skills/orch/scripts/workflow-state set [ISSUE_ID] pr_approval.forced true
   ```

2. **Record the result** for gate 4 — the gate status and the `unresolved_count` at verdict time — then → § 5.

The full cycle after any fix-up push is: push → the head changes → wait for a NEW review of the new head → triage, reply to, and resolve every thread → § 5 Verify CI → § 6 merge gates.

---

## 5. Verify CI

On always-on repos CI has been running since § 2; on approval-gated repos checks register only after § 4 completes, which is why this section runs second. Neither needs detecting: ci-wait treats "no checks yet" as pending inside `CI_WAIT_NO_CHECKS_GRACE`, keeps a stale pre-approval failure pending while the current-head approved run is active, holds a concurrency-cancelled run's failure pending while any same-head substantive run is queued or running, and fails closed when the fresh run fails or never publishes its replacement status.

```bash
.agents/skills/orch/scripts/ci-wait [PR_NUMBER] --json
```

| Result | Action |
|--------|--------|
| `status=complete`, `verdict=pass` | → § 6 |
| `status=complete`, `verdict=none` | Repo has no CI configured (no active workflows, no required checks). Record `ci: none` in workflow state and → § 6 — this is a documented route, not a failure or an override |
| `status=complete`, `verdict=fail` | → § 5.1 |
| `status=timeout` or `status=error` | Re-run once; if it repeats, ask: `Skip CI` \| `Retry` \| `Abort` |

### 5.1 CI Failure Recovery

```bash
.agents/skills/orch/scripts/orch-env CI_FIX_MAX_CYCLES 6
```

The printed value is `MAX_CYCLES`. A rerun-in-place re-executes the workflow definition and verifier state pinned at the original triggering event, so a PR that changes gate or CI workflow behavior only exhibits it on a fresh head — reruns are for flakes and re-gating on unchanged workflows.

**Run Workflow**: `⤵ workflows/ci-fix.md [PR_NUMBER] § 1-6 → § 5.1 tail`. ci-fix pushes, re-confirms the § 4 gate at the new head, and only then re-verifies CI — that ordering is deliberate, because a recovery push outdates exact-head review evidence and gated repos start CI for the new head only once renewed evidence exists. Record its gate re-confirmation as the § 4 result (skip when `GATE_MODE` is `off`), treat its final CI result as the § 5 result, and re-route through the table above. A returned `comments` or `changes_requested` routes through the § 4 step-1 table first, then re-enters § 5.

Keep routing failures back into ci-fix until CI passes or `MAX_CYCLES` is spent. At the cap, go to § 6 with a failure report that names the checks still failing, quotes ci-fix's last error summary, and lists what each cycle attempted — never a bare "CI is failing".

---

## 6. Merge Gates And Summary

### 6.1 Merge Gates

A PR merges on exactly four deterministic gates. Gates 2 and 4 **verify results already recorded** by § 5 and § 4 — do not re-run the waits; gate 3 is a final live check.

| # | Gate | Check |
|---|------|-------|
| 1 | Internal review verdict recorded | Managed: `review-pr.md` completed with verdict `pass`. Standalone: `json_paths` is non-empty |
| 2 | CI green | The § 5 result is `status=complete` with `verdict=pass`, or `verdict=none` (repo has no CI configured — satisfied with a `CI: none configured` note in the summary) |
| 3 | Zero unresolved review comments | `pr-threads` reports `unresolved_count == 0` AND every actionable PR-level bot comment has a reply (tracked in `pr_comment_review.replied`) |
| 4 | Reviewer-gate verdict | Mode-aware per `GATE_MODE`. `approval`: § 4 ended `approved`. `review`: § 4 ended `reviewed`. Either mode is also met by a recorded `pr_approval.forced` or `pr_approval.reviewer_down`. `off`: not applicable for this repo |

**Gate 1** — standalone only; managed callers reach this workflow only after `review-pr.md` passed:

```bash
.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '{json_paths: (.json_paths // []), cycles: (.cycles // 0)}'
```

Empty `json_paths` means no internal review is recorded: report the unmet gate and recommend `orch review-pr [PR_NUMBER]`.

**Gate 2** — verify the recorded result; do not re-run ci-wait. `ci-wait verdict=pass` is not the same as "every check in the rollup is green": ci-wait and `github.sh pr-merge --check` both scope the rollup to the head's current substantive run before classifying, while raw `gh pr checks` reads the whole rollup — which can still hold a duplicate same-head dispatch cancelled by concurrency, surfacing as zero-second failures. Raw `gh pr checks` output is never the gate. A `pr-merge --check` refusal right after a green § 5 reports state that moved since, not a wrong § 5 verdict: identify which run each reported failure belongs to (`gh pr checks [PR_NUMBER] --json name,state,link,workflow` — the run id is in `link`, and run ids do not order runs by execution, since a rerun executes under the original run's id) before treating it as real. If a refusal survives and every reported failure belongs to a superseded or duplicate run while the required aggregate is green, report it with the run ids rather than silently forcing or abandoning the merge.

**Gate 3** — final live check:

```bash
.agents/skills/github/scripts/github.sh pr-threads [PR_NUMBER] --unresolved
```

`unresolved_count > 0` runs ONE triage pass (`⤵ workflows/review-pr-comments.md [PR_NUMBER] § 1-8 → § 6.1 gate 3`, managed, bounded by the max-5 iteration cap). If that pass pushed commits, re-confirm the § 4 gate with a short wait (skip when `GATE_MODE` is `off`), then re-run § 5 — review before CI holds after every push:

```bash
.agents/skills/orch/scripts/approval-wait [PR_NUMBER] 15 300 --json --mode [GATE_MODE]
```

Re-run the gate-3 command once; if threads remain, present them and ask: `Triage again` | `Force merge` | `Stop here`.

**Gate 4** — verify the recorded § 4 result. Read the recorded mode; the `gsub` strips literal quote characters left by older state files:

```bash
.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '(.pr_review.mode // .pr_approval.gate // "") | gsub("\"";"")'
```

`MERGE_READY = true` only when all four gates are met.

### 6.2 Standalone Summary

**Skip if** managed → § 7.

Post a summary comment when there were fixes or created issues. Fix SHAs come from workflow state, which § 2 reconciled after any rebase; artifact-sourced SHAs resolve through `.rebase_map` first. Write the summary to a file (same backtick hazard as the PR body) and post it:

```bash
.agents/skills/github/scripts/github.sh post-comment [PR_NUMBER] --body-file "$SUMMARY_FILE"
```

Linear items also get it on the issue; GitHub items get linkage through `Closes #N` in the PR body:

```bash
.agents/skills/linear/scripts/linear.sh comments create [ISSUE_ID] --body-file "$SUMMARY_FILE"
```

```markdown
## Recommendations Processed

### Fixed in PR
- [SOURCE]: [ITEM] — [SHA]

### Issues Created
- [ISSUE_ID] - [TITLE] — [PROJECT]

### Skipped
- [SOURCE]: [ITEM] — [REASON]
```

<output_format>

### ✅ PR SUBMITTED — #[PR_NUMBER]

| Metric | Value |
|--------|-------|
| PR | #[PR_NUMBER] |
| CI | ✅ passing / ❌ failing |
| Review gate | ✅ approved / ✅ reviewed / ⏳ pending / forced / off (no reviewer policy) |
| Unresolved threads | [N] |
| Comment iterations | [N] |
| Fixes applied | [N] |
| Issues created | [N] |

</output_format>

**Offer merge** — skip unless `MERGE_READY`. Ask `orch merge-pr [PR_NUMBER]` | `Skip`; on merge, `⤵ workflows/merge-pr.md [PR_NUMBER] § 1-7 → end`.

---

## 7. Return

**Managed**: return to the parent workflow's next section with the § 6.1 gate results (`MERGE_READY`, the § 4 gate mode and status, the unresolved thread count, the § 5 CI verdict). **Standalone**: session complete.
