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

### 3.1 Resolve transient "unknown" before prompting

If `issues` contains an entry starting with `unknown:` (GitHub still computing mergeable status), wait and re-check — do NOT prompt the user:

```bash
.agents/skills/github/scripts/github.sh await-mergeable [PR_NUMBER]
.agents/skills/github/scripts/github.sh pr-merge [PR_NUMBER] --check
```
Use the second command output as `CHECK`.

`await-mergeable` polls `state` + `mergeStateStatus` (never `mergeable` — stays UNKNOWN after merge, hangs forever). Exit 124 on timeout → surface to user.

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

2. **Merge** (before cleanup — worktree survives if merge fails):
   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/github/scripts/github.sh -C [MAIN_REPO_ROOT] pr-merge [PR_NUMBER] [--force]
   ```

   Exit `75` = queued for auto-merge (fires when CI + branch protection clear). Wait before sync:
   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/github/scripts/github.sh -C [MAIN_REPO_ROOT] await-mergeable [PR_NUMBER]
   ```
   Never poll `gh pr view --json mergeable` — stays UNKNOWN after merge, loops forever.

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
   [MAIN_REPO_ROOT]/.agents/skills/github/scripts/git-https-auth -C [MAIN_REPO_ROOT] fetch --prune origin
   [MAIN_REPO_ROOT]/.agents/skills/github/scripts/git-https-auth -C [MAIN_REPO_ROOT] pull --rebase origin [BASE_BRANCH]
   git -C [MAIN_REPO_ROOT] worktree prune
   ```
   Target `origin` only. Optional secondary remotes must not block closure of
   the current PR. `git-https-auth` preserves normal SSH behavior unless a
   GitHub SSH remote is present and `gh` auth is valid, in which case it
   applies a per-command HTTPS/`gh auth git-credential` fallback. `--rebase`
   prevents merge-bubble commits when local main diverged.

5. **Sweep stale branches & worktrees** (after all PRs merged and synced). Default: scoped to current PR only — do not enumerate unrelated branches or sibling worktrees.

   ### 5a. Scoped sweep (default)

   1. Resolve the merged PR branch:
      ```bash
      gh pr view [PR_NUMBER] --json headRefName --jq .headRefName
      ```
      Use the output as `PR_BRANCH`.
   2. If `[PR_BRANCH]` exists locally and is not the current branch, delete it:
      ```bash
      git -C [MAIN_REPO_ROOT] branch -D "$PR_BRANCH"
      ```
   3. Worktree removal is handled by step 6 when § 4.1 captured a cleanup request.

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

Total: [N] PRs merged | Synced: origin fetch/pull via git-https-auth

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
