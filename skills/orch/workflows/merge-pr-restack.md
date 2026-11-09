# Merge-pr restack cycle

Use this cycle for a `conflicting` `queue-watch` verdict, and for a `worktree-push-base-conflict` refusal that [submit-pr.md](submit-pr.md) § 2 step 1 routes here: steps 1-3, then continue that caller. Step 4 returns a merge caller to `merge-pr.md`. [§ Unarm at a stop](#unarm-at-a-stop) runs step 1 alone, to unarm a PR, and pushes or restacks nothing. A base conflict is not a CI failure.

With `ORCH_DELIVERY=push-base`, skip step 1 because no PR exists. Run step 2 through completion of the guarded restack and its rules reload. Before that step's validation, return to [submit-pr.md § 2.1](submit-pr.md#21-base-publication) from its entry. That shared route checks internal review, prepares, returns control for another rules reload, then validates and transports the exact prepared head against its pinned base. Skip step 3 and the remaining PR proof and merge steps. A failed restack, validation or transport hands back without a completion notice.

1. Unarm the PR before any push. Read its node id and live arm with `env -u GH_REPO -u GITHUB_REPOSITORY gh pr view [PR_NUMBER] --json id,autoMergeRequest`. If `autoMergeRequest` is set, disable auto-merge first with `github.sh merge-queue-mutation disablePullRequestAutoMerge [PR_NODE_ID]`. Then read the PR's `mergeQueueEntry` through the GraphQL query [merge-pr.md § 5](merge-pr.md#5-execute-the-merge) step 1's Entry-ahead wait runs, with this PR's number and its repository's owner and name: `gh pr view --json` exposes no queue field. If it is non-null, call `github.sh merge-queue-mutation dequeuePullRequest [PR_NODE_ID]`, then read `autoMergeRequest` and `mergeQueueEntry` again. Either still set means hand back without pushing. This order prevents an armed PR from re-entering the queue while it is dequeued.

2. Resolve the managed worktree, then ask whether a fix round is in flight before rebasing anything:

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/worktree/scripts/worktree path [ISSUE]
   ```

   Write `[WT_PATH]/tmp/restack-live-round-[ISSUE].json` with the harness file tool as `{"op": "record-push", "mode": "check-live-round", "worktree": "[WT_PATH]"}`, then run it:

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/orch-runtime op --item [ISSUE] --request [WT_PATH]/tmp/restack-live-round-[ISSUE].json
   ```

   It pushes nothing. Exit 0 is the only answer that permits the restack. Exit 3 names the fix round in flight as the reply's `live_round`, a round whose record stands in the worktree with no receipt beside it, and a refusal exits 1 with its keyed line on stderr; any other exit hands back too. `worktree create [ISSUE] --reuse` rebases outside this check too, and carries no live-round refusal of its own.

   The restack takes [SKILL.md § The Cycle](../SKILL.md#the-cycle), Rules reload after a rebase. Then start the guarded restack:

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/worktree/scripts/worktree create [ISSUE] --restack
   ```

   No issue worktree means hand back. On conflicts, resolve every listed file, stage it, and run `worktree restack continue [ISSUE]` until complete. Never force-push over an unresolved base.

   Then resolve validation for the restacked head before step 3 pushes it. Under `push-first`, a covered `ci` route records completed local edits with required CI pending and starts no local range command. Step 4's existing exact-head CI wait proves the published head. Required CI supplies the full record. Bind the base branch the restack rebased onto as `[BASE_BRANCH]`, and read the mode a range run in the worktree records:

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/resolve-base-branch [WT_PATH]
   ```

   ```bash
   RESTACK_MODE_ARGS=()
   if ! PR_ORDER="$([MAIN_REPO_ROOT]/.agents/skills/orch/scripts/pr-order [WT_PATH])"; then
     PR_ORDER=pr-order=review-first
   fi
   [[ "$PR_ORDER" != pr-order=push-first ]] || RESTACK_MODE_ARGS=(--base origin/[BASE_BRANCH])
   [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/orch-runtime validate entry --resolve-mode --worktree [WT_PATH] ${RESTACK_MODE_ARGS[@]+"${RESTACK_MODE_ARGS[@]}"}
   ```

   A non-zero exit from `resolve-base-branch`, `--resolve-mode`, or the `--record` read below hands back with that command's stderr and pushes nothing.

   For the `ci` mode, record the pending run through the runtime's validation entry:

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/orch-runtime validate entry --worktree [WT_PATH] --validate-mode ci --base origin/[BASE_BRANCH] --restack
   ```

   `validate-mode=ci` runs that command with `--validate-mode ci`. Its `--restack` flag skips selector preview and scoped suites. The restack's starts, this one and the range run below, carry no `--run-id`: a restack runs outside a round's admission, so the entry records the run itself, the route [dev SKILL.md § Long-Running Validation](../../dev/SKILL.md#long-running-validation) names for a delegation with no admission. Successful CI admission records CI pending without a local command and returns at once. A refusal runs the range command and records its cause on the start record's `ci-fallback=` line, which `--record` reports. Read the result through `--record` before step 3. `validate-mode=full` means the project sets no `DEV_VALIDATE_RANGE_CMD`. Both `full` and `range` first ask whether the restacked head can skip its range re-test. The check takes the worktree's newest passing run as its candidate, and retests where a later run there did not pass:

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/restack-skip --worktree [WT_PATH] --base origin/[BASE_BRANCH]
   ```

   Exit 0 prints `restack=skip condition=[CONDITION] ... head=[HEAD] paths=[PATHS]`: the restacked tree is that run's tree merged with the base's new commits, a merge that conflicted nowhere (`no-conflict`) or only over the version field commit-guards reads and changelog entries in the files it left conflicted (`version-only`). It starts no run. Record the skip in workflow state, with `[CONDITION]` the line's `condition=` value, `[VALIDATED_HEAD]` its `validated-head=` value and `[PATHS]` its `paths=` value, then go to step 3:

   ```bash
   jq -n --arg head [HEAD] --arg condition [CONDITION] --arg validated [VALIDATED_HEAD] --arg paths [PATHS] '{head: $head, condition: $condition, validated_head: $validated, paths: (if $paths == "none" then [] else ($paths | split(",")) end)}' > tmp/restack-skip-[ISSUE].json
   .agents/skills/orch/scripts/orch-runtime state upsert --item [ISSUE] /restack_skips --key head tmp/restack-skip-[ISSUE].json
   ```

   A lane also rewrites its status file's validation line, which names the skip, its condition and its paths, as [dev-start.md § Validation status](dev-start.md#validation-status) sets out. A skip proves tree equivalence, and no more: a later run at that tree which did not pass voids the skip's proof with every other proof of the tree, so step 3's read answers `missing` and the restack hands back. Step 3 asks the runtime for that proof before either caller can admit the queue or merge. Any other skip exit under `full` goes to step 3 with no run. Any other exit under `range`, whatever it prints, runs the range command over the branch as it sits on the base after the restack, started without `--run-id` and polled as [dev SKILL.md § Long-Running Validation](../../dev/SKILL.md#long-running-validation) sets out for the harness:

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/orch-runtime validate entry --worktree [WT_PATH] --validate-mode range --base origin/[BASE_BRANCH]
   ```

   Bind `[RUN_DIR]` to the run's `run-dir=` line and read its head and times after it ends:

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/orch-runtime validate entry --record --run-dir [RUN_DIR]
   ```

   After a confirmed push, step 3's push records the newest finished, timed run for the pre-push restacked head as the item's restack `validate` stage, with the run's proof and outcome, and adds its seconds to `validate_rounds`, once per run directory. A skipped re-test adds no stage for an earlier head's run. A failed range run reaches no push and records no restack stage.

   A start refused as `run-live` ran nothing and is no result: take [dev-implement.md § 5. Validate](../../dev/workflows/dev-implement.md#5-validate)'s route for that refusal, then start the range run again.

   A `validate-mode=ci` record with `verdict=pending` goes on to step 3. It is no CI pass. For local runs, only `validate=pass` goes on to step 3. Any other result, `FAILING`, `no-verdict`, `state=timeout` or `state=lost`, pushes nothing and hands back with the verdict and the run's log path, as a fix round's red verdict ends its workflow with no second validation run. The PR stays unarmed from step 1, and this cycle never reaches step 4.

3. Push through the guarded owner. Write `[WT_PATH]/tmp/restack-push-[ISSUE].json` with the harness file tool as `{"op": "record-push", "mode": "branch", "worktree": "[WT_PATH]"}`, then run it:

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/orch-runtime op --item [ISSUE] --request [WT_PATH]/tmp/restack-push-[ISSUE].json
   ```

   This step is not skippable and no other push replaces it: the restack in step 2 rewrote every branch commit, and this request is the only thing that reconciles the SHAs workflow state recorded before it. It reconciles the rebase map the restack left before the push, then the hop the push itself wrote, and the reply's `reconciled` rows name each map read with the recorded commits it moved. The reply's `push` carries the worktree skill's own answer, its exit and its output. Where the push confirmed a restacked head, the reply's `stage` names the run directory it recorded, `none` where no run qualified, or `unrecorded` with its cause, and the push's verdict stands either way. Exit 0 is a confirmed push. A push that failed exits with its own status, a refusal exits 1, and 75 means the push's answer was lost: its `push_attempt` stays `attempted`, and the next request settles it from the remote before it pushes again. Any non-zero exit hands back, because republishing `Fixed in <sha>` replies or a closing comment over unreconciled SHAs publishes commits the branch does not have.

   A `ci` record needs no local head comparison after the push. Its proof is the exact published head, including any head the push rebased. After a local range run, compare the pushed head with the `head=` value of that run's record; after a skip, with the `head=` value of the skip line:

   ```bash
   git -C [WT_PATH] rev-parse HEAD
   ```

   A different head means the push rebased the branch again, onto a base that moved during the run, and pushed a head no run validated. The PR is still unarmed from step 1, so that head cannot enter the queue. Run step 2's mode read and skip check again on it, recording a new skip for that head. Where range mode does not skip, run its range command and record read. The proof read below uses this resulting head. Route a non-passing result as step 2 does. After a pass, bind `[RUN_DIR]` to this second run and record its stage through the same owner: write `[WT_PATH]/tmp/restack-stage-[ISSUE].json` with the harness file tool as `{"op": "record-push", "mode": "record-restack-validation", "worktree": "[WT_PATH]", "run_dir": "[RUN_DIR]"}`, then run it:

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/orch-runtime op --item [ISSUE] --request [WT_PATH]/tmp/restack-stage-[ISSUE].json
   ```

   This request publishes nothing and reads no rebase map. Its stage write is advisory: the reply's `stage` names the run directory, or `unrecorded cause=no-run` where that run is unfinished or validated another head, and it exits 0 either way. A pass or a skip takes the proof read below with no second push, and a base that moves again returns through the next `queue-watch` verdict. The worktree skill's `--no-rebase` push flag cannot hold the head still here: that push carries none of the restack's force-with-lease authorization, and git refuses the rewritten branch as a non-fast-forward push.

   **Restack proof.** Before either caller resumes, bind `[WORKTREE_PATH]` to `[WT_PATH]`, `[STATE_KEY]` to `[ISSUE]` and `[PREPARED_HEAD]` to the pushed head, and keep step 2's `[BASE_BRANCH]`. Read the current head's recorded skip. Where one stands, ask the runtime whether the item's proof rows prove the pushed head: a pass at its tree over the new base, or the run the skip is equivalent to, read by the head (`restack-skip` owns the equivalence; the reader takes the skip's validated run as the tree's). A range pass counts where the project declares a range command and no CI context; a full pass covers the tree whole. A reused tree alone supplies no passing validation. This read starts no validation, and the block prints the reader's reply:

   ```bash
   if ! RESTACK_SKIPS="$(.agents/skills/orch/scripts/orch-runtime state get --item [STATE_KEY] /restack_skips)"; then
     exit 1
   fi
   if ! RESTACK_PROOF_HEAD="$(jq -r --arg head [PREPARED_HEAD] '[(.result.value // [])[] | select(.head == $head)] | last | .validated_head // empty' <<<"$RESTACK_SKIPS")"; then
     exit 1
   fi
   if [[ -n "$RESTACK_PROOF_HEAD" ]]; then
     PREPARED_TREE="$(git -C [WORKTREE_PATH] rev-parse "[PREPARED_HEAD]^{tree}")"
     PREPARED_BASE="$(git -C [WORKTREE_PATH] merge-base [PREPARED_HEAD] origin/[BASE_BRANCH])"
     RESTACK_PROOF="$(.agents/skills/orch/scripts/orch-runtime read-proof --item [STATE_KEY] --need restack --tree "$PREPARED_TREE" --head [PREPARED_HEAD] --base "$PREPARED_BASE")" || exit $?
     printf '%s\n' "$RESTACK_PROOF"
     [[ "$(jq -r '.result.proof' <<<"$RESTACK_PROOF")" != missing ]] || exit 1
   fi
   ```

   A nonzero exit hands back with the printed reply and keeps the PR unarmed. This includes submission's steps 1-3 route, before creation or update can arm the queue. Keep the reader's reply, its `proof` word and the rows it names, with the merge decision. A `missing` reply names in `lacks` the tree and the narrowest mode the project declares. A `pending` answer stays pending until the existing exact-head CI wait or queue proves it.

4. The head changed. Re-confirm the gate mode, then return to `merge-pr.md` § 5 step 1 to read the new exact head, repeat its proof read, wait for CI and take the merge route again.

## Unarm at a stop

A PR [submit-pr.md](submit-pr.md) § 2 step 5 armed at creation stays armed until something unarms it, and a lane that stops leaves it to merge with no `queue-watch` guard and none of [merge-pr.md](merge-pr.md) § 5 steps 2-6. So every run that ends without a merged PR takes this section first: [submit-pr.md](submit-pr.md) § 2 step 5 on a refused re-arm, a `MERGE_READY = false` stop at [submit-pr.md](submit-pr.md) § 6.1, and every [merge-pr.md](merge-pr.md) hand-back. The caller supplies `[STATE_KEY]` and `[STOP_DIR]`, the directory its own stop route renders into.

Run step 1 above on the PR. It reads the live arm and queue membership and unarms in its order; a PR it finds neither armed nor queued needs nothing. A hand-back means its final read still found the PR armed or queued: run step 1 once more. A second hand-back replaces the caller's stop with one saying the PR is still armed, which `record` writes over any earlier stop and every later `record-if-empty` keeps, and the run ends there:

```bash
.agents/skills/orch/scripts/orch-runtime state post-pr-stop record --item [STATE_KEY] --name disarm-unconfirmed --gate merge --remaining "PR #[PR_NUMBER] is still armed or queued: the lane could not disarm it, and GitHub can merge it with no lane watching" --comment-file [STOP_DIR]/post-pr-stop-[STATE_KEY].md
```

```bash
env -u GH_REPO -u GITHUB_REPOSITORY .agents/skills/github/scripts/github.sh post-comment [PR_NUMBER] --body-file [STOP_DIR]/post-pr-stop-[STATE_KEY].md
```

In a lane, also tell the overseer: write a notice naming the PR and the stop to `[STOP_DIR]/disarm-unconfirmed-[STATE_KEY].md` with the harness file-write tool, then send it:

```bash
.agents/skills/mailbox/scripts/lane-mail notice --item [STATE_KEY] --file [STOP_DIR]/disarm-unconfirmed-[STATE_KEY].md
```
