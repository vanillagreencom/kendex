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

High-severity findings (conflicts) abort early with the issues shown. Otherwise verify for real — this merges the PRs into a temp worktree from main, builds, tests, reports, and cleans up:

```bash
.agents/skills/github/scripts/github.sh pr-cross-check [PR_NUMBERS] --verify --json
```

`can_batch_merge: true` → § 3 in the reported `merge_order`. `false` → show the merge, build, and test failures with their suggested remediation and ask: `Abort` | `Force anyway`.

## 3. Check Merge Readiness

```bash
.agents/skills/github/scripts/github.sh pr-merge [PR_NUMBER] --check
```

### 3.1 Resolve Transient Blockers First

`CHECK.transient == true` means the block may clear by waiting — route on the issue prefix before any user prompt, and never loop indefinitely. Continue to § 3.2 once `transient` is `false` or the bounded wait expires.

| Prefix | Wait |
|--------|------|
| `unknown:` (GitHub still computing mergeable status) | `github.sh await-mergeable [PR_NUMBER]`, then re-check. It polls `state` + `mergeStateStatus`, never `mergeable`, which stays UNKNOWN after merge and hangs forever. Exit 124 on timeout → surface to the user |
| `ci_pending:` | `.agents/skills/orch/scripts/ci-wait [PR_NUMBER] 15 600`, then re-check. On a non-zero exit or timeout, surface the result, re-check once for fresh state, and continue without another automatic wait |
| `ci_fetch_failed:`, `ci_unconfigured:` | Re-check, at most three checks total, then continue with the latest `CHECK` |

### 3.2 Act On The Result

`CHECK.state` decides first: `MERGED` → the PR already landed — run § 4 (`ISSUE`, worktree, token) and § 5's preamble (`MAIN_REPO_ROOT`) as for a fresh merge, then continue at § 5 step 2 for sync and cleanup, skipping step 1; `CLOSED` → report that it was closed unmerged and stop. Neither is a blocker to clear, and both arrive with an empty `issues` array.

`can_merge: true` → § 4, showing any warnings. `false` → show the issues with their suggested fixes and ask: `Skip` | `Fix and retry` | `Force merge`.

Two warnings are merge gates, not advice:

- **`unresolved_threads`** — zero unresolved review threads is required at merge time. Route to `review-pr-comments` to reply and resolve first; merge past them only on explicit user override.
- **`not_approved`** — resolve the project's gate mode first with `.agents/skills/orch/scripts/approval-wait --resolve-mode` ([references/gates.md](../references/gates.md)) and route on the printed `GATE_MODE`:
  - `off` — informational only; do not gate on it.
  - `review` — commenting-only reviewers never approve, so `not_approved` is expected. Poll `approval-wait [PR_NUMBER] 30 --json --mode review` and treat `reviewed` as the met gate.
  - `approval` — a GitHub-native approval verdict is required. Without it, do not auto-merge: poll `approval-wait [PR_NUMBER] 30 --json` or ask the user.

  With `PR_REVIEW_ON_TIMEOUT=proceed`, a deadline reached with zero unresolved threads and no reviewer evidence returns `proceeded` (exit 0) instead of `timeout` in both modes — treat it as a met gate and record it in the § 6 report (merge-pr keeps no workflow-state; that note is the provenance). It fires only when every reviewer is silent; an open thread or a `changes_requested` still blocks. The proceed is a LOCAL verdict — orch posts no status, so a repo whose CI gates on review evidence stays red unless its own override governs it.

  Merge past a missing gate verdict only on an explicit user `Force merge`.

Bot-specific signals — emoji reactions, sticky-comment prose, checklist text — are never parsed as merge gates. Only GitHub-native review state and the thread-resolution count count.

## 4. Prepare

```bash
.agents/skills/github/scripts/github.sh pr-issue [PR_NUMBER] --format=text
.agents/skills/worktree/scripts/worktree exists "$ISSUE"
.agents/skills/github/scripts/github.sh bot-token
```

Note whether a worktree exists for `ISSUE` — § 5 step 4 disposes of it by rule, no question. `bot-token` reporting `.configured: false` → ask `Merge as current user` | `Abort`.

### 4.1 Detach Orphaned Children

Linear cascades a parent's Done state to all children, so any pending `make_child` issue under `[ISSUE]` is silently flipped to Done on merge. **Skip if** no `[ISSUE]` was extracted, or `TRACKER=github` — no cascade there.

