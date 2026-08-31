# PR Merge Workflow

Verify the merge conditions and merge PR(s).

| Command | Flow |
|---------|------|
| `merge-pr` | List ready PRs, user selects |
| `merge-pr [N]` | Merge a specific PR |
| `merge-pr all` | Merge all ready PRs in sequence |

## 1. Identify Candidates

```bash
.agents/skills/github/scripts/github.sh pr-list-ready
```

With no argument, present the list and ask which to merge. With `all`, process every ready PR sequentially.

## 2. Cross-Check (batch merges only)

**Skip if** fewer than two PRs are in scope.

```bash
.agents/skills/github/scripts/github.sh pr-cross-check [PR_NUMBERS] --quick --json
```

High-severity findings (conflicts) abort early with the issues shown. Otherwise verify:

```bash
.agents/skills/github/scripts/github.sh pr-cross-check [PR_NUMBERS] --verify --json
```

`can_batch_merge: true` → § 3 in the reported `merge_order`. `false` → show the merge, build, and test failures with their suggested remediation and ask: `Abort` | `Force anyway`.

## 3. Check Merge Readiness

```bash
.agents/skills/github/scripts/github.sh pr-merge [PR_NUMBER] --check
```

### 3.1 Resolve Transient Blockers First

`CHECK.transient == true` → route on the issue prefix before any user prompt, and never loop indefinitely. Continue to § 3.2 once `transient` is `false` or the bounded wait expires.

| Prefix | Wait |
|--------|------|
| `unknown:` (GitHub still computing mergeable status) | `github.sh await-mergeable [PR_NUMBER]`, then re-check. Exit 124 on timeout → surface to the user |
| `ci_pending:` | `.agents/skills/orch/scripts/ci-wait [PR_NUMBER] 15 600`, then re-check. On a non-zero exit or timeout, surface the result, re-check once for fresh state, and continue without another automatic wait |
| `ci_fetch_failed:`, `ci_unconfigured:` | Re-check, at most three checks total, then continue with the latest `CHECK` |

### 3.2 Act On The Result

`CHECK.state` decides first: `MERGED` → set `[ALREADY_MERGED]=true`, run § 4 EXCEPT § 4.1, then enter § 5 step 1 to create and claim its lifecycle before post-merge work; `CLOSED` → report that it was closed unmerged and stop.

`can_merge: true` → § 4, showing any warnings. `false` → show the issues with their suggested fixes and ask: `Skip` | `Fix and retry` | `Force merge`.

Two warnings are merge gates, not advice:

- **`unresolved_threads`** — zero unresolved review threads is required at merge time. Route to `review-pr-comments` to reply and resolve first; merge past them only on explicit user override.
- **`not_approved`** — resolve the project's gate mode first with `.agents/skills/orch/scripts/approval-wait --resolve-mode` ([references/gates.md](../references/gates.md)) and route on the printed `GATE_MODE`:
  - `off` — informational only; do not gate on it.
  - `review` — `not_approved` is expected. Poll `approval-wait [PR_NUMBER] 30 --json --mode review` and treat `reviewed` as the met gate.
  - `approval` — a GitHub-native approval verdict is required. Without it, do not auto-merge: poll `approval-wait [PR_NUMBER] 30 --json` or ask the user.

  With `PR_REVIEW_ON_TIMEOUT=proceed`, a deadline reached with zero unresolved threads and no reviewer evidence returns `proceeded` (exit 0) instead of `timeout` in both modes — treat it as a met gate and record it in the § 6 report. An open thread or a `changes_requested` still blocks. The proceed is a LOCAL verdict — orch posts no status.

  Merge past a missing gate verdict only on an explicit user `Force merge`.

Bot-specific signals — emoji reactions, sticky-comment prose, checklist text — are never parsed as merge gates. Only GitHub-native review state and the thread-resolution count count.

## 4. Prepare

