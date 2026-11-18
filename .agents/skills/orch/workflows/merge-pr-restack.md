# Merge-pr restack cycle

Run this cycle when the base, not CI, blocks a pull request: on a `conflicting` `queue-watch` verdict in [merge-pr.md § 5](merge-pr.md#5-execute-the-merge) step 1, and on the `worktree-push-base-conflict` refusal [submit-pr.md](submit-pr.md) § 2 step 1 routes here. A submit-pr caller runs steps 1-3, then continues its own workflow; a merge-pr caller runs steps 1-4, and step 4 returns it to merge-pr.md. [§ Unarm at a stop](#unarm-at-a-stop) runs step 1 alone, and pushes or restacks nothing. Never route a base conflict into ci-fix.

With `ORCH_DELIVERY=push-base` no pull request exists: skip step 1. Run step 2 through the guarded restack and its rules reload, then, before step 2's validation, return to [submit-pr.md § 2.1](submit-pr.md#21-base-publication) from its entry. That route checks internal review, prepares, returns control for another rules reload, then validates and transports the exact prepared head against its pinned base. Skip step 3 and the pull-request proof and merge steps. A failed restack, validation or transport hands back without a completion notice.

1. **Unarm the PR before any push.** Read its node id and live arm with `env -u GH_REPO -u GITHUB_REPOSITORY gh pr view [PR_NUMBER] --json id,autoMergeRequest`. Where `autoMergeRequest` is set, disable auto-merge first with `github.sh merge-queue-mutation disablePullRequestAutoMerge [PR_NODE_ID]`. Then read the PR's `mergeQueueEntry` with the GraphQL query merge-pr.md § 5 step 1's Entry-ahead wait runs, given this PR's number and its repository's owner and name: `gh pr view --json` exposes no queue field. Where it is non-null, call `github.sh merge-queue-mutation dequeuePullRequest [PR_NODE_ID]`, then read `autoMergeRequest` and `mergeQueueEntry` again. Either still set hands back without pushing. The disarm comes first so an armed PR cannot re-enter the queue once dequeued.

2. **Restack the branch and validate the restacked head.** Resolve the managed worktree as `[WT_PATH]`:

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/worktree/scripts/worktree path [ISSUE]
   ```

   No issue worktree hands back. Ask whether a fix round is in flight before rebasing anything. Write `[WT_PATH]/tmp/restack-live-round-[ISSUE].json` with the harness file tool as `{"op": "record-push", "mode": "check-live-round", "worktree": "[WT_PATH]"}`, then send it:

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/orch-runtime op --item [ISSUE] --request [WT_PATH]/tmp/restack-live-round-[ISSUE].json
   ```

   It pushes nothing. Exit 0 alone permits the restack. Exit 3 names the round in flight as the reply's `live_round`: a round whose record stands in the worktree with no receipt beside it. A refusal exits 1 with its keyed line on stderr. Every exit but 0 hands back. `worktree create [ISSUE] --reuse` also rebases, outside this check, and has no live-round refusal of its own: never use it to restack.

   The restack takes the rules reload after a rebase of [SKILL.md § The Cycle](../SKILL.md#the-cycle). Start the guarded restack:

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/worktree/scripts/worktree create [ISSUE] --restack
   ```

   On conflicts, resolve every listed file, stage it, and run `worktree restack continue [ISSUE]` until the restack completes. Never force-push over an unresolved base.

   Then resolve validation for the restacked head, before step 3 pushes it. Bind the base branch the restack rebased onto as `[BASE_BRANCH]`, and read the mode a range run in the worktree records:

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/resolve-base-branch [WT_PATH]
   ```

   ```bash
   RESTACK_MODE_ARGS=()
   if ! PR_ORDER="$([MAIN_REPO_ROOT]/.agents/skills/orch/scripts/orch-runtime pr order [WT_PATH])"; then
     PR_ORDER=pr-order=review-first
   fi
   [[ "$PR_ORDER" != pr-order=push-first ]] || RESTACK_MODE_ARGS=(--base origin/[BASE_BRANCH])
   [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/orch-runtime validate entry --resolve-mode --worktree [WT_PATH] ${RESTACK_MODE_ARGS[@]+"${RESTACK_MODE_ARGS[@]}"}
   ```

   A refused or failed order read takes review-first. A non-zero exit from `resolve-base-branch`, from `--resolve-mode` or from the `--record` read below hands back with that command's stderr and pushes nothing.

   **`validate-mode=ci`.** Under `push-first`, a covered head records required CI as pending and starts no local range command; step 4's exact-head CI wait proves the published head. Record the pending run through the validation entry:

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/orch-runtime validate entry --worktree [WT_PATH] --validate-mode ci --base origin/[BASE_BRANCH] --restack
   ```

   `--restack` skips the selector preview and scoped suites. The restack's starts, this one and the range run below, carry no `--run-id`: a restack runs outside a round's admission, so the entry records the run itself, the route [dev SKILL.md § Long-Running Validation](../../dev/SKILL.md#long-running-validation) names for a delegation with no admission. A CI admission records CI pending with no local command and returns at once. A refused admission runs the range command and records its cause on the start record's `ci-fallback=` line, which `--record` reports. Read the result through `--record` before step 3.

   **`validate-mode=full` or `range`.** `full` means the project declares no `DEV_VALIDATE_RANGE_CMD`. Both first ask whether the restacked head can skip its range re-test. The check takes the worktree's newest passing run as its candidate, and retests where a later run there did not pass:

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/orch-runtime validate entry --restack-check --worktree [WT_PATH] --base origin/[BASE_BRANCH]
   ```

   Exit 0 prints `restack=skip condition=[CONDITION] ... head=[HEAD] paths=[PATHS]` and starts no run. The restacked tree is that run's tree merged with the base's new commits, a merge that conflicted nowhere (`no-conflict`) or only over the version field commit-guards reads and changelog entries in the files it left conflicted (`version-only`). Record the skip on the item, `[CONDITION]` being the line's `condition=` value, `[VALIDATED_HEAD]` its `validated-head=` value and `[PATHS]` its `paths=` value, then go to step 3:

   ```bash
   jq -n --arg head [HEAD] --arg condition [CONDITION] --arg validated [VALIDATED_HEAD] --arg paths [PATHS] '{head: $head, condition: $condition, validated_head: $validated, paths: (if $paths == "none" then [] else ($paths | split(",")) end)}' > tmp/restack-skip-[ISSUE].json
   .agents/skills/orch/scripts/orch-runtime op --item [ISSUE] --request-json '{"op":"record-pr-progress","step":"restack-skip","file":"tmp/restack-skip-[ISSUE].json"}'
   ```

   A lane also rewrites its status file's validation line to name the skip, its condition and its paths, as [dev-start.md § Validation status](dev-start.md#validation-status) sets out. A skip proves tree equivalence and no more: a later run at that tree that did not pass voids the skip's proof with every other proof of the tree, so handle step 3's `missing` reply before either caller resumes.

   Any other exit of the check under `full` goes to step 3 with no run. Any other exit under `range`, whatever it prints, runs the range command over the branch as it sits on the base after the restack:

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/orch-runtime validate entry --worktree [WT_PATH] --validate-mode range --base origin/[BASE_BRANCH]
   ```

   Bind `[RUN_DIR]` to the run's `run-dir=` line. A start that exits 3 printed `state=running`: its wait budget passed while the run continues, so follow it with `orch-runtime validate entry --wait --run-dir [RUN_DIR]` until it prints `state=done`, polling as [dev SKILL.md § Long-Running Validation](../../dev/SKILL.md#long-running-validation) sets out for the harness. A start refused as `run-live` ran nothing: take the route for that refusal in [dev-implement.md § 5. Validate](../../dev/workflows/dev-implement.md#5-validate), then start the range run again. Once the run ends, read its head and times:

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/orch-runtime validate entry --record --run-dir [RUN_DIR]
   ```

   Step 3's push records the newest finished, timed run for the pre-push restacked head as the item's restack `validate` stage, with the run's proof and outcome, and adds its seconds to `validate_rounds`, once per run folder. A skipped re-test adds no stage for an earlier head's run. A failed range run reaches no push and records no stage.

   Route the result. A `validate-mode=ci` record with `verdict=pending` goes on to step 3; it is no CI pass. For a local run, only `validate=pass` goes on to step 3. Any other result, `FAILING` (a stall among them) or `no-verdict`, or a record at `state=lost`, pushes nothing and hands back with the verdict and the run's log path, as a fix round's red verdict ends its workflow with no second run. The PR stays unarmed from step 1, and the cycle never reaches step 4.

3. **Push through the guarded owner.** Write `[WT_PATH]/tmp/restack-push-[ISSUE].json` with the harness file tool as `{"op": "record-push", "mode": "branch", "worktree": "[WT_PATH]"}`, then send it:

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/orch-runtime op --item [ISSUE] --request [WT_PATH]/tmp/restack-push-[ISSUE].json
   ```

   This step is never skipped, and no other push replaces it: step 2's restack rewrote every branch commit, and this request alone reconciles the SHAs the item recorded before it. It reconciles the rebase map the restack left, then the hop the push itself wrote; the reply's `reconciled` rows name each map read with the recorded commits it moved. The reply's `push` carries the worktree skill's own answer, its exit and its output. Where the push confirmed a restacked head, the reply's `stage` names the run folder it recorded, `none` where no run qualified, or `unrecorded` with its cause; the push's verdict stands either way. Exit 0 is a confirmed push. A failed push exits with its own status, a refusal exits 1, and 75 means the push's answer was lost: its `push_attempt` stays `attempted`, and the next request settles it from the remote before it pushes again. Every non-zero exit hands back: replies naming `Fixed in <sha>`, or a closing comment, over unreconciled SHAs would publish commits the branch does not have.

   A `ci` record needs no head comparison after the push: its proof is the exact published head, a head the push rebased included. After a local range run, compare the pushed head with the `head=` value of that run's record; after a skip, with the `head=` value of the skip line:

   ```bash
   git -C [WT_PATH] rev-parse HEAD
   ```

   A different head means the push rebased the branch again, onto a base that moved during the run, and pushed a head no run validated. The PR is still unarmed from step 1, so that head cannot enter the queue. Run step 2's mode read and skip check again on it, recording a new skip for that head; where range mode does not skip, run its range command and record read. The proof read below uses the resulting head. Route a result that did not pass as step 2 does. After a pass, bind `[RUN_DIR]` to this second run and record its stage through the same owner: write `[WT_PATH]/tmp/restack-stage-[ISSUE].json` with the harness file tool as `{"op": "record-push", "mode": "record-restack-validation", "worktree": "[WT_PATH]", "run_dir": "[RUN_DIR]"}`, then send it:

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/orch-runtime op --item [ISSUE] --request [WT_PATH]/tmp/restack-stage-[ISSUE].json
   ```

   This request publishes nothing and reads no rebase map. Its stage write is advisory: the reply's `stage` names the run folder, or `unrecorded cause=no-run` where that run is unfinished or validated another head, and it exits 0 either way. A pass or a skip takes the proof read below with no second push; a base that moves again comes back through the next `queue-watch` verdict. The worktree skill's `--no-rebase` push flag cannot hold the head still here: that push carries none of the restack's force-with-lease authorization, and git refuses the rewritten branch as a non-fast-forward push.

   **Restack proof.** Before either caller resumes, bind `[WORKTREE_PATH]` to `[WT_PATH]`, `[STATE_KEY]` to `[ISSUE]` and `[PREPARED_HEAD]` to the pushed head, and keep step 2's `[BASE_BRANCH]`. The block reads the pushed head's recorded skip. Where one stands, it asks the runtime whether the item's proof rows prove the pushed head: a pass at its tree or proof of the prior tree named by the skip. A range pass over the new base counts where the project declares a range command and no CI context. For the prior tree, a range pass counts only if it chains to a whole-tree pass. A reused tree alone supplies no passing validation. The block starts no validation and prints the reader's reply:

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
     PROOF_STATUS=0
     RESTACK_PROOF="$(.agents/skills/orch/scripts/orch-runtime read-proof --item [STATE_KEY] --need restack --tree "$PREPARED_TREE" --head [PREPARED_HEAD] --base "$PREPARED_BASE")" || PROOF_STATUS=$?
     printf '%s\n' "$RESTACK_PROOF"
     [[ "$PROOF_STATUS" -eq 0 ]] || exit "$PROOF_STATUS"
     [[ "$(jq -r '.result.proof' <<<"$RESTACK_PROOF")" != missing ]] || exit 1
   fi
   ```

   Where the item's dev round closed `pass-excused`, add `--exception-file [WORKTREE_PATH]/tmp/round-exception-[STATE_KEY].json` to the `read-proof` line: [dev-start.md § The exception file](dev-start.md#the-exception-file).

   When the block prints `missing` with `lacks.mode` `range`, keep the PR unarmed and validate the pushed head. Use the commit the proof read passed as `--base` for `[PREPARED_BASE]`. `--reproduce` runs the declared range command fresh.

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/orch-runtime validate entry --worktree [WT_PATH] --validate-mode range --base [PREPARED_BASE] --reproduce
   ```

   Follow step 2's wait and record reads for this run. A result other than `validate=pass` or a record for a head other than `[PREPARED_HEAD]` hands back with the run's verdict, head and log path. Bind `[RUN_DIR]` to the fresh run and import it with the `record-restack-validation` request above. If the reply's `stage` names that run folder, repeat `read-proof` with the same head, tree, base and any exception file. Resume only on `complete`. An import refusal, an unrecorded stage or a failed proof recheck hands back with its reply and keeps the PR unarmed.

   Any other nonzero exit hands back with the printed reply and keeps the PR unarmed, on submit-pr's steps 1-3 route too, before its create or update can arm the queue. Keep the reader's reply, its `proof` word and the rows it names, with the merge decision. A `missing` reply names in `lacks` the tree and the narrowest mode the project declares. A `pending` reply stays pending until the exact-head CI wait or the queue proves it.

4. **Return to the merge.** The head changed. Re-confirm the gate mode, then return to merge-pr.md § 5 step 1, which reads the new exact head, repeats its proof read, waits for CI and takes the merge route again.

## Unarm at a stop

A PR [submit-pr.md](submit-pr.md) § 2 step 5 armed at creation stays armed until something unarms it. A run that stops leaves it to merge with no `queue-watch` guard and none of [merge-pr.md § 5](merge-pr.md#5-execute-the-merge) steps 2-6. So every run that ends without a merged PR takes this section first: submit-pr.md § 2 step 5 on a refused re-arm, a `MERGE_READY = false` stop at submit-pr.md § 6.1, and every merge-pr.md hand-back. The caller supplies `[STATE_KEY]` and `[STOP_DIR]`, the folder its own stop route renders into.

Run step 1 above on the PR. It reads the live arm and queue membership and unarms in its order; a PR it finds neither armed nor queued needs nothing. A hand-back means its last read still found the PR armed or queued: run step 1 once more. A second hand-back replaces the caller's stop with one saying the PR is still armed, and the run ends there. `record` writes it over any earlier stop, and every later `record-if-empty` keeps it:

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