```bash
.agents/skills/linear/scripts/linear.sh cache issues children [ISSUE] --pending --recursive
```

Partition by `state_type`: `backlog` and `unstarted` are **safe** (`[SAFE_IDS]`); anything else is **active**. Both empty → § 5.

Active children pause the merge and ask the user per orphan — was the work landed in this PR? Yes closes it Done; no appends it to `[SAFE_IDS]`; abort stops § 4.1 entirely.

`[SAFE_IDS]` still empty → § 5. Otherwise rebundle them under a new parent so nothing is lost:

```bash
.agents/skills/linear/scripts/linear.sh cache issues get [ISSUE]
```

Read `.title`, `.project.id`, and the joined label names for the new bundle, and take `[BUNDLE_PRIORITY]` as the highest priority across `[SAFE_IDS]` (Linear: `1`=Urgent…`4`=Low, lower wins; default `3`). Build `[BUNDLE_DESC]` per `.agents/skills/project-management/templates/parent-issue-template.md`, with a `## Sub-Issues` list and a `## Context` line naming the detachment.

```bash
.agents/skills/linear/scripts/linear.sh issues create --title "[PARENT_TITLE] follow-ups" --description "[BUNDLE_DESC]" --project "[PARENT_PROJECT]" --labels "[PARENT_LABELS]" --priority [BUNDLE_PRIORITY] --format=ids
```

A non-zero exit or empty output **aborts the merge** — human intervention beats silent loss. Otherwise reparent each safe id (one call each), link the bundle back, and comment on the original:

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

1. **Merge**, before any cleanup, so the worktree survives a failure:

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/github/scripts/github.sh -C [MAIN_REPO_ROOT] pr-merge [PR_NUMBER] [--force]
   ```

   Exit `0` = merged → step 2.

   Exit `1` BLOCKED on pending required checks or a merge queue — the issues or stderr mention `ci_pending:`, checks that have not started, or a base branch requiring merges through a queue — re-runs with `--auto`: a merge-queue repo enqueues the PR, a plain repo arms auto-merge. `--auto` never bypasses the § 3 gates. Any other BLOCKED cause (conflicts, `ci_failed:`, `changes_requested:`) is surfaced and returns to § 3.2 — do not queue it.

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/github/scripts/github.sh -C [MAIN_REPO_ROOT] pr-merge [PR_NUMBER] --auto
   ```

   Exit `75` = queued or armed. Watch it with queue-wait — it blocks until the outcome is decided and carries the cross-poll `WAS_QUEUED` memory separate tool calls cannot:

   ```bash
   .agents/skills/orch/scripts/queue-wait [PR_NUMBER] 30 600 --json
   ```

   Never poll `gh pr view --json mergeable` — it stays UNKNOWN after merge and loops forever. Ejection is per-PR: a failed merge-group run removes only this PR, so each session's own watch owns its recovery and parallel sessions never coordinate.

   | `verdict` | Meaning | Action |
   |-----------|---------|--------|
   | `merged` | Merge landed | → step 2 |
   | `ejected` | The merge-group CI run failed and GitHub removed this PR from the queue | Recovery cycle below |
   | `disarmed` | Auto-merge cleared, or a required check failed (`cause` says which) | Recovery cycle below |
   | `dequeued` | The late-findings guard saw a NEW unresolved review thread while queued/armed and pulled the arming (`cause: late_findings`) — or tried and failed (`cause: late_findings_dequeue_failed`: the PR is STILL queued and the merge may fire; dequeue manually before triage) | Late-findings triage below |
   | `closed` | The PR was closed out from under the merge | Skip steps 2-4 and hand back |
   | `queued` | Deadline reached, still armed | Not a failure: the merge fires when checks and protection clear. Skip steps 2-4 and note in § 6 that sync and cleanup need `merge-pr [PR_NUMBER]` re-run once merged |
   | `not_queued` | The `--auto` merge never armed | Re-run `pr-merge [PR_NUMBER] --auto` once; still unarmed → surface and hand back |

   **Recovery cycle** — route the failure back into ci-fix, never fix CI by hand:

   ```bash
   .agents/skills/orch/scripts/orch-env CI_FIX_MAX_CYCLES 6
   ```

   Max `[MAX_CYCLES]` recovery cycles per merge-pr run. At the cap, report the failing check names, ci-fix's last error summary, and what each cycle attempted — never a bare "persistent failure" — then skip steps 2-4 and hand back. A rerun-in-place re-executes the workflow definition pinned at the original triggering event, so gate or CI behavior changes only appear on a fresh head; reruns are for flakes.

   1. `⤵ workflows/ci-fix.md [PR_NUMBER] § 1-6 → § 5 step 1`. For a queue ejection the failing run is the **merge-group** run (event `merge_group`), not necessarily the PR-head run — locate it via the failing check's run link or `gh run list --event merge_group --limit 10` and point ci-fix at it.
   2. Re-confirm the gate at the head about to be re-armed (skip when `GATE_MODE` is `off`); ci-fix already re-confirmed at its own new head before re-verifying CI, and this checks the evidence still stands:

      ```bash
      .agents/skills/orch/scripts/approval-wait [PR_NUMBER] 15 300 --json --mode [GATE_MODE]
      ```

   3. Re-run `pr-merge [PR_NUMBER] --auto`, then `queue-wait` with a fresh poll budget.

   **Late-findings triage** — the guard dequeued because a reviewer posted after enqueue; the findings, not CI, are the blocker:

   1. On `cause: late_findings_dequeue_failed` first confirm the dequeue by hand (GraphQL `dequeuePullRequest` — its `id` input takes the PR node id) or disable auto-merge; the PR must be out of the queue before triage pushes anything.
   2. `⤵ workflows/review-pr-comments.md [PR_NUMBER] § 1-8 → § 5 step 1` with managed context — every new thread replied to and resolved.
   3. Triage may have pushed a new head: re-confirm the gate exactly as recovery step 2 above, then re-run `pr-merge [PR_NUMBER] --auto` and `queue-wait` with a fresh poll budget.