```bash
.agents/skills/github/scripts/github.sh pr-issue [PR_NUMBER] --format=text
.agents/skills/worktree/scripts/worktree exists "$ISSUE"
.agents/skills/worktree/scripts/worktree path "$ISSUE"
.agents/skills/github/scripts/github.sh bot-token
```

Use the extracted issue as `[ISSUE]`. Set `[STATE_KEY]` to `[ISSUE]` when nonempty;
otherwise use `pr-[PR_NUMBER]`. This repository-local key cannot collide with
normalized GitHub key `issue-N`. Use worktree commands only with an `[ISSUE]`.
When no issue worktree exists, set `[WORKTREE_PATH]` to `[MAIN_REPO_ROOT]` and
`[CLEANUP_WORKTREE]=false`. Read the PR branch, then initialize workflow state;
the command is idempotent for managed sessions and creates it for standalone
`merge-pr`:

```bash
.agents/skills/orch/scripts/git-context common-root .
```
```bash
env -u GH_REPO -u GITHUB_REPOSITORY gh pr view [PR_NUMBER] --json headRefName --jq .headRefName
```
```bash
.agents/skills/orch/scripts/merge-queue-watch init --worktree [WORKTREE_PATH] --issue [STATE_KEY] --branch [PR_BRANCH]
```

`bot-token` reporting `.configured: false` → ask `Merge as current user` | `Abort`.

### 4.1 Detach Orphaned Children

**Skip if** no `[ISSUE]` was extracted, or `TRACKER=github`.

```bash
.agents/skills/linear/scripts/linear.sh cache issues children [ISSUE] --pending --recursive
```

Partition by `state_type`: `backlog` and `unstarted` are **safe** (`[SAFE_IDS]`); anything else is **active**. Both empty → § 5.

Active children pause the merge and ask the user per orphan — was the work landed in this PR? Yes closes it Done; no appends it to `[SAFE_IDS]`; abort stops § 4.1 entirely.

`[SAFE_IDS]` still empty → § 5. Otherwise rebundle them under a new parent:

```bash
.agents/skills/linear/scripts/linear.sh cache issues get [ISSUE]
```

Read `.title`, `.project.id`, and the joined label names for the new bundle, and take `[BUNDLE_PRIORITY]` as the highest priority across `[SAFE_IDS]` (Linear: `1`=Urgent…`4`=Low, lower wins; default `3`). Build `[BUNDLE_DESC]` per `.agents/skills/project-management/templates/parent-issue-template.md`, with a `## Sub-Issues` list and a `## Context` line naming the detachment.

```bash
.agents/skills/linear/scripts/linear.sh issues create --state "Backlog" --title "[PARENT_TITLE] follow-ups" --description "[BUNDLE_DESC]" --project "[PARENT_PROJECT]" --labels "[PARENT_LABELS]" --priority [BUNDLE_PRIORITY] --format=ids
```

A non-zero exit or empty output **aborts the merge**. Otherwise reparent each safe id (one call each), link the bundle back, and comment on the original:

```bash
.agents/skills/linear/scripts/linear.sh issues update [SAFE_ID] --parent [NEW_BUNDLE]
```
```bash
.agents/skills/linear/scripts/linear.sh issues add-relation [NEW_BUNDLE] --related [ISSUE]
```
```bash
.agents/skills/linear/scripts/linear.sh comments create [ISSUE] --body "Pending children rebundled under [NEW_BUNDLE] before merge to avoid cascade-Done."
```

## 5. Execute The Merge

Some harnesses reset cwd per shell call — prefer `-C` and absolute paths over `cd &&` chains.

```bash
.agents/skills/orch/scripts/git-context common-root .
```

Use the output as `MAIN_REPO_ROOT`.

