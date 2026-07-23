# PR Merge Workflow

Verify conditions and safely merge PR(s).

## Inputs

| Command | Flow |
|---------|------|
| `merge-pr` | List ready PRs, user selects |
| `merge-pr [N]` | Merge specific PR |
| `merge-pr all` | Batch merge all ready PRs |

## 1. Identify Candidates

```bash
.agents/skills/github/scripts/github.sh pr-list-ready
```

If no argument provided: present list, ask user for selection.

If `--all`: process all ready PRs sequentially.

## 2. Cross-Check PRs (if batch merge)

When `all` or 2+ PRs requested:

### 2.1 Run Quick Pre-Check

```bash
.agents/skills/github/scripts/github.sh pr-cross-check [PR_NUMBERS] --quick --json
```
Use the output as `QUICK`.

If quick check finds high-severity issues (conflicts): Show issues, abort early.

### 2.2 Run Full Verification (if quick check passes)

```bash
.agents/skills/github/scripts/github.sh pr-cross-check [PR_NUMBERS] --verify --json
```
Use the output as `VERIFY`.

Creates temp worktree from main, merges PRs sequentially, runs build + test, reports + cleans up.

### 2.3 Handle Results

| `can_batch_merge` | Action |
|-------------------|--------|
| `true` | Show "Verification passed", **→ Jump to § 3** with `merge_order` |
| `false` | Show failure details (merge/build/test logs), Ask user: `Abort` \| `Force anyway` |

**On failure**, display details:
```
Verification failed:
  [FAILURE_TYPE]: [FAILURE_DESCRIPTION]
     → [SUGGESTED_REMEDIATION]
```

## 3. Check Merge Readiness

For each PR:

```bash
.agents/skills/github/scripts/github.sh pr-merge [PR_NUMBER] --check
```
Use the output as `CHECK`.

### 3.1 Resolve transient readiness blockers before prompting

If `CHECK.transient == true`, route by the transient issue prefix before any
user prompt. Transient issue prefixes include `unknown:` (GitHub still
computing mergeable status), `ci_pending:` (checks still running),
`ci_unconfigured:`, and `ci_fetch_failed:`. Treat `CHECK.transient` as the
contract for whether the block may resolve by waiting, but choose the wait path
from the specific issue prefix.

For `unknown:` only, wait for GitHub's merge-state computation and re-check:

```bash
.agents/skills/github/scripts/github.sh await-mergeable [PR_NUMBER]
.agents/skills/github/scripts/github.sh pr-merge [PR_NUMBER] --check
```
Use the second command output as `CHECK`.

`await-mergeable` polls `state` + `mergeStateStatus` (never `mergeable` — stays UNKNOWN after merge, hangs forever). Exit 124 on timeout → surface to user.

For `ci_pending:`, wait on CI with the bounded CI watcher, then re-check:

```bash
.agents/skills/orch/scripts/ci-wait [PR_NUMBER] 15 600
.agents/skills/github/scripts/github.sh pr-merge [PR_NUMBER] --check
```
Use the second command output as `CHECK`. If `ci-wait` exits nonzero or times
out, surface that result to the user, re-run `pr-merge --check` once for fresh
state, then continue to § 3.2 without another automatic wait loop.

For `ci_fetch_failed:` or `ci_unconfigured:`, use a short bounded backoff before
re-checking:

```bash
sleep 30
.agents/skills/github/scripts/github.sh pr-merge [PR_NUMBER] --check
```
Use the second command output as `CHECK`. Repeat at most three total checks
before continuing to § 3.2 with the latest `CHECK`.

Do not repeat § 3.1 indefinitely. Continue to § 3.2 when `CHECK.transient` is
`false` or when the relevant bounded wait/backoff path times out.

### 3.2 Parse and act

Parse result and present to user:

| `can_merge` | Action |
|-------------|--------|
| `true` | Show warnings if any, **→ Jump to § 4** |
| `false` | Show issues, Ask user: `Skip` \| `Fix and retry` \| `Force merge` |

**On issues**, display with guidance:
```
PR #N has issues:
  [CHECK_NAME]: [DESCRIPTION]
    → [SUGGESTED_FIX]
```

**On warnings only**, display and confirm:
```
PR #N ready with warnings:
  ⚠ [WARNING_TYPE]: [DESCRIPTION]
```
→ Ask user: `Merge anyway` | `Review first`