2. **Sync the tracker and close a finished container** — **Linear only**; merged PRs close issues via magic words, so the cache must reflect the new Done states. Skip the WHOLE step for GitHub work items: resolve the tracker first, since an `issue-N` key in any casing is a GitHub item and running Linear commands for it would fail the merge outright.

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/linear/scripts/linear.sh sync --reconcile
   ```

   **The container closes LAST.** The merge just closed `[ISSUE]`; if that was the final open child of a container parent, complete the container now. Skip when no `[ISSUE]` was extracted.

   a. Read `.parent_id` (`cache issues get [ISSUE]`). Empty → step 3.
   b. Fetch the parent with its bundle. A `(one PR)` title marker keeps it single-PR; without the marker, children or an `agent:multi` label make it a CONTAINER. Not a container → step 3.
   c. **Serialize per parent before anything else** — concurrent final siblings can each observe the other as pending and both return, leaving no later merge to close the container. Create `[MAIN_REPO_ROOT]/tmp` (git-ignored, absent on fresh checkouts), then take the lock with `mkdir [MAIN_REPO_ROOT]/tmp/container-close-[PARENT_ID].lock` — mkdir is atomic. A lock older than 60 minutes is a crashed run: remove it and take it fresh. A fresh lock is NOT a skip — retry the `mkdir` up to three times (the owner may be reading state that predates this merge's propagation), and only then defer with a § 6 note and continue to step 3. `touch` the lock dir after each command below, and release it (`rmdir`) on EVERY exit path.

      Holding the lock, re-sync (state may have moved while waiting) and confirm nothing is still open:

      ```bash
      [MAIN_REPO_ROOT]/.agents/skills/linear/scripts/linear.sh cache issues children [PARENT_ID] --recursive --pending
      ```

      Pending children remaining → rule out propagation lag first: re-sync and re-list up to three times, since a sibling merge's closure propagates on the same timescale. Still pending → report it in § 6 — "container [PARENT_ID] stays open ([N] children pending)", or, when `[ISSUE]` itself still reads pending, that this merge's own closure has not propagated and merge-pr should be re-run — then release the lock and continue to step 3.

      Empty → capture the canceled set first: the cascade below can flip a canceled child to completed, and the validation payload deliberately excludes canceled children.

      ```bash
      [MAIN_REPO_ROOT]/.agents/skills/linear/scripts/linear.sh cache issues children [PARENT_ID] --recursive
      ```

      Record each `canceled` entry as id + original state name in `[MAIN_REPO_ROOT]/tmp/container-canceled-[PARENT_ID]-[PR_NUMBER].lst` with the harness file-write tool, skipping the file when nothing is canceled. Then gate the completion:

      ```bash
      [MAIN_REPO_ROOT]/.agents/skills/linear/scripts/linear.sh issues validate-completion [PARENT_ID] --include-children-of [PARENT_ID] --container
      ```

      Proceed ONLY on `.all_ok == true`. A non-zero exit is the fail-closed guard and emits its diagnostic on stderr instead of the payload — do not parse JSON there, treat it as `all_ok=false`. On either failure: delete the snapshot, release the lock, report the failing `.results[]` entries or the stderr diagnostic in § 6, and stop — do not complete this container and do not climb to its parent.

      d. On `all_ok == true`, check the container's own `.results[]` entry first — `completed` means a concurrent sibling already closed it, so skip with a § 6 note rather than re-posting a summary. Otherwise write the bundle summary with the harness file-write tool (starting `## Bundle Complete`, one line per child with its PR) and complete:

      ```bash
      [MAIN_REPO_ROOT]/.agents/skills/linear/scripts/linear.sh issues complete [PARENT_ID] --summary-file [SUMMARY_FILE]
      ```

      A non-zero exit does NOT prove the transition failed — the client retries POSTs, so Linear may have completed the parent while the response was lost. Verify with `sync --reconcile` then `cache issues get [PARENT_ID]`, re-reading up to three times. Completed → continue into the repair and report the error alongside the actual outcome. Not completed → report in § 6, release the lock, and stop.

      e. **Repair the cascade**, on the skip branch too — a concurrent completer's cascade does the same damage. For every id in the snapshot, `issues bulk-get` in chunks of at most 50, verify each chunk returned one row per requested id, and restore any now reading `completed` back to its recorded state name, deepest entries first:

      ```bash
      .agents/skills/linear/scripts/linear.sh issues update [CHILD_ID] --state "[ORIGINAL_STATE_NAME]"
      ```

      Report every restoration in § 6, delete the snapshot, and release the lock. Then climb: if `[PARENT_ID]` has a container parent, re-run the step-2 sync first — the completion mutated Linear, not the cache — and repeat a-e for the grandparent.