1. **Merge**, before any cleanup:

   Resolve the repository, gate mode, and exact head, then prepare the lifecycle before
   any merge attempt. `[RECOVERY_COUNT]` is `0` initially and the latest consume result thereafter.

   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY gh repo view --json nameWithOwner --jq .nameWithOwner
   ```
   ```bash
   .agents/skills/orch/scripts/approval-wait --resolve-mode
   ```
   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY gh pr view [PR_NUMBER] --json headRefOid --jq .headRefOid
   ```
   ```bash
   .agents/skills/orch/scripts/merge-queue-watch prepare --worktree [WORKTREE_PATH] --issue [STATE_KEY] --repo [OWNER/REPO] --pr [PR_NUMBER] --head [PREPARED_HEAD] --root [MAIN_REPO_ROOT] --gate-mode [GATE_MODE] --recovery-count [RECOVERY_COUNT] --cleanup-worktree [CLEANUP_WORKTREE]
   ```

   `[ALREADY_MERGED]=true` skips the mutation, runs `direct-merged` below, and
   continues to step 2. Otherwise attempt only the prepared head:

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/github/scripts/github.sh -C [MAIN_REPO_ROOT] pr-merge [PR_NUMBER] [--force] --expected-head [PREPARED_HEAD]
   ```

   Exit `0` runs `direct-merged` below, then continues to step 2.

   Exit `1` BLOCKED → run `[MAIN_REPO_ROOT]/.agents/skills/github/scripts/github.sh -C [MAIN_REPO_ROOT] ci-classify-refusal [PR_NUMBER]` and route on its `cause:` line: `ci_pending` — or `none` when the merge output names a base branch requiring merges through a queue — → re-run the prepared head with `--auto`. Any other cause terminalizes the prepared lifecycle with `--cause merge_blocked`, surfaces the detail, and returns to § 3.2.

   The prepare result supplies `[WATCH_ID]`, `[PREPARED_HEAD]`, and absolute artifact and diagnostic paths. Arm only that head:

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/github/scripts/github.sh -C [MAIN_REPO_ROOT] pr-merge [PR_NUMBER] --auto --expected-head [PREPARED_HEAD]
   ```

   Exit `75` launches the prepared one-shot watch, then returns immediately:

   ```bash
   .agents/skills/orch/scripts/merge-queue-watch launch --root [MAIN_REPO_ROOT] --issue [STATE_KEY] --watch-id [WATCH_ID]
   ```

   Exit `0` claims the same prepared head as an immediate merge, then continues
   to step 2:

   ```bash
   .agents/skills/orch/scripts/merge-queue-watch direct-merged --root [MAIN_REPO_ROOT] --issue [STATE_KEY] --watch-id [WATCH_ID]
   ```

   Launch setup failures persist `resume_launch`; fix the diagnostic and rerun launch for the same watch. Do not hand back while that action is active. Exact-head arm failures remain terminal:

   ```bash
   .agents/skills/orch/scripts/merge-queue-watch fail --root [MAIN_REPO_ROOT] --issue [STATE_KEY] --watch-id [WATCH_ID] --cause arm_failed
   ```

   Never poll merge state by hand. At a lane boundary, run `consume` and route
   only on its normalized `action`:

   ```bash
   .agents/skills/orch/scripts/merge-queue-watch consume --root [MAIN_REPO_ROOT] --issue [STATE_KEY]
   ```

   | `action` | Route |
   |----------|-------|
   | `pending` | Return; the detached supervisor is live and within its deadline |
   | `resume_launch` | Fix the persisted setup failure and rerun launch for the same watch; never hand back |
   | `postmerge` | Step 2 |
   | `resume_postmerge` | Resume the already-claimed step 2 path after interruption |
   | `restack`, `resume_restack` | Run or resume the guarded Restack cycle below |
   | `recovery` | Recovery cycle below, using the persisted gate mode and recovery count |
   | `resume_recovery` | Resume the persisted recovery cycle; do not increment or delegate a new cycle |
   | `triage` | Late-findings triage below |
   | `resume_triage`, `resume_manual_dequeue` | Resume the already-claimed review path |
   | `manual_dequeue` | Confirm dequeue or disarm before late-findings triage |
   | `rewatch` | Prepare and launch a new watch without re-arming |
   | `rearm` | Prepare, re-arm the exact head once, and launch |
   | `resume_rewatch`, `resume_rearm` | Resume the claimed next-generation setup without replaying consume |
   | `lane_postmerge`, `resume_cleanup`, `acknowledge` | Continue in `lane-postmerge.md`; never replay merge-pr steps 2-4 |
   | `complete` | No-op; lifecycle already finished |
   | `failed`, `abandoned` | Hand back with the durable diagnostic; no replay |

   **Recovery cycle** — route the failure back into ci-fix, never fix CI by hand:

   ```bash
   .agents/skills/orch/scripts/workflow-state cap CI_FIX_MAX_CYCLES
   ```

   Max `[MAX_CYCLES]` recovery cycles per merge-pr run. At the cap, report the failing check names, ci-fix's last error summary, and what each cycle attempted — never a bare "persistent failure" — then skip steps 2-4 and hand back. Use rerun-in-place only for flakes; gate or CI behavior changes need a fresh head.

   1. `⤵ workflows/ci-fix.md [PR_NUMBER] § 1-6 → § 5 step 1`. For a queue ejection the failing run is the **merge-group** run (event `merge_group`), not necessarily the PR-head run — locate it via the failing check's run link or `gh run list --event merge_group --limit 10` and point ci-fix at it.
   2. Re-confirm the gate at the head about to be re-armed (skip when `GATE_MODE` is `off`):

      ```bash
      .agents/skills/orch/scripts/approval-wait [PR_NUMBER] 15 300 --json --mode [GATE_MODE]
      ```

   3. Return to step 1's prepare, exact-head arm, and launch sequence.

   **Restack cycle** — the base, not CI, is the blocker. Follow `workflows/merge-pr-restack.md`,
   then return to step 1's exact-head sequence. Never route a conflict into ci-fix.

   **Late-findings triage** — the findings, not CI, are the blocker:

   1. On `cause: late_findings_dequeue_failed`, first apply the disarm-then-dequeue order and PR-node-id lookup from `merge-pr-restack.md`; the PR must be out of the queue before triage pushes.
   2. `⤵ workflows/review-pr-comments.md [PR_NUMBER] § 1-8 → § 5 step 1` with managed context — every new thread replied to and resolved.
   3. Triage may have pushed a new head. Return to step 1's prepare, exact-head arm, and launch sequence.