Two of the warnings are merge gates, not advice:

- `unresolved_threads` — zero unresolved review threads is required at merge time. Route to `review-pr-comments` to reply and resolve first; merge past unresolved threads only on explicit user override.
- `not_approved` — first read the project's reviewer-gate mode with `.agents/skills/orch/scripts/approval-wait --resolve-mode` (`PR_REVIEW_GATE`, with the legacy `PR_APPROVAL_GATE` mapping `on` → `approval` and `off` → `off`; default `approval`). Use the printed value as `GATE_MODE` and route:
  - `off` (reviewer-less repo) — `not_approved` is informational only; do not gate on it.
  - `review` — commenting-only reviewers never approve, so `not_approved` is expected; the gate is instead a formal review of the current head commit from a non-author reviewer (any state — COMMENTED counts) plus zero unresolved threads. Poll with `.agents/skills/orch/scripts/approval-wait [PR_NUMBER] 30 900 --json --mode review` and treat `reviewed` as the met gate (approval-wait nudges silent reviewers per `PR_REVIEW_NUDGE`/`PR_REVIEW_NUDGE_SECS`, once per head). With `PR_REVIEW_ON_TIMEOUT=proceed`, a deadline reached with zero unresolved threads and no reviewer evidence returns `proceeded` (exit 0) instead of `timeout` — treat it as a met gate (a reviewer-down proceed) and continue to § 4, recording it in the § 7 report so the reviewer-down merge is visible. Unlike `submit-pr`, `merge-pr` gates live and initializes no workflow-state record (and resolves no `[ISSUE_ID]` until § 4.1), so there is no `pr_approval` field to set here — the § 7 note is the provenance. It only fires when every reviewer stayed silent; an open thread or a `changes_requested` still blocks. **Exception — `outage_marker: "failed"`** (the repo set `PR_REVIEW_OUTAGE_CONTEXT` but orch's status POST was rejected): the CI gate got no signal and cannot recover, so do NOT continue to idle the § 5 CI wait against it — surface the failure and re-poll once or hand back; `outage_marker: "posted"` (or absent) continues normally.
  - `approval` — a GitHub-native approval verdict is required: `reviewDecision == "APPROVED"`, or, when `reviewDecision` is empty (no required-review protection), at least one reviewer whose latest review is APPROVED and none whose latest review is CHANGES_REQUESTED (any reviewer counts, human or bot). Without it, do not auto-merge: poll with `.agents/skills/orch/scripts/approval-wait [PR_NUMBER] 30 900 --json` or ask the user. `PR_REVIEW_ON_TIMEOUT=proceed` applies here too — the poller returns `proceeded` (exit 0) instead of `timeout` when the deadline is reached with zero unresolved threads and no reviewer engagement at all (in approval mode an active COMMENTED review still times out, since a reviewer that engaged but did not approve is not "down"); treat `proceeded` as a met gate (a reviewer-down proceed) and continue to § 4, recording it in the § 7 report. As above, `merge-pr` keeps no workflow-state, so the § 7 note is the provenance rather than a `pr_approval` field. (No `outage_marker` handling here: the marker is review-mode only — `approval-wait` posts it only in `--mode review` — so approval-mode JSON never carries an `outage_marker` field. The `review` arm above owns that exception.)

  Merge past a missing gate verdict only on explicit user override (`Force merge`).

Bot-specific signals — emoji reactions, sticky-comment prose, checklist text — are never parsed as merge gates; only the GitHub-native review state (approval verdict or review-at-head per `GATE_MODE`) and thread resolution count.

## 4. Prepare for Merge

### 4.1 Check Worktree Cleanup

```bash
.agents/skills/github/scripts/github.sh pr-issue [PR_NUMBER] --format=text
```
Use the output as `ISSUE`.

If `ISSUE` is non-empty, check whether its worktree exists:

```bash
.agents/skills/worktree/scripts/worktree exists "$ISSUE"
```

If worktree exists: Ask user `"Cleanup worktree for [ISSUE_ID]?"` → store for § 5.

### 4.2 Verify Bot Token

```bash
.agents/skills/github/scripts/github.sh bot-token
```
Read `.configured` from the JSON output.

If `false`: Ask user: `Merge as current user` | `Abort`

### 4.3 Detach Orphaned Children (Cascade-Done Guard)

Linear cascades the parent's Done state to all children. Any `make_child`
issue still pending under `[ISSUE]` will be silently flipped to Done on
merge. Detach them first.

**Skip if** no `[ISSUE]` extracted in § 4.1, or `TRACKER=github` (no cascade — Linear only).

1. **List pending children** and partition by `state_type`:
   ```bash
   .agents/skills/linear/scripts/linear.sh cache issues children [ISSUE] --pending --recursive
   ```
   - **safe** — `state_type` is `backlog` or `unstarted` (Todo). Capture IDs as `[SAFE_IDS]`.
   - **active** — anything else (`started` = In Progress / In Review / custom started states; `triage`; any non-terminal custom type). Capture id + title + state name as `[ACTIVE]`.

   Both empty → § 5.

2. **`[ACTIVE]` non-empty** — pause and prompt the user before touching anything:

   > Cannot merge `[ISSUE]` cleanly. These sub-issues are still active and would be cascade-Done:
   > - `[ID]`: [title] ([state name])
   >
   > For each, was the work landed in this PR?
   > 1. Yes — close as Done (`linear.sh issues complete [ID]`)
   > 2. No — detach into the follow-up bundle (append to `[SAFE_IDS]`)
   > 3. Abort merge — resolve manually first

   Apply per-orphan, then continue. Choice 3 aborts § 4.3 entirely.

3. `[SAFE_IDS]` empty after step 2 → § 5.

4. **Rebundle `[SAFE_IDS]` under a new parent.**

   a. Read parent metadata. Capture `.title` → `[PARENT_TITLE]`, `.project.id` → `[PARENT_PROJECT]`, joined labels → `[PARENT_LABELS]`:
      ```bash
      .agents/skills/linear/scripts/linear.sh cache issues get [ISSUE]
      ```
      Read `.title`, `.project.id // .project.name // ""`, and joined `.labels.nodes[].name` from the JSON output.

   b. Compute `[BUNDLE_PRIORITY]` (highest-priority across `[SAFE_IDS]`; Linear: `1`=Urgent…`4`=Low, lower=higher; default `3`):
      ```bash
      .agents/skills/linear/scripts/linear.sh cache issues children [ISSUE] --pending --recursive
      ```
      Read priorities from the JSON output and use the minimum positive priority, or `3` when none exists.

   c. Build `[BUNDLE_DESC]` per `.agents/skills/project-management/templates/parent-issue-template.md` — 1-2 sentence summary synthesized from orphan titles, `## Sub-Issues` listing each safe ID, `## Context` line: `Detached from [ISSUE] before merge to prevent cascade-Done.`

   d. Create the bundle. Capture printed ID as `[NEW_BUNDLE]`:
      ```bash
      .agents/skills/linear/scripts/linear.sh issues create \
          --title "[PARENT_TITLE] follow-ups" \
          --description "[BUNDLE_DESC]" \
          --project "[PARENT_PROJECT]" \
          --labels "[PARENT_LABELS]" \
          --priority [BUNDLE_PRIORITY] \
          --format=ids
      ```
      **Non-zero exit or empty output → abort the merge.** Better human intervention than silent loss.

   e. Reparent each `[SAFE_ID]` (one call per ID):
      ```bash
      .agents/skills/linear/scripts/linear.sh issues update [SAFE_ID] --parent [NEW_BUNDLE]
      ```

   f. Link bundle back + comment:
      ```bash
      .agents/skills/linear/scripts/linear.sh issues add-relation [NEW_BUNDLE] --related [ISSUE]
      .agents/skills/linear/scripts/linear.sh comments create [ISSUE] --body "Pending children rebundled under [NEW_BUNDLE] before merge to avoid cascade-Done."
      ```

5. → § 5.

## 5. Execute Merge

**Note**: Some harnesses reset cwd per shell call. Prefer helper scripts and `-C`/absolute-path options over `cd && ...` chains in generated commands.

1. **Resolve main repo root** (needed when running from a worktree):
   ```bash
   .agents/skills/orch/scripts/git-context common-root .
   ```
   Use the output as `MAIN_REPO_ROOT`.

2. **Merge** (before cleanup — worktree survives if merge fails). Attempt the immediate merge first:
   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/github/scripts/github.sh -C [MAIN_REPO_ROOT] pr-merge [PR_NUMBER] [--force]
   ```

   Exit `0` = MERGED → step 3.

   **If pr-merge reports BLOCKED** (exit `1`) and the block is pending required checks or a merge queue — the issues/stderr mention `ci_pending:`, required checks that have not started yet, or that the base branch requires merges through a merge queue — re-run with `--auto`:
   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/github/scripts/github.sh -C [MAIN_REPO_ROOT] pr-merge [PR_NUMBER] --auto
   ```
   One flag covers both repo shapes with no detection: on merge-queue repos GitHub enqueues the PR; on plain repos it arms auto-merge to fire when CI and branch protection clear. `--auto` never bypasses the § 3 readiness gates — GitHub still requires the checks and approval to complete before the merge fires. For any other BLOCKED cause (conflicts, `ci_failed:`, `changes_requested:`), do not queue — surface the failure and return to § 3.2.

   Exit `75` = QUEUED FOR AUTO-MERGE — treat as success-pending and run the watch loop below. Ejection is per-PR: a failed merge-group run removes only this PR from the queue while other queued PRs re-test and merge independently, so each session's own merge-pr watch owns recovery for its own PR and parallel sessions never need to coordinate.

   **Watch loop** — each poll runs the two commands below, then routes; `sleep 30` between polls, at most 20 polls (~10 min):
   ```bash
   gh pr view [PR_NUMBER] --json state,mergedAt
   ```
   ```bash
   gh api graphql -f query='query($owner: String!, $repo: String!, $number: Int!) { repository(owner: $owner, name: $repo) { pullRequest(number: $number) { isInMergeQueue mergeQueueEntry { state } autoMergeRequest { enabledAt } } } }' -F owner='{owner}' -F repo='{repo}' -F number=[PR_NUMBER]
   ```
   `gh pr view --json` exposes no queue-membership field (verified against gh 2.96.0), so the GraphQL query is required; gh fills the `{owner}`/`{repo}` placeholders from the current repo. Track across polls whether any earlier poll observed the PR queued or armed (`isInMergeQueue == true`, `mergeQueueEntry` non-null, or `autoMergeRequest` non-null) — use that as `WAS_QUEUED`. Never poll `gh pr view --json mergeable` — stays UNKNOWN after merge, loops forever.

   | Observation | Meaning | Action |
   |-------------|---------|--------|
   | `state == "MERGED"` | Merge landed | → step 3 |
   | `OPEN`, still queued or armed, no failed required check | Waiting on checks / queue position | Continue polling |
   | `OPEN`, `WAS_QUEUED`, now `isInMergeQueue == false` and `mergeQueueEntry == null`, not merged | **Ejected** — the merge-group CI run failed and GitHub removed this PR from the queue | Recovery cycle below |
   | `OPEN` on a plain auto-merge repo, `autoMergeRequest == null` after `--auto` armed it, or a required check failed (probe: `.agents/skills/orch/scripts/ci-wait [PR_NUMBER] 15 60 --json` → `verdict=fail`) | Auto-merge disarmed by a check failure | Recovery cycle below |
   | Poll bound reached, still queued/armed | Deep queue | Report still-queued: the merge stays armed and fires when checks and protection clear. Skip steps 3-6 (they assume a landed merge) and note in § 7 that sync/cleanup should be re-run via `merge-pr [PR_NUMBER]` once merged |

   **Recovery cycle** — no manual CI-fixing; route the failure back into ci-fix automatically. Before the first recovery cycle, read the budget:

   ```bash
   .agents/skills/orch/scripts/orch-env CI_FIX_MAX_CYCLES 6
   ```

   The printed value is `MAX_CYCLES` — the effective `CI_FIX_MAX_CYCLES` (process env > `vstack.settings.toml` `[env]` > default 6; non-numeric falls back to 6). Max [MAX_CYCLES] recovery cycles per merge-pr run (a session-scoped count, parallel to ci-fix's own internal cycle cap); at the cap, report the failing check names, ci-fix's last error summary, and what each cycle attempted — never a bare "persistent failure" — then skip steps 3-6 and hand back to the user.

   A rerun-in-place (`gh run rerun` / rerun-failed-jobs) re-executes the workflow definition and verifier state pinned at the original triggering event — a PR that changes gate or CI workflow behavior only exhibits its new behavior on a fresh head (new push → attempt-1 run), never via a rerun of an old attempt. Reruns are for flakes and re-gating on unchanged workflows; behavior changes need a new commit and push.

   1. **Run Workflow**: `⤵ workflows/ci-fix.md [PR_NUMBER] § 1-7 → § 5 step 2`. For a queue ejection the failing run is the **merge-group** run (workflow event `merge_group`), not necessarily the PR-head run — locate it via the failing run link in the PR's checks or `gh run list --event merge_group --limit 10`, and point ci-fix's log fetching at that run.
   2. **Re-confirm the review gate** after ci-fix pushed a fix — pushes can dismiss reviewer approvals and move the head past the reviewed commit. ci-fix itself already re-confirmed the gate at the new head before re-verifying CI (its § 5, vstack#726); this short wait re-checks that the evidence still stands at the head about to be re-armed (skip when the § 3.2 `GATE_MODE` is `off`):
      ```bash
      .agents/skills/orch/scripts/approval-wait [PR_NUMBER] 15 300 --json --mode [GATE_MODE]
      ```
   3. **Re-arm and resume**: re-run `pr-merge [PR_NUMBER] --auto` (command above) and restart the watch loop from the top with a fresh poll budget.

3. **Sync issue tracker cache** — **Linear only** (merged PRs close issues via magic words; cache must reflect done states):
   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/linear/scripts/linear.sh sync --reconcile
   ```

4. **Sync main repo** (ALWAYS runs after merge):
   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/resolve-base-branch [MAIN_REPO_ROOT]
   ```
   Use the output as `BASE_BRANCH`.

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/github/scripts/git-https-auth -C [MAIN_REPO_ROOT] fetch --prune origin "+refs/heads/[BASE_BRANCH]:refs/remotes/origin/[BASE_BRANCH]"
   git -C [MAIN_REPO_ROOT] merge --ff-only "origin/[BASE_BRANCH]"
   git -C [MAIN_REPO_ROOT] worktree prune
   ```
   Target `origin` only. Optional secondary remotes must not block closure of
   the current PR. The fetch uses `git-https-auth`, which preserves normal SSH
   behavior unless a GitHub SSH remote is present and `gh` auth is valid; then
   it applies a per-command HTTPS/`gh auth git-credential` fallback. Fetch the
   base branch with an explicit refspec so narrowed `remote.origin.fetch`
   config cannot leave `origin/[BASE_BRANCH]` stale or missing. Keep the local
   fast-forward merge on plain `git` so credential helper config is not exposed
   to merge-time repository hooks. Sync to the explicit fetched
   `origin/[BASE_BRANCH]` ref with `--ff-only` so local main never gains
   merge-bubble commits; if the fast-forward fails, stop and surface the
   divergence for manual handling.

5. **Sweep stale branches & worktrees** (after all PRs merged and synced). Default: scoped to current PR only — do not enumerate unrelated branches or sibling worktrees.

   ### 5a. Scoped sweep (default)

   1. Resolve the merged PR branch:
      ```bash
      gh pr view [PR_NUMBER] --json headRefName --jq .headRefName
      ```
      Use the output as `PR_BRANCH`.
   2. Delete the local `[PR_BRANCH]` **only when no worktree owns it**:

      - **If § 4.1 captured a worktree-cleanup request** for this PR's issue → **skip** the standalone delete; step 6's `worktree remove` removes the worktree and safely deletes the merged branch. Continue to step 3.
      - **Otherwise**, list registered worktrees to confirm the branch is free before deleting:
        ```bash
        git -C [MAIN_REPO_ROOT] worktree list --porcelain
        ```
        | Output condition | Action |
        |------------------|--------|
        | A `branch refs/heads/[PR_BRANCH]` line is present | A worktree still has it checked out — do NOT delete (`branch -D` would fail). Leave it for worktree removal or the § 5b maintenance sweep; note in § 7. |
        | No such line, and `[PR_BRANCH]` exists locally and is not the current branch | Delete it: `git -C [MAIN_REPO_ROOT] branch -D "[PR_BRANCH]"` |
        | `[PR_BRANCH]` is absent locally or is the current branch | Nothing to delete. |
   3. When § 4.1 captured a cleanup request, step 6's `worktree remove` owns branch deletion; the standalone delete above is intentionally skipped.

   ### 5b. Project maintenance sweep (explicit only)

   Run only for `merge-pr all` or explicit user request. Find local branches whose remote PRs are merged/closed:
   ```bash
   git -C [MAIN_REPO_ROOT] branch --format='%(refname:short)'
   ```
   Ignore the default branch from this output.

   For each branch, check PR status:
   ```bash
   gh pr list --head [BRANCH] --state all --json number,state -q '.[0].state'
   ```

   - **MERGED/CLOSED with no worktree**: Auto-delete (`git branch -D [BRANCH]`). Report in § 7.
   - **MERGED/CLOSED with worktree**: Ask user `"Stale worktree for [BRANCH] (PR already merged). Remove?"`. If yes: `[MAIN_REPO_ROOT]/.agents/skills/worktree/scripts/worktree remove [ISSUE_ID]` then `git -C [MAIN_REPO_ROOT] branch -D [BRANCH]`.
   - **OPEN**: Leave alone (active work).
   - **No PR found**: Ask user `"Local branch [BRANCH] has no associated PR. Delete?"`. Show last commit for context.

   Also check for orphan worktree directories:
   ```bash
   ls [TREES_DIR]/
   git -C [MAIN_REPO_ROOT] worktree list --porcelain
   ```
   Compare the two outputs; any tree directory absent from `git worktree list --porcelain` is an orphan.
   If orphans found: Ask user before `rm -rf`.

6. **Cleanup current worktree** (if requested in § 4.1 — **must be last**, destroys session cwd):
   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/worktree/scripts/worktree remove "[ISSUE_ID]"
   ```
   If this prints `SESSION CWD DESTROYED`: present § 7 immediately, tell user to end the session — no further shell calls will succeed. Skip if cleanup not requested.

## 6. Post-Merge Quality Review (overlapping files only)

**Skip** if § 2.1 found no file overlaps, or if session cwd was destroyed in § 5 step 6.

For each file flagged as overlapping in § 2.1:

1. **Capture pre/post diff**:
   ```bash
   git diff [PRE_MERGE_SHA]..HEAD -- [FILE]
   ```
   Where `PRE_MERGE_SHA` is the main branch commit before the first merge in § 5.

2. **Read the full merged file** and review for: duplicate imports, reordering needs, redundant error guards, inconsistent patterns, dead code from the combination.

3. **Act on findings**:
   - **Auto-fix**: Duplicate imports, obvious ordering issues, trivial style inconsistencies → fix directly, commit as `fix(merge): clean up overlapping changes from PRs #X, #Y`
   - **Present to user**: Semantic issues requiring judgment (conflicting patterns, redundant logic where it's unclear which to keep) → describe the issue, propose a fix, ask user to confirm
   - **No issues**: Report `✅ Overlapping files reviewed — no quality issues` in § 7

## 7. Present Results

### Single PR

<output_format>

### ✅ MERGED — PR #[N]: [TITLE]

| Field | Value |
|-------|-------|
| Branch | [BRANCH_NAME] (deleted) |
| Worktree | cleaned up |
| Issue Tracker | [ISSUE_ID] → Done (via magic words) |

Include a `Review gate` row only when the merge did not proceed on a plain
`approved`/`reviewed` verdict — surface `⚠️ reviewer-down proceed (no reviewer
posted; PR_REVIEW_ON_TIMEOUT=proceed)` or `⚠️ forced (user override)` so a
non-organic gate is visible in the record.
</output_format>

### Multiple PRs (`all`)

<output_format>

### 🔍 CROSS-PR ANALYSIS

| Check | Result |
|-------|--------|
| File overlaps | ✅ None |
| Dependencies | ⚠️ #[N] → #[M] (merged in order) |

### 📋 MERGE SUMMARY

| Status | PR | Issue | Note |
|--------|-----|-------|------|
| ✅ | #[N] | [ISSUE_ID] - [TITLE] | Merged |
| ✅ | #[M] | [ISSUE_ID] - [TITLE] | After #[N] |
| ⏭️ | #[P] | [ISSUE_ID] - [TITLE] | Review threads |
| ❌ | #[Q] | [ISSUE_ID] - [TITLE] | Merge conflicts |

Total: [N] PRs merged | Synced: origin fetch via git-https-auth + local ff-only merge

### 🧹 STALE CLEANUP

| Action | Branch | Reason |
|--------|--------|--------|
| 🗑️ | [BRANCH_NAME] | PR #[N] merged |
| ⏭️ | [BRANCH_NAME] | User kept |

Legend: ✅ merged  ⏭️ skipped (user)  ❌ skipped (error)  🗑️ cleaned
</output_format>

---

## 8. Return State

**If managed**: Return to the parent workflow's next section.

**If standalone**: Session complete — merge results presented in § 7.