3. **Sync the main repo** — always runs after a merge.

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/resolve-base-branch [MAIN_REPO_ROOT]
   ```
   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/github/scripts/git-https-auth -C [MAIN_REPO_ROOT] fetch --prune origin "+refs/heads/[BASE_BRANCH]:refs/remotes/origin/[BASE_BRANCH]"
   ```

   Target `origin` only — optional secondary remotes must not block closing the current PR. The explicit refspec keeps a narrowed `remote.origin.fetch` config from leaving `origin/[BASE_BRANCH]` stale. `git-https-auth` preserves normal SSH behavior unless a GitHub SSH remote is present with valid `gh` auth; keep every local ref update on plain `git` so credential-helper config is not exposed to merge-time repository hooks.

   **Resolve which checkout owns `[BASE_BRANCH]` before advancing it.** `merge --ff-only` advances whatever branch the target checkout has on `HEAD`, not `[BASE_BRANCH]` by name: run in a `[MAIN_REPO_ROOT]` sitting on a foreign branch it fast-forwards THAT branch, exits 0, and leaves local `[BASE_BRANCH]` where it was with nothing reported.

   ```bash
   git -C [MAIN_REPO_ROOT] rev-parse --abbrev-ref HEAD
   ```

   | `MAIN_HEAD_BRANCH` | Action |
   |--------------------|--------|
   | `[BASE_BRANCH]` | Advance in place: `git -C [MAIN_REPO_ROOT] merge --ff-only "origin/[BASE_BRANCH]"` |
   | Any other branch, or detached `HEAD` | Advance the local ref by name: `git -C [MAIN_REPO_ROOT] fetch . "refs/remotes/origin/[BASE_BRANCH]:refs/heads/[BASE_BRANCH]"`. Fetching from `.` re-uses the tracking ref the origin fetch already updated; the refspec form updates a branch no checkout has on `HEAD` and REFUSES a non-fast-forward |

   The by-name update fails when `[BASE_BRANCH]` is checked out in another worktree (`refusing to fetch into branch ... checked out at ...`). That is not a stale outcome — locate that worktree with `git -C [MAIN_REPO_ROOT] worktree list` and run `git -C [BASE_WORKTREE] merge --ff-only "origin/[BASE_BRANCH]"` there. Then `git -C [MAIN_REPO_ROOT] worktree prune`.

   **Blocking outcomes.** Each leaves local `[BASE_BRANCH]` behind origin. Never record the sync as done on any of them, and carry the named cause into § 6:

   | Outcome | Report |
   |---------|--------|
   | Either ff-merge refuses on uncommitted changes (`Your local changes to the following files would be overwritten by merge`) | **Blocking** — name every file git listed and the checkout it sits in, not an informational note |
   | Any of the three updates — the in-place ff-merge, the by-name update, or the `[BASE_WORKTREE]` ff-merge — is rejected as non-fast-forward | **Blocking** — local `[BASE_BRANCH]` has diverged; name both shas |
   | `[BASE_BRANCH]` is checked out in no reachable worktree and the by-name update failed for any other reason | **Blocking** — name the sha `origin/[BASE_BRANCH]` points at and the git error |

   Report the result in § 6 either way: the new sha when it advanced, a WARNING naming the stale local sha, the origin sha, and the cause when it did not.

