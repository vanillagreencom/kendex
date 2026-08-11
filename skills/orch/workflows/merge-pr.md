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
re-checking. The two-command shape below is a Claude Code shell; in **Codex** the
`approval=never` classifier rejects both the multi-command block and the `sleep`,
so re-check once as a single command per tool call and skip the backoff:

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
  - `review` — commenting-only reviewers never approve, so `not_approved` is expected; the gate is instead a formal review of the current head commit from a non-author reviewer (any state — COMMENTED counts) plus zero unresolved threads. Poll with `.agents/skills/orch/scripts/approval-wait [PR_NUMBER] 30 --json --mode review` and treat `reviewed` as the met gate (approval-wait nudges silent reviewers per `PR_REVIEW_NUDGE`/`PR_REVIEW_NUDGE_SECS`, once per head). With `PR_REVIEW_ON_TIMEOUT=proceed`, a deadline reached with zero unresolved threads and no reviewer evidence returns `proceeded` (exit 0) instead of `timeout` — treat it as a met gate (a reviewer-down proceed) and continue to § 4, recording it in the § 7 report so the reviewer-down merge is visible. Unlike `submit-pr`, `merge-pr` gates live and initializes no workflow-state record (and resolves no `[ISSUE_ID]` until § 4.1), so there is no `pr_approval` field to set here — the § 7 note is the provenance. It only fires when every reviewer stayed silent; an open thread or a `changes_requested` still blocks. The proceed is a LOCAL verdict — orch posts no status and manufactures no review evidence, so a repo-side CI gate that requires review evidence stays red unless the engine's `REVIEW_GATE_MODE=off` or an operator's manual override status governs it.
  - `approval` — a GitHub-native approval verdict is required: `reviewDecision == "APPROVED"`, or, when `reviewDecision` is empty (no required-review protection), at least one reviewer whose latest review is APPROVED and none whose latest review is CHANGES_REQUESTED (any reviewer counts, human or bot). Without it, do not auto-merge: poll with `.agents/skills/orch/scripts/approval-wait [PR_NUMBER] 30 --json` or ask the user. `PR_REVIEW_ON_TIMEOUT=proceed` applies here too — the poller returns `proceeded` (exit 0) instead of `timeout` when the deadline is reached with zero unresolved threads and no reviewer engagement at all (in approval mode an active COMMENTED review still times out, since a reviewer that engaged but did not approve is not "down"); treat `proceeded` as a met gate (a reviewer-down proceed) and continue to § 4, recording it in the § 7 report. As above, `merge-pr` keeps no workflow-state, so the § 7 note is the provenance rather than a `pr_approval` field.

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

   Exit `75` = QUEUED FOR AUTO-MERGE — treat as success-pending and run the queue watch below. Ejection is per-PR: a failed merge-group run removes only this PR from the queue while other queued PRs re-test and merge independently, so each session's own merge-pr watch owns recovery for its own PR and parallel sessions never need to coordinate.

   **Watch the queue** — one command, every harness. It blocks until the merge-queue outcome is decided:

   ```bash
   .agents/skills/orch/scripts/queue-wait [PR_NUMBER] 30 600 --json
   ```

   The printed `verdict` routes the table below directly, and `status` is `complete`/`timeout`/`error`. Exit `0` only for `merged`; `1` for `ejected`/`disarmed`/`closed`/`queued`/`not_queued`/non-auth error; `3` on GitHub auth failure. The script holds `WAS_QUEUED` — whether any earlier poll observed the PR queued or armed — inside its own loop, which is the state a per-poll re-entry cannot carry, and it delegates the failed-required-check disarm probe to `ci-wait` internally (`--no-check-probe` opts out). Never poll `gh pr view --json mergeable` — it stays UNKNOWN after merge and loops forever.

   > If you are running in **Codex**: run exactly that one command and route on its `verdict`. Do not hand-roll the poll loop below — `sleep`, `for`/`while`, and multi-command blocks are rejected outright by the `approval=never` classifier, and a per-poll re-entry has no memory of `WAS_QUEUED`, so it cannot distinguish an ejected PR from one that was never queued (vstack#819).

   <details><summary>Raw per-poll signals (Claude Code, for inspecting a verdict)</summary>

   In the **Claude Code** shell shape, each poll runs the two commands below, then routes on the same table; `sleep 30` between polls, at most 20 polls (~10 min). `queue-wait` reads exactly these two signals, so use them only to inspect what it saw — not as a substitute for it.

   ```bash
   gh pr view [PR_NUMBER] --json state,mergedAt
   ```
   ```bash
   gh api graphql -f query='query($owner: String!, $repo: String!, $number: Int!) { repository(owner: $owner, name: $repo) { pullRequest(number: $number) { isInMergeQueue mergeQueueEntry { state } autoMergeRequest { enabledAt } } } }' -F owner='{owner}' -F repo='{repo}' -F number=[PR_NUMBER]
   ```
   `gh pr view --json` exposes no queue-membership field (verified against gh 2.96.0), so the GraphQL query is required; gh fills the `{owner}`/`{repo}` placeholders from the current repo. `WAS_QUEUED` is true once any poll has observed `isInMergeQueue == true`, `mergeQueueEntry` non-null, or `autoMergeRequest` non-null.

   </details>

   | `queue-wait` verdict | Observation | Meaning | Action |
   |----------------------|-------------|---------|--------|
   | `merged` | `state == "MERGED"` | Merge landed | → step 3 |
   | — (keeps polling) | `OPEN`, still queued or armed, no failed required check | Waiting on checks / queue position | Continue polling |
   | `ejected` | `OPEN`, `WAS_QUEUED`, now `isInMergeQueue == false` and `mergeQueueEntry == null`, not merged | **Ejected** — the merge-group CI run failed and GitHub removed this PR from the queue | Recovery cycle below |
   | `disarmed` | `OPEN` on a plain auto-merge repo, `autoMergeRequest == null` after `--auto` armed it, or a required check failed (`queue-wait` probes with `.agents/skills/orch/scripts/ci-wait [PR_NUMBER] 15 30 --json` → `verdict=fail`; `cause` says which) | Auto-merge disarmed by a check failure | Recovery cycle below |
   | `closed` | `state == "CLOSED"`, never merged | The PR was closed out from under the merge | Skip steps 3-6 and hand back to the user |
   | `queued` | Poll bound reached, still queued/armed | Deep queue | Report still-queued: the merge stays armed and fires when checks and protection clear. Skip steps 3-6 (they assume a landed merge) and note in § 7 that sync/cleanup should be re-run via `merge-pr [PR_NUMBER]` once merged |
   | `not_queued` | No poll ever saw the PR queued or armed (arming grace expired) | The `--auto` merge never armed — nothing will fire on its own | Re-run `pr-merge [PR_NUMBER] --auto` once; if it still does not arm, surface the failure and hand back |

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
   3. **Re-arm and resume**: re-run `pr-merge [PR_NUMBER] --auto` (command above), then re-run `queue-wait [PR_NUMBER] 30 600 --json` with a fresh poll budget.

3. **Sync issue tracker cache, then close a finished container** — **Linear only** (merged PRs close issues via magic words; cache must reflect done states):
   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/linear/scripts/linear.sh sync --reconcile
   ```

   **Container completion — the container closes LAST.** The merge just closed `[ISSUE]` (from § 4.1); if that was the final open child of a container parent, complete the container now. Skip if no `[ISSUE]` was extracted in § 4.1, and skip the WHOLE step (sync included, per the Linear-only header) for GitHub work items: resolve the tracker per SKILL.md → Tracker Resolution first — an `issue-N` key (any casing; `pr-issue` may uppercase it) is a GitHub work item, never a Linear identifier, and running Linear commands for it would fail a GitHub-only merge outright. Mechanical check:

   a. Read the parent:
      ```bash
      [MAIN_REPO_ROOT]/.agents/skills/linear/scripts/linear.sh cache issues get [ISSUE]
      ```
      `.parent_id` empty → continue to step 4.
   b. Fetch the parent with its bundle (`cache issues get [PARENT_ID] --with-bundle`). Check the title FIRST: a `(one PR)` marker always wins and keeps the bundle single-PR, even when it carries the `agent:multi` label. Without the marker, the parent is a CONTAINER when it has children or carries the `agent:multi` label. Not a container → continue to step 4.
   c. **Serialize per parent FIRST — before even the pending check.** Two final siblings merging concurrently could otherwise each observe the other as pending and both return, leaving no later merge to close the container. Create the scratch dir first — `mkdir -p [MAIN_REPO_ROOT]/tmp` (git-ignored, absent on fresh checkouts; without it the lock mkdir below fails before anything is protected) — then take the per-parent lock with `mkdir [MAIN_REPO_ROOT]/tmp/container-close-[PARENT_ID].lock` (mkdir is atomic — it either creates or fails). If it already exists: a concurrent sibling merge is mid-sequence — UNLESS the lock dir's mtime is over 60 minutes old (a crashed run; remove it and take it fresh — safe because every LIVE run refreshes its lock as described next). A fresh lock is NOT a skip: wait ~30 seconds and retry the `mkdir`, up to 3 attempts (in Codex: one single-command retry per tool call, no sleep — same form as the recheck note below), because the current owner may be reading state that predates THIS merge's propagation; if it returns on that stale view and this contender also skipped, no later merge would remain to close the parent. A contender that acquires the lock on retry runs the FULL close sequence from the re-sync. Only after all attempts still find the lock held, defer with the § 7 note ("container close deferred: concurrent attempt holds the lock — rerun merge-pr if the container stays open") and continue to step 4. While holding the lock, `touch` the lock dir after EACH command in this sequence (pending check, recovery scan, validation, completion, repair) — the commands are seconds apart, so an mtime over 60 minutes genuinely means a crashed run, never a slow live one. Everything below through the final snapshot deletion runs while holding the lock; release it (`rmdir`, after removing this run's snapshot when one exists) on EVERY exit path — pending-children return, completion, skip, and the validation-fail stop.

      Holding the lock, re-run the step-3 sync (state may have moved while waiting for the lock), then confirm nothing is still open:
      ```bash
      [MAIN_REPO_ROOT]/.agents/skills/linear/scripts/linear.sh cache issues children [PARENT_ID] --recursive --pending
      ```
      Pending children remain → first rule out propagation lag: when `[ISSUE]` itself is among the pending entries (its closure may still be propagating), OR any pending entry changed recently — the children listing carries no timestamps, so fetch the pending entries themselves (`[MAIN_REPO_ROOT]/.agents/skills/linear/scripts/linear.sh issues bulk-get [PENDING_IDS]`, chunks of at most 50) and read `updated_at`: any entry updated within the last few minutes counts as concurrently in flight (a sibling merge's closure propagates on the same timescale) — wait ~30 seconds, re-run the sync and this pending listing, and repeat up to 3 times before concluding. (In **Codex**, run each recheck as its own single-command tool call without the sleep — the round-trip spacing between calls provides the interval; same form as § 3.1.) If THIS was the final child, giving up here would leave the container open with no later merge to retry — after the bounded rechecks still show `[ISSUE]` pending, report that explicitly in § 7 ("container [PARENT_ID] not closed: merged child [ISSUE] still reads pending after 3 rechecks — rerun merge-pr or close the container manually"). Otherwise report "container [PARENT_ID] stays open ([N] children pending)" in § 7. Either way RELEASE the lock and continue to step 4. Empty → FIRST capture the canceled set (both branches below need it; the validation payload deliberately excludes canceled children, and post-completion reads only observe overwritten state):
      ```bash
      [MAIN_REPO_ROOT]/.agents/skills/linear/scripts/linear.sh cache issues children [PARENT_ID] --recursive
      ```
      Collect every entry whose `state_type` is `canceled` as `[CANCELED_IDS]`.

      The recursive listing is DEPTH-BOUNDED to the documented 3-level bundle hierarchy (parent → sub → nested — deeper nesting is out of contract across orch). GUARD the boundary instead of trusting it: for every captured entry at the deepest level, run the direct-child query `[MAIN_REPO_ROOT]/.agents/skills/linear/scripts/linear.sh cache issues children [ID]` as a single command (NOT a plain `cache issues get` — the default safe formatter omits `.children`, so that probe would always observe none) and READ its JSON output directly: the command always prints an array; an empty `[]` is the normal leaf answer (never an abort), any element is the hit. Any hit means the bundle exceeds the supported hierarchy and this snapshot CANNOT see all canceled descendants — STOP the container close (release the lock, report "bundle nests deeper than the supported 3 levels — flatten it, then rerun merge-pr" in § 7) rather than completing with a repair list that silently omits deeper canceled work.

      Holding the lock, check for leftover `[MAIN_REPO_ROOT]/tmp/container-canceled-[PARENT_ID]-*.lst` snapshots from interrupted prior runs (the lock guarantees none belong to a live attempt). Phase is encoded in the name: a `*-pending.lst` snapshot means the run believed no completion cascaded — but VERIFY against the parent before discarding: parent `state_type` COMPLETED means a delayed completion landed after that run's verification window (the retried POST case) — treat the snapshot as cascaded (repair it, below) instead of discarding. Parent not completed → delete it WITHOUT repairing (repairing would revert children legitimately reopened and completed since). A `*-cascaded.lst` snapshot means the run reached the completion request — but the rename precedes the request, so VERIFY against the parent before repairing: parent `state_type` NOT completed → the request never landed (no cascade); discard the snapshot exactly like a pending one. Parent completed → run the cascade repair on the UNION of cascaded snapshots IMMEDIATELY, before validation: for rows recorded with a canceled `state_type` (older snapshots list only canceled entries — treat rows without a recorded type as canceled), restore any that now reads `state_type == "completed"` back to its recorded original state (deepest first), then run the same convergence pass as § 4.3's repair over each snapshot's full row set — EXCEPT ids whose completion clearly postdates the parent's (when the payload carries `completed_at`/`updated_at`, a child completed well after the parent was not flipped by this cascade but deliberately reopened and finished since; leave those and flag them in § 7 for review instead of silently reverting) (the interrupted completion already cascaded them, and validating first would count them as completed bundle children and fail on their missing summaries); delete each repaired file, then run `sync --reconcile` again and re-run the children listing so `[CANCELED_IDS]` reflects the restored states (the repairs went to live Linear — without the re-sync the cached listing still reads them as completed, they would drop out of `[CANCELED_IDS]`, and this run's completion would cascade them to Done with nothing left to repair them). PERSIST the pre-completion state of the WHOLE subtree before anything mutates — one `ID<TAB>ORIGINAL_STATE_NAME<TAB>ORIGINAL_STATE_TYPE` row for EVERY descendant in the full children listing, not only the canceled ones: restoring a canceled intermediate node can itself cascade cancellation into ITS subtree, and repairing that collateral needs each descendant's recorded state, canceled or not. Write with the harness file tool to `[MAIN_REPO_ROOT]/tmp/container-canceled-[PARENT_ID]-[MERGED_PR]-[RUN_TS]-pending.lst`, where `[MERGED_PR]` is the PR number just merged and `[RUN_TS]` is THIS run's `git-context timestamp compact` (skip when `[CANCELED_IDS]` is empty — with nothing canceled there is nothing a cascade can wrongly flip back; the PR number keeps names unique even at one-second timestamp resolution, and the lock means no two live attempts write here anyway). Then validate, and gate the completion on the result:
      ```bash
      [MAIN_REPO_ROOT]/.agents/skills/linear/scripts/linear.sh issues validate-completion [PARENT_ID] --include-children-of [PARENT_ID] --container
      ```
      On exit 0, capture the JSON; the gate is the payload: proceed ONLY when `.all_ok == true`. A NONZERO exit is the fail-closed container guard and emits the error on stderr INSTEAD of the `{results, all_ok}` payload — do not try to parse JSON there; treat it as `all_ok=false` with the stderr text as the diagnostic. On either failure shape, DELETE this run's just-persisted `*-pending.lst` snapshot and release the lock (nothing mutated, so there is no interrupted cascade to recover), report the failure (the `.results[]` entries — id, state, what failed — or the stderr diagnostic) in § 7, and stop — do not complete this container and do not climb to its parent.

      On `all_ok == true`, check the container's own entry in `.results[]` first: `state_type == "completed"` means a concurrent sibling merge (or a retried run) already closed it — skip the completion with a note in § 7 instead of re-posting a summary. Otherwise — and ONLY on this branch (`issues complete` never runs on the skip branch; `[SUMMARY_FILE]` exists only here) — ensure `[MAIN_REPO_ROOT]/tmp` exists, write the bundle summary with the harness file-write tool to `[MAIN_REPO_ROOT]/tmp/container-summary-[PARENT_ID]-[TIMESTAMP].md` (timestamp via `git-context timestamp compact`; starts with `## Bundle Complete`, one line per child with its PR), use that path as `[SUMMARY_FILE]`, then — only when a snapshot was persisted (`[CANCELED_IDS]` non-empty; with an empty set there is no file to rename and nothing to repair) — RENAME this run's snapshot from `-pending.lst` to `-cascaded.lst` (rename is atomic; from this instant a crash leaves a snapshot that recovery MUST repair — before it, one that recovery must discard), and complete NOW — the completion runs BEFORE the cascade repair below, because it is exactly what the repair repairs:
      ```bash
      [MAIN_REPO_ROOT]/.agents/skills/linear/scripts/linear.sh issues complete [PARENT_ID] --summary-file [SUMMARY_FILE]
      ```
      If `issues complete` exits NONZERO, do NOT assume the transition failed to apply — the client retries POSTs, so Linear may have completed the parent (and cascaded) while every response was lost. VERIFY with two commands (one per call): `[MAIN_REPO_ROOT]/.agents/skills/linear/scripts/linear.sh sync --reconcile`, then `[MAIN_REPO_ROOT]/.agents/skills/linear/scripts/linear.sh cache issues get [PARENT_ID]` and read its `state_type` field. Parent COMPLETED → the cascade ran; keep the `-cascaded.lst` marker, report the completion error alongside the actual outcome in § 7, and continue into the repair pass below as if completion had succeeded. Parent NOT completed on the first read → re-verify twice more (~30 seconds apart; Codex: one single-command re-read per tool call) — the retried POST can become visible just after a single read. Still not completed → when a snapshot was persisted (`[CANCELED_IDS]` non-empty — with an empty set there is no file, and skipping this must not skip the lock release), rename it back to `-pending.lst`; report in § 7, release the lock, and stop — and note for the retry, branching on the DIAGNOSTIC: "Completion summary comment failed" → no comment posted — retry WITH `--summary-file` as normal (retrying without it would close the container with no Bundle Complete comment); a state-TRANSITION failure (the command's retry-without-summary guidance) → the comment may have posted — confirm `## Bundle Complete` is present in the parent's comments and then finish without re-posting (re-run without the summary flags, or a transition-only `issues update [PARENT_ID] --state "Done"`); when the comment is NOT confirmed present, keep the summary file. On success: the summary starts with `## Bundle Complete`. Containers hold no implementation state — no worktree, no branch, no workflow-state beyond bookkeeping — so there is nothing else to clean up. Report the closed container in § 7.

      AFTER the completion (and also on the skip branch — a concurrent completer's cascade does the same damage), when `[CANCELED_IDS]` is non-empty, run the cascade repair (the § 4.3 cascade can flip a canceled child to a completed state, and a canceled child must stay canceled): `issues bulk-get [CANCELED_IDS]` (chunks of at most 50 ids — the command caps at 50 rows per call), and restore every id whose `state_type` now reads `completed` (terminality by type, never state names) with `.agents/skills/linear/scripts/linear.sh issues update [CHILD_ID] --state "[ORIGINAL_STATE_NAME]"` — the state recorded beside the id in the snapshot (older snapshots without a recorded name fall back to "Canceled") — restoring DEEPEST entries first (an already-terminal child is untouched by its parent's later cancel-cascade), and noting restorations in § 7. THEN run one CONVERGENCE pass over the whole snapshot: `issues bulk-get` every recorded id — in CHUNKS of at most 50 ids per call (the command caps its query at 50 rows; a larger container read in one call would silently drop the overflow), verifying each chunk returned one row per requested id and re-fetching any missing before proceeding — and restore any whose live `state_type` no longer matches its recorded one (a restored intermediate's own cancel-cascade may have flipped a legitimately completed descendant — put each back to ITS recorded state name); repeat the pass once more if it changed anything, then report any id still mismatched in § 7 for review. Only a convergence pass that READ every snapshot id may precede the snapshot deletion below — never delete on a partial read. Only once the repair pass finishes (also when `[CANCELED_IDS]` was empty) DELETE this run's snapshot (whichever suffix it carries) and RELEASE the per-parent lock — the snapshot exists solely to recover an INTERRUPTED cascade: deleting it before the completion+repair sequence has run would leave a mid-sequence crash unrecoverable, and leaving it after a completed run would make a later merge treat this run as interrupted and revert children that were legitimately completed afterward. And STILL climb on the skip branch: an already-completed container's own parent may be waiting, so continue to the grandparent check either way. If `[PARENT_ID]` itself has a container parent, re-run the step-3 cache sync FIRST — the completion above mutated Linear, not the cache, and a stale cache would read the just-completed container as pending — then repeat a-c for the grandparent.

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
