# Base Publication Workflow

Publish one item's commit to its base branch, with no pull request, under `ORCH_DELIVERY=push-base`. Under that setting `orch-runtime pr order` answers `review-first`, so no early pull request exists.

**Caller context**: `worktree` as `[WORKTREE_PATH]`; `lifecycle`, `"managed"` or `"self"`; `issue_id` as `[ISSUE_ID]`, the workflow-state key. Resolve `TRACKER` from `[ISSUE_ID]` per [SKILL.md § Tracker Resolution](../SKILL.md#tracker-resolution).

---

## 1. Open Post-Merge Boxes

**Skip if** `TRACKER=none` ([SKILL.md § Tracker Resolution](../SKILL.md#tracker-resolution)): a directed change has no item to read.

1. Before any other step, read the root item live.
   - For a single bundle, also read each non-canceled child the commit implements.
   - For Linear, run `.agents/skills/linear/scripts/linear.sh issues get [ID]`.
   - For GitHub, run `gh issue view [N] --repo [OWNER/REPO] --json body`.
2. Save each body or description under `tmp/`. Classify it with `linear.sh done-when parse --description-file [FILE]`, and read its answer as [SKILL.md § Tracker Resolution](../SKILL.md#tracker-resolution) does.
3. If a read or a classification fails, stop publication. An absent linear package is not a failure: [SKILL.md § Tracker Resolution](../SKILL.md#tracker-resolution) states its outcome.

An item whose answer holds an open post-merge box, or any `errors`, takes the PR route:

1. Write `[WORKTREE_PATH]/tmp/delivery-post-merge-[ISSUE_ID].md` with one `delivery-post-merge: issue=[ID] route=pr` line per such item, and print it.
2. Send it: `.agents/skills/mailbox/scripts/lane-mail notice --item [ISSUE_ID] --file "[WORKTREE_PATH]/tmp/delivery-post-merge-[ISSUE_ID].md"`.
3. Stop. The stop prepares, pushes and completes nothing. The overseer relaunches the item with `ORCH_DELIVERY=pr`.

## 2. Review Check

Apply gate 1 of [publication.md § Merge gates](../references/publication.md#merge-gates) before preparation.

- Bind `[LIFECYCLE]` to `managed` or `self`.
- For a managed caller, bind `[REVIEW_VERDICT]` to the verdict the internal review returned.
- A standalone caller needs a non-empty `json_paths` record. The advisory local review of [submit-pr.md § 1.2](submit-pr.md#12-local-pre-pr-review) does not count.
- A micro item keeps its internal-review exception.

```bash
if ! BASE_REVIEW_STATE="$(.agents/skills/orch/scripts/orch-runtime state get --item [ISSUE_ID])"; then
  exit 1
fi
BASE_REVIEW_STATE="$(jq -c '.result.value | {tier: (.tier // "standard"), json_paths: (.json_paths // [])}' <<<"$BASE_REVIEW_STATE")"
if ! jq -e --arg lifecycle "[LIFECYCLE]" --arg verdict "[REVIEW_VERDICT]" '.tier == "micro" or (if $lifecycle == "managed" then $verdict == "pass" else (.json_paths | length) > 0 end)' <<<"$BASE_REVIEW_STATE" >/dev/null; then
  printf 'delivery-review: issue=%s state=unaccepted\n' '[ISSUE_ID]' >&2
  exit 1
fi
```

A refused review check publishes nothing. On a refusal:

1. Run [review-pr.md § 1-9](review-pr.md).
2. Repeat this check with its result.

Keep the tier's local validation.

## 3. Prepare

1. Bind `git -C [WORKTREE_PATH] rev-parse --verify HEAD` as `[BOUND_HEAD]`.
2. Write `[WORKTREE_PATH]/tmp/base-prepare-[ISSUE_ID].json` with the harness file tool as `{"op": "record-push", "mode": "prepare", "worktree": "[WORKTREE_PATH]"}`, then run it:

   ```bash
   .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request [WORKTREE_PATH]/tmp/base-prepare-[ISSUE_ID].json
   ```

   The request runs the worktree skill's preparation, its normal commit hooks and SHA reconciliation. It returns before validation and transport.

3. Bind `[BASE]`, `[PREPARED_BASE]` and `[PREPARED_HEAD]` from the reply's `prepared` receipt: its `base`, `before` and `commit`.
4. Apply **Rules reload after a rebase** ([SKILL.md § The Cycle](../SKILL.md#the-cycle)) at once, against `[BOUND_HEAD]`.
5. If the new rules require edits or review, complete that work and restart base publication from its entry, § 1.
6. Keep the receipt's values across this pause.

## 4. Publish

Write `[WORKTREE_PATH]/tmp/base-publish-[ISSUE_ID].json` with the harness file tool as `{"op": "record-push", "mode": "publish", "worktree": "[WORKTREE_PATH]", "base": "[PREPARED_BASE]", "head": "[PREPARED_HEAD]"}`, then run it:

```bash
.agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request [WORKTREE_PATH]/tmp/base-publish-[ISSUE_ID].json
```

The request validates the prepared head locally over the range from the prepared base. It then publishes that head through the worktree skill's pinned base transport, without rebasing.

- It refuses a head that moved from `[PREPARED_HEAD]`, before validation and again after it.
- A micro item takes the tier check first, which refuses any range that is not micro.
- Where the consumer's committed policy runs the `git-hooks` stage, the armed commit chain stands in for a micro item's range validation. Otherwise the range validation runs too.

Route the reply:

- On exit 0, read the reply's `delivery` receipt. Its `commit` is `[PUSHED_SHA]` and its `at` is `[PUSHED_AT]`.
- A refusal exits 1 with its key. A failed push exits with its status.
- A `worktree-push-base-conflict`, `worktree-push-base-rejected` or `worktree-push-rebase-failed` refusal in the reply's `push` output returns to [merge-pr-restack.md](merge-pr-restack.md). After its guarded restack and rules reload, that route returns to base publication from its entry.
- A red validation publishes nothing. A failed push sends no completion notice.

## 5. Verify The Published Head

Verify the published head where it stands. The verification is pinned to `[PUSHED_SHA]`, never to the branch's later head or a pull request. `[OWNER/REPO]` is what `gh repo view --json nameWithOwner --jq .nameWithOwner` answers from `[WORKTREE_PATH]`, whatever the item's tracker.

```bash
jq -cn --arg repo "[OWNER/REPO]" --arg base "[BASE]" --arg head "[PUSHED_SHA]" \
  '{op: "verify-head", repo: $repo, base: $base, head: $head, required_only: true}' \
  > "[WORKTREE_PATH]/tmp/verify-request-[ISSUE_ID].json"
.agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request "[WORKTREE_PATH]/tmp/verify-request-[ISSUE_ID].json"
```

| Reply | Action |
|--------|--------|
| `ok` true, `result.status` `complete` | Bind `[VERDICT]` to `result.verdict` |
| `ok` true, `result.status` `pending` | Repeat the call, as below |
| `ok` true, `result.status` `unreadable` | Run the call once more, as below |
| `ok` false | Report the refusal, as below |

- On `complete`, the op records a `fail` on a published head as read. Name it in the completion notice. Its fix is a new item.
- A `pending` reply is not final, and the op runs no wait of its own. Repeat the same call every 180 seconds until `CI_WAIT_MAX_SECS` seconds have passed since the first call (`.agents/skills/orch/scripts/orch-env CI_WAIT_MAX_SECS 600`).
- A `pending` reply at that point is unconfirmed: record nothing, and write `verification: head=[PUSHED_SHA] unconfirmed` in the completion notice.
- If `unreadable` repeats, record nothing, and write `verification: head=[PUSHED_SHA] unconfirmed` in the completion notice. Never record a verdict that did not arrive.
- On `ok` false, report the refusal's key with the pushed SHA in the completion notice. Do not repeat transport.

The op records a `complete` verdict in the same call ([workflow-state.md](../schemas/workflow-state.md) `verification`). Make no separate `record-verification` call.

## 6. Complete The Tracker Item

### 6.1 Linear

**Skip if** the tracker is not Linear.

Read the common checkout before you enter the reused step, a standalone caller included:

```bash
.agents/skills/orch/scripts/git-context common-root "[WORKTREE_PATH]"
```

- Stop on a nonzero exit.
- Bind the printed path as `[MAIN_REPO_ROOT]`.
- Substitute the value into each later command: a shell variable does not survive a separate tool call.

Run [merge-pr.md § 5 step 2](merge-pr.md#5-execute-the-merge) alone, with these bindings:

- `[ISSUE]` is this session's root `[ISSUE_ID]`, and `[MERGED_AT]` is the receipt's `[PUSHED_AT]`.
- Its merge summary runs [post-summary.md § 1](post-summary.md#1-post-the-summary) with no `pr_number`. The summary goes to the Linear item alone.
- Skip both of its `gh pr view` reads, the timestamp and the body: this delivery has no pull request.
- Write `[EVIDENCE_FILE]` and select `[MET_BOXES]` as that step states for a direct delivery.
- Use its `issues complete --post-merge-at` command.
- For the in-PR bundle, repeat the completion for each non-canceled child the pushed commit implements.
- Follow that step's container close.

### 6.2 GitHub

**Skip if** the tracker is not GitHub.

Use this session's resolved tracker and repository. Bind `[ISSUE_NUMBER]` to the root GitHub item's number from Tracker Resolution, then run:

```bash
gh issue close [ISSUE_NUMBER] --repo "[OWNER/REPO]" --reason completed
```

- Repeat that command with each qualified started bundle child's resolved number and repository: the children a PR body's `Closes` lines would include.
- Item commits need no closing trailer.
- A GitHub-tracked direct delivery posts no summary.
- Report a tracker failure with the pushed SHA, and do not repeat transport.

## 7. Notify And Return

Write `[WORKTREE_PATH]/tmp/delivery-[ISSUE_ID].md` with three parts:

1. `Pushed [PUSHED_SHA] to [BASE].`
2. The verification line `verification: head=[PUSHED_SHA] verdict=[VERDICT]`, or its unconfirmed form.
3. The tracker completion result.

Send it through the lane mailbox:

```bash
.agents/skills/mailbox/scripts/lane-mail notice --item [ISSUE_ID] --file "[WORKTREE_PATH]/tmp/delivery-[ISSUE_ID].md"
```

Return the receipt to the caller.

- A managed caller retires its agents through [start-worktree.md § 5.4](start-worktree.md#54-retire-agents), then ends.
- A standalone caller ends here.