2. **Sync the tracker and close a finished container** — **Linear only**. Skip the WHOLE step for GitHub work items: resolve the tracker first; an `issue-N` key in any casing is a GitHub item.

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/linear/scripts/linear.sh sync --reconcile
   ```

   The lane owns tracker completion after a detached merge; the overseer does
   not substitute for it. When `[ISSUE]` was extracted, read it from the synced
   cache. A completed state needs no write. A live state completes now:

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/linear/scripts/linear.sh cache issues get [ISSUE]
   ```
   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/linear/scripts/linear.sh issues complete [ISSUE]
   ```

   A canceled or unreadable issue is a tracker failure, not a completed merge
   record. Carry the diagnostic into § 6 and do not claim tracker completion.

   **The container closes LAST.** If `[ISSUE]` was the final open child of a container parent, complete the container now. Skip when no `[ISSUE]` was extracted.

   a. Read `.parent_id` (`cache issues get [ISSUE]`). Empty → step 3.
   b. Fetch the parent with its bundle. A `(one PR)` title marker keeps it single-PR; without the marker, children or an `agent:multi` label make it a CONTAINER. Not a container → step 3.
   c. Close the container through the serialized helper:

      ```bash
      [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/container-close [MAIN_REPO_ROOT] [PARENT_ID]
      ```

      `closed [PARENT_ID]` → record the closure in § 6 with every stderr diagnostic from the helper. If this container has a container parent, re-run the step-2 sync and repeat a-c for that parent.

      `deferred [CHILD_IDS...]` → record `container [PARENT_ID] stays open (pending: [CHILD_IDS])` in § 6 and continue to step 3. When `[ISSUE]` is among `[CHILD_IDS]`, report `closure for [ISSUE] has not propagated; rerun merge-pr`. A bare `deferred` means the 120-second lock wait expired; report that and continue. On a non-zero exit, carry its diagnostic into § 6, do not climb to another parent, and continue to step 3; the container stays OPEN and the close is safe to repeat once the diagnostic's cause is gone — a failed `gh pr list` among them — so report `container [PARENT_ID] stays open; rerun merge-pr to close it`. Re-running costs nothing when the parent is already complete: the helper short-circuits to `closed`.

3. **Sync the main repo** — always runs after a merge.

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/sync-base [MAIN_REPO_ROOT]
   ```

   Its stdout is `[BASE_BRANCH]`. On success, read `refs/heads/[BASE_BRANCH]` for `[NEW_SHA]` and report it in § 6. On a non-zero exit, the base remains unsynchronized. Carry the helper's diagnostic into the § 6 warning, resolve `[BASE_BRANCH]` with `resolve-base-branch`, then collect the warning SHAs before cleanup:

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/resolve-base-branch [MAIN_REPO_ROOT]
   git -C [MAIN_REPO_ROOT] rev-parse "refs/heads/[BASE_BRANCH]"
   git -C [MAIN_REPO_ROOT] rev-parse "refs/remotes/origin/[BASE_BRANCH]"
   ```

   The outputs are `[LOCAL_SHA]` and `[ORIGIN_SHA]`. A failed ref read stays in the warning as its cause. Never record the sync as done.

4. **Prepare branch and worktree cleanup**, scoped to this PR by default — never enumerate unrelated branches or sibling worktrees.

   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY gh pr view [PR_NUMBER] --json headRefName --jq .headRefName
   ```

   **Worktree disposal is by rule.** When the PR's worktree exists, its tree is clean (`git -C [WT_PATH] status --porcelain` empty), and its checked-out branch is `[PR_BRANCH]`, remove it in the removal step below — no question. A dirty tree or a foreign-lease refusal from `worktree remove` keeps the worktree and its checked-out branch; a worktree on a branch other than the merged one is kept as-is (the merged branch then falls to the standalone delete below). Report any kept worktree with its cause in the § 6 `Worktree` row.

   **The merged predicate is `worktree cleanup`'s**: ancestry into the repository's default branch, or, when ancestry fails, a pull request merged into that same default branch whose head commit is the local branch's tip. A squash merge leaves no ancestry, so the second proof is the one that applies to every PR landing through the queue, and it is the commit that proves it — a branch carrying commits past its merged PR is unmerged work. `worktree remove` applies the predicate itself when deleting the branch: a nonzero exit after the tree is gone means the branch survived, and the diagnostic names the answer the lookup gave; carry that as `kept` in the § 6 `Branch` row.

   With no qualifying worktree, delete the local `[PR_BRANCH]` only when no worktree owns it. Confirm first:

   ```bash
   git -C [MAIN_REPO_ROOT] worktree list --porcelain
   ```

   A `branch refs/heads/[PR_BRANCH]` line means a worktree still has it checked out: do not delete, and note it in § 6. No such line, and the branch exists locally and is not current → apply the predicate before deleting, never worktree ownership alone:

   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY gh pr view [PR_NUMBER] --json headRefOid --jq .headRefOid
   ```
   ```bash
   git -C [MAIN_REPO_ROOT] rev-parse "refs/heads/[PR_BRANCH]"
   ```

   Run every `gh` command in this step from `[MAIN_REPO_ROOT]` with both variables cleared, as the script and `reconcile-work-items` do: an inherited `GH_REPO` or `GITHUB_REPOSITORY` points the proof at another repository, whose PR of the same number can authorize this `branch -D`.

   Equal → `git -C [MAIN_REPO_ROOT] branch -D "[PR_BRANCH]"`. Different → the branch carries commits the merge did not take: keep it and report it `kept` in the § 6 `Branch` row. Never `git branch -d` here — it proves merge against the branch's configured upstream, which `worktree push` sets, so it passes for any pushed branch however far it is from `[BASE_BRANCH]`.

   For `merge-pr all` or an explicit user request, also sweep the project. Check each local branch with `env -u GH_REPO -u GITHUB_REPOSITORY gh pr list --head [BRANCH] --base [BASE_BRANCH] --state all --json number,state,headRefOid,isCrossRepository`, and auto-delete only a branch with no worktree whose tip equals the `headRefOid` of one of its **merged**, non-cross-repository PRs — the predicate `worktree cleanup` applies. Neither state nor a merge into another base is the test: a closed PR merged nothing, a PR merged into a release or other side branch left its commit out of `[BASE_BRANCH]` with this ref possibly the last ordinary one holding it, and a merged PR whose head differs from the tip left the extra commits reachable from this ref alone. Leave every other branch alone, and ask before removing a stale worktree or a branch with no PR. Compare `ls [TREES_DIR]/` against `worktree list --porcelain` for orphan directories, asking before removing any.

   After every branch/worktree cleanup decision is recorded, persist the return
   point for the lane's outer post-merge work. The lifecycle file lives under
   the shared git directory and survives worktree removal:

   ```bash
   .agents/skills/orch/scripts/merge-queue-watch merge-pr-complete --root [MAIN_REPO_ROOT] --issue [STATE_KEY] --watch-id [WATCH_ID]
   ```

   Keep the issue worktree through the managed lane post-merge phase. That phase
   removes it from the main repository after project verification succeeds.

## 6. Present Results

An armed or queued PR returns this result as soon as its detached watch reports
ready. It is not a merge claim:

<output_format>

### ⏳ ARMED — PR #[N]: [TITLE]

| Field | Value |
|-------|-------|
| Head | `[PREPARED_HEAD]` |
| Queue watch | `[WATCH_ID]` detached; diagnostics at `[LOG_PATH]` |
| Lane | released; this session owns the later verdict |

</output_format>

A completed merge uses the result below.

<output_format>

### ✅ MERGED — PR #[N]: [TITLE]

| Field | Value |
|-------|-------|
| Branch | [BRANCH_NAME] (deleted / kept) |
| Worktree | pending lane cleanup / kept — [cause] |
| Issue Tracker | [ISSUE_ID] → Done (completed by the lane after merge) |
| Container | [PARENT_ID] → Done / deferred — [pending ids, restorations, or cause] |
| Base sync | local `[BASE_BRANCH]` → [NEW_SHA] |

</output_format>

The `Container` row appears only when § 5 step 2 found a container parent. The `Base sync` row is never omitted. When § 5 step 3 hit a blocking outcome it carries the warning instead of a sha: `⚠️ local [BASE_BRANCH] STALE at [LOCAL_SHA] (origin/[BASE_BRANCH] at [ORIGIN_SHA]) — [CAUSE]`. The `Worktree` row reports `pending lane cleanup`, or `kept — [dirty tree | branch not merged | foreign lease]` when § 5 step 4 found it ineligible (no worktree existed → omit the row). Add a `Review gate` row only when the merge did not proceed on a plain `approved`/`reviewed` verdict — `⚠️ reviewer-down proceed (no reviewer posted; PR_REVIEW_ON_TIMEOUT=proceed)` or `⚠️ forced (user override)`.

For `merge-pr all`, add the cross-PR analysis and a merge table:

<output_format>

### 📋 MERGE SUMMARY

| Status | PR | Issue | Note |
|--------|-----|-------|------|
| ✅ | #[N] | [ISSUE_ID] - [TITLE] | Merged |
| ⏭️ | #[P] | [ISSUE_ID] - [TITLE] | Review threads |
| ❌ | #[Q] | [ISSUE_ID] - [TITLE] | Merge conflicts |

Total: [N] PRs merged | Base sync: local `[BASE_BRANCH]` → [NEW_SHA]

Legend: ✅ merged  ⏭️ skipped (user)  ❌ skipped (error)

</output_format>

## 7. Return

**Managed**: return to `workflows/lane-postmerge.md`. **Standalone**: session
complete after any `awaiting_lane_postmerge` record is explicitly acknowledged.
