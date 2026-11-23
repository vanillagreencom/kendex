# Merge-pr restack cycle

Run this cycle when the base, not CI, blocks a pull request. Two verdicts route here: a `conflicting` `queue-watch` verdict in [merge-contracts.md § Queue wait](../references/merge-contracts.md#queue-wait), and the `worktree-push-base-conflict` refusal of [submit-pr.md](submit-pr.md) § 2 step 1.

- A submit-pr caller runs steps 1-3, then continues its own workflow.
- A merge-pr caller runs steps 1-4, and step 4 returns it to merge-pr.md.
- [§ Unarm at a stop](#unarm-at-a-stop) runs step 1 alone and pushes or restacks nothing.
- Never route a base conflict into ci-fix.

With `ORCH_DELIVERY=push-base`, no pull request exists:

- Skip step 1.
- Run step 2 through the guarded restack and its rules reload.
- Then, before step 2's validation, return to [submit-pr.md § 2.1](submit-pr.md#21-base-publication) from its entry. That route checks internal review, prepares, and returns control for another rules reload. It then validates the exact prepared head and transports it against its pinned base.
- Skip step 3 and the pull-request proof and merge steps.
- A failed restack, validation or transport hands back without a completion notice.

1. **Unarm the PR before any push.**

   - Read its node id and live arm with `env -u GH_REPO -u GITHUB_REPOSITORY gh pr view [PR_NUMBER] --json id,autoMergeRequest`.
   - Where `autoMergeRequest` is set, first disable auto-merge with `github.sh merge-queue-mutation disablePullRequestAutoMerge [PR_NODE_ID]`.
   - Then read the PR's `mergeQueueEntry` with the GraphQL query of [merge-contracts.md § Entry-ahead wait](../references/merge-contracts.md#entry-ahead-wait), given this PR's number and its repository's owner and name.
   - Where the entry is non-null, call `github.sh merge-queue-mutation dequeuePullRequest [PR_NODE_ID]`.
   - Then read `autoMergeRequest` and `mergeQueueEntry` again. Either one still set hands back without pushing.

2. **Restack the branch and validate the restacked head.** Resolve the managed worktree as `[WT_PATH]`:

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/worktree/scripts/worktree path [ISSUE]
   ```

   - No issue worktree hands back.
   - Before rebasing anything, ask whether a fix round is in flight. Write `[WT_PATH]/tmp/restack-live-round-[ISSUE].json` with the harness file tool as `{"op": "record-push", "mode": "check-live-round", "worktree": "[WT_PATH]"}`, then send it:

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/orch-runtime op --item [ISSUE] --request [WT_PATH]/tmp/restack-live-round-[ISSUE].json
   ```

   - The request pushes nothing.
   - Exit 0 alone permits the restack. Every other exit hands back; exit 3 names the round in flight as the reply's `live_round`.
   - Never restack with `worktree create [ISSUE] --reuse`: it rebases outside this check and has no live-round refusal.

   The restack takes the rules reload after a rebase of [SKILL.md § The Cycle](../SKILL.md#the-cycle). Start the guarded restack:

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/worktree/scripts/worktree create [ISSUE] --restack
   ```

   - On conflicts, resolve every listed file, stage it, and run `worktree restack continue [ISSUE]` until the restack completes.
   - Never force-push over an unresolved base.

   Then resolve validation for the restacked head, before step 3 pushes it. Bind the base branch the restack rebased onto as `[BASE_BRANCH]`. Then read the mode a range run in the worktree records:

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/resolve-base-branch [WT_PATH]
   ```

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/orch-runtime validate entry --resolve-mode --worktree [WT_PATH] --base origin/[BASE_BRANCH]
   ```

   - A non-zero exit from `resolve-base-branch`, `--resolve-mode` or the `--record` read below hands back with that command's stderr and pushes nothing.

   **`validate-mode=ci`.** A covered head records required CI as pending and starts no local range command. Step 4's exact-head CI wait proves the published head. Record the pending run through the validation entry:

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/orch-runtime validate entry --worktree [WT_PATH] --validate-mode ci --base origin/[BASE_BRANCH] --restack
   ```

   The restack's starts, this one and the range run below, carry no `--run-id`: the entry records the run itself, the route [dev SKILL.md § Long-Running Validation](../../dev/SKILL.md#long-running-validation) names for a delegation with no admission. Read the result through `--record` before step 3.

   **`validate-mode=full`, `range` or `docs`.** `full` means the project declares no `DEV_VALIDATE_RANGE_CMD`. All three first ask whether the restacked head can skip its range re-test:

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/orch-runtime validate entry --restack-check --worktree [WT_PATH] --base origin/[BASE_BRANCH]
   ```

   Exit 0 prints `restack=skip condition=[CONDITION] ... head=[HEAD] paths=[PATHS]` and starts no run. Record the skip on the item, then go to step 3. `[CONDITION]` is the line's `condition=` value, `[VALIDATED_HEAD]` its `validated-head=` value and `[PATHS]` its `paths=` value:

   ```bash
   jq -n --arg head [HEAD] --arg condition [CONDITION] --arg validated [VALIDATED_HEAD] --arg paths [PATHS] '{head: $head, condition: $condition, validated_head: $validated, paths: (if $paths == "none" then [] else ($paths | split(",")) end)}' > tmp/restack-skip-[ISSUE].json
   .agents/skills/orch/scripts/orch-runtime op --item [ISSUE] --request-json '{"op":"record-pr-progress","step":"restack-skip","file":"tmp/restack-skip-[ISSUE].json"}'
   ```

   - A lane also rewrites its status file's validation line to name the skip, its condition and its paths ([dev-start.md § Validation status](dev-start.md#validation-status)).
   - A skip proves tree equivalence and no more. A later run at that tree that did not pass voids the skip's proof, with every other proof of the tree.
   - Handle step 3's `missing` reply before either caller resumes.

   Under `full`, any other exit of the check goes to step 3 with no run. Under `range` or `docs`, any other exit, whatever it prints, runs the range command over the restacked branch on its base. Never pass `--validate-mode docs`: this range start runs a docs-only branch's docs command and records `validate-mode=docs`:

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/orch-runtime validate entry --worktree [WT_PATH] --validate-mode range --base origin/[BASE_BRANCH]
   ```

   - Bind `[RUN_DIR]` to the run's `run-dir=` line.
   - A start that exits 3 printed `state=running`: its wait budget passed while the run continues. Follow it with `orch-runtime validate entry --wait --run-dir [RUN_DIR]` until it prints `state=done`. Poll as [dev SKILL.md § Long-Running Validation](../../dev/SKILL.md#long-running-validation) sets out for the harness.
   - A start refused as `run-live` ran nothing. Take that refusal's route in [dev-implement.md § 5. Validate](../../dev/workflows/dev-implement.md#5-validate), then start the range run again.
   - Once the run ends, read its head and times:

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/orch-runtime validate entry --record --run-dir [RUN_DIR]
   ```

   Route the result:

   - A `validate-mode=ci` record with `verdict=pending` goes on to step 3, but it is no CI pass.
   - For a local run, only `validate=pass` goes on to step 3.
   - Every other result pushes nothing and hands back with the verdict and the run's log path: `FAILING` (a stall among them), `no-verdict`, or a record at `state=lost`. Like a fix round's red verdict, it ends the workflow with no second run. The PR stays unarmed from step 1, and the cycle never reaches step 4.

3. **Push through the guarded owner.** Write `[WT_PATH]/tmp/restack-push-[ISSUE].json` with the harness file tool as `{"op": "record-push", "mode": "branch", "worktree": "[WT_PATH]"}`, then send it:

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/orch-runtime op --item [ISSUE] --request [WT_PATH]/tmp/restack-push-[ISSUE].json
   ```

   - Never skip this step, and never replace it with another push: this request alone reconciles the SHAs the item recorded before the restack, and records the run as the item's restack `validate` stage.
   - Exit 0 is a confirmed push. Every non-zero exit hands back.

   A `ci` record needs no head comparison after the push. After a local run, `range` or `docs`, compare the pushed head with the `head=` value of that run's record. After a skip, compare it with the `head=` value of the skip line:

   ```bash
   git -C [WT_PATH] rev-parse HEAD
   ```

   A different head means the push rebased the branch again onto a moved base, and pushed a head no run validated:

   - Run step 2's mode read and skip check again on that head, and record a new skip for it.
   - Where range or docs mode does not skip, run its range command and record read.
   - The proof read below uses the resulting head.
   - Route a result that did not pass as step 2 does.
   - After a pass, bind `[RUN_DIR]` to this second run and record its stage through the same owner. Write `[WT_PATH]/tmp/restack-stage-[ISSUE].json` with the harness file tool as `{"op": "record-push", "mode": "record-restack-validation", "worktree": "[WT_PATH]", "run_dir": "[RUN_DIR]"}`, then send it:

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/orch-runtime op --item [ISSUE] --request [WT_PATH]/tmp/restack-stage-[ISSUE].json
   ```

   - This request publishes nothing. Its stage write is advisory: it exits 0 whether the reply's `stage` names the run folder or reads `unrecorded`.
   - A pass or a skip takes the proof read below with no second push.
   - The worktree skill's `--no-rebase` push flag cannot hold the head still here: git refuses the rewritten branch as a non-fast-forward push.

   **Restack proof.** Before either caller resumes, bind `[WORKTREE_PATH]` to `[WT_PATH]`, `[STATE_KEY]` to `[ISSUE]` and `[PREPARED_HEAD]` to the pushed head. Keep step 2's `[BASE_BRANCH]`.

   - The block reads the pushed head's recorded skip.
   - Where one stands, the block asks the runtime whether the item's proof rows prove the pushed head.
   - The block starts no validation and prints the reader's reply:

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

   When the block prints `missing` with `lacks.mode` `range`, keep the PR unarmed and validate the pushed head. Pass `[PREPARED_BASE]`, the commit the proof read took as `--base`, as `--base` here.

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/orch-runtime validate entry --worktree [WT_PATH] --validate-mode range --base [PREPARED_BASE] --reproduce
   ```

   - Follow step 2's wait and record reads for this run.
   - A result other than `validate=pass`, or a record for a head other than `[PREPARED_HEAD]`, hands back with the run's verdict, head and log path.
   - Bind `[RUN_DIR]` to the fresh run and import it with the `record-restack-validation` request above.
   - If the reply's `stage` names that run folder, repeat `read-proof` with the same head, tree, base and any exception file. Resume only on `complete`.
   - An import refusal, an unrecorded stage or a failed proof recheck hands back with its reply and keeps the PR unarmed.

   Then, for the block's result:

   - Any other nonzero exit hands back with the printed reply and keeps the PR unarmed. This holds on submit-pr's steps 1-3 route too, before its create or update can arm the queue.
   - Keep the reader's reply, its `proof` word and the rows it names with the merge decision.
   - A `pending` reply stays pending until the exact-head CI wait or the queue proves it.

4. **Return to the merge.** The head changed. Re-confirm the gate mode, then return to merge-pr.md § 5 step 1. That step reads the new exact head, repeats its proof read, waits for CI and takes the merge route again.

## Unarm at a stop

A PR that [submit-pr.md](submit-pr.md) § 2 step 5 armed at creation stays armed until something unarms it. Every run that ends without a merged PR takes this section first:

- submit-pr.md § 2 step 5, on a refused re-arm;
- a `MERGE_READY = false` stop at submit-pr.md § 6.1;
- every merge-pr.md hand-back.

The caller supplies `[STATE_KEY]` and `[STOP_DIR]`, the folder its own stop route renders into.

Run step 1 above on the PR. It reads the live arm and queue membership and unarms in its order.

- A PR it finds neither armed nor queued needs nothing.
- A hand-back means its last read still found the PR armed or queued: run step 1 once more.
- A second hand-back replaces the caller's stop with one saying the PR is still armed, and the run ends there:

```bash
.agents/skills/orch/scripts/orch-runtime state post-pr-stop record --item [STATE_KEY] --name disarm-unconfirmed --gate merge --remaining "PR #[PR_NUMBER] is still armed or queued: the lane could not disarm it, and GitHub can merge it with no lane watching" --comment-file [STOP_DIR]/post-pr-stop-[STATE_KEY].md
```

```bash
env -u GH_REPO -u GITHUB_REPOSITORY .agents/skills/github/scripts/github.sh post-comment [PR_NUMBER] --body-file [STOP_DIR]/post-pr-stop-[STATE_KEY].md
```

In a lane, also tell the overseer. Write a notice naming the PR and the stop to `[STOP_DIR]/disarm-unconfirmed-[STATE_KEY].md` with the harness file-write tool, then send it:

```bash
.agents/skills/mailbox/scripts/lane-mail notice --item [STATE_KEY] --file [STOP_DIR]/disarm-unconfirmed-[STATE_KEY].md
```