4. **Clean up branches and worktrees**, scoped to this PR by default — never enumerate unrelated branches or sibling worktrees.

   ```bash
   gh pr view [PR_NUMBER] --json headRefName --jq .headRefName
   ```

   **Worktree disposal is by rule.** When the PR's worktree exists, its tree is clean (`git -C [WT_PATH] status --porcelain` empty), and its checked-out branch is `[PR_BRANCH]`, remove it in the removal step below — no question; `worktree remove` deletes the merged branch with the worktree and releases only this session's own lease. A dirty tree or a foreign-lease refusal from `worktree remove` keeps the worktree and its checked-out branch; a worktree sitting on a branch other than the merged one is kept as-is (the merged branch then falls to the standalone delete below). Report any kept worktree with its cause in the § 6 `Worktree` row.

   With no qualifying worktree, delete the local `[PR_BRANCH]` only when no worktree owns it. Confirm first:

   ```bash
   git -C [MAIN_REPO_ROOT] worktree list --porcelain
   ```

   A `branch refs/heads/[PR_BRANCH]` line means a worktree still has it checked out: do not delete (`branch -D` would fail), and note it in § 6. No such line, and the branch exists locally and is not current → `git -C [MAIN_REPO_ROOT] branch -D "[PR_BRANCH]"`.

   For `merge-pr all` or an explicit user request, also sweep the project: check each local branch with `gh pr list --head [BRANCH] --state all --json number,state`, auto-delete merged or closed branches with no worktree, leave open ones alone, and ask before removing a stale worktree or a branch with no PR — the sweep touches other items' trees, so asking stays. Compare `ls [TREES_DIR]/` against `worktree list --porcelain` for orphan directories, asking before removing any.

   Finally, when the rule selected the worktree for removal, remove it — **last**, because it destroys the session cwd:

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/worktree/scripts/worktree remove "[ISSUE_ID]"
   ```

   If that prints `SESSION CWD DESTROYED`, present § 6 immediately and tell the user to end the session — no further shell call will succeed.

## 6. Present Results

<output_format>

### ✅ MERGED — PR #[N]: [TITLE]

| Field | Value |
|-------|-------|
| Branch | [BRANCH_NAME] (deleted / kept) |
| Worktree | removed / kept — [cause] |
| Issue Tracker | [ISSUE_ID] → Done (via magic words) |
| Base sync | local `[BASE_BRANCH]` → [NEW_SHA] |

</output_format>

The `Base sync` row is never omitted. When § 5 step 3 hit a blocking outcome it carries the warning instead of a sha: `⚠️ local [BASE_BRANCH] STALE at [LOCAL_SHA] (origin/[BASE_BRANCH] at [ORIGIN_SHA]) — [CAUSE]`. The `Worktree` row reports `removed`, or `kept — [dirty tree | branch not merged | foreign lease]` when the § 5 step 4 rule declined removal (no worktree existed → omit the row). Add a `Review gate` row only when the merge did not proceed on a plain `approved`/`reviewed` verdict — `⚠️ reviewer-down proceed (no reviewer posted; PR_REVIEW_ON_TIMEOUT=proceed)` or `⚠️ forced (user override)` — so a non-organic gate is visible in the record.

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

**Managed**: return to the parent workflow's next section. **Standalone**: session complete.
