# Copilot on the current head

Read when a workflow waits on Copilot's work on a pull request's current head, or routes that head once its Copilot threads are answered.

- [review-pr-comments.md](../workflows/review-pr-comments.md) runs § Current-head Copilot wait in § 1 and § 6.3, and § Copilot head route in § 7.2.
- [submit-pr.md](../workflows/submit-pr.md) § 2 step 1 runs § Copilot head route on a published head.
- submit-pr.md § 6.1 gate 3 and [micro.md](../workflows/micro.md) send a finding that only a review body carries through § Body findings.
- The overseer handles the notices this route sends by [copilot-head-notices.md](copilot-head-notices.md).

## Current-head Copilot wait

The wait holds the calling read while Copilot's work on the head runs. It requests and records nothing, under either gate mode.

- Run it through [Waiter launch](waiter-launch.md).
- Skip it while the pull request is a draft. This command reads whether it is one:

  ```bash
  env -u GH_REPO -u GITHUB_REPOSITORY gh pr view [PR_NUMBER] --json isDraft --jq .isDraft
  ```

- `[OWNER/REPO]` is what `gh repo view --json nameWithOwner --jq .nameWithOwner` answers in `[WORKTREE_PATH]`.

```bash
env -u GH_REPO -u GITHUB_REPOSITORY .agents/skills/orch/scripts/orch-runtime copilot-wait --repo [OWNER/REPO] --pr [PR_NUMBER]
```

The bound is `ORCH_COPILOT_HOLD_SECS`, counted from the wait's own start.

Every caller routes the reply's `result` by this table. An expiry is a `state` in a reply that exits 0, so route the `state`, never the exit.

| Reply | Report | Then the calling read |
|---|---|---|
| `status` `complete`, `state` `none` | nothing | continues |
| `state` `settled` | nothing | continues |
| `state` `expired` | `run`, `started_at` and `waited` | continues under the existing gate |
| `status` `unreadable` | its `reason` and `detail` | stops |
| A refusal: a nonzero exit with a keyed `orch-runtime:` line | the refusal | stops |

- `state` `none` means no Copilot work on the head.
- After `settled`, the calling read reads the review that `review` names, where it names one, with the threads and bodies.
- The expiry grants no approval.
- A read stopped on `unreadable` takes the **GitHub read failures** rule of review-pr-comments.md. A failed read is never `none`.

No bot other than Copilot holds the read.

- A Copilot thread posted after the read holds the merge as [gates.md § Gate-mode routing](gates.md#gate-mode-routing) states for each gate mode.
- Bot prose is never a gate: emoji reactions, sticky comments and checklist text carry no gating weight.

## Copilot head route

**Skip if** workflow state `pr_order` reads `open-first-returned`, `push-first` or `push-first-returned`: send no notice and no request.

- For `push-first-returned`, first complete [submit-pr.md § 2](../workflows/submit-pr.md#2-push-and-submit) step 4's **Push-first ready head** block, a head already ready included. That block changes the order to `push-first-pushed` before this route's call.
- The other skipped orders still hold the lane's `Review:` line pending, and take submit-pr's publication route.

1. Run § Current-head Copilot wait and route its reply by that section's table. Keep the reply as `[COPILOT_WAIT]`.
2. Bind `[REVIEW_BASE_CHECKOUT]` per [Gate-mode routing](gates.md#gate-mode-routing).
   - Run [the review call](gates.md#the-review-call) once, from `[WORKTREE_PATH]`, with `[MARK_READY]` `false`. Keep its reply as `[REVIEW_READ]`.
   - Where the call's `head` differs from `[COPILOT_WAIT]`'s, run the wait again, then the call.
3. Route the reply:
   - A refusal ends this route. Report its keyed line.
   - A reply whose `status` is `unreadable` ends it too, with or without a `mode`. Report its `reason` and `detail`.
   - A `pending` reply whose `reason` opens `head-moved` restarts this route from its Copilot wait.
4. Under either gate mode, bind the reply's `head` as `[HEAD_SHA]` before any approval-only exit.
5. Read every review of the pull request, oldest first, one id, login, `commit_id`, `state` and body per line:

   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY gh api --paginate 'repos/{owner}/{repo}/pulls/[PR_NUMBER]/reviews' --jq '.[] | [.id, .user.login, .commit_id, .state, .body] | @tsv'
   ```

### Body findings

Copilot writes a finding on code the diff left unchanged only in its review body, under `Previously missed` or `Suppressed comments`. No thread carries it, and an `APPROVED` review can carry one too.

The body check is the one reader of those bodies. Run it at two points:

- after binding the head and reading the reviews, before any approval-only exit or route selection;
- again before a `copilot-approved-on-rerequest` or `copilot-declined-unchanged` notice, or the `timeout` row's `copilot-fallback` notice.

The lane answers a body finding before it waits on CI, not at the merge gate.

The body check is this command:

```bash
env -u GH_REPO -u GITHUB_REPOSITORY .agents/skills/github/scripts/github.sh -C "[WORKTREE_PATH]" check-review-replies [PR_NUMBER]
```

- A `head=` other than `[HEAD_SHA]` restarts this route from its Copilot wait, review call and reviews read.
- Exit `1` with `suppressed-entry` lines starts a triage pass. Save `[HEAD_SHA]` as `[BODY_REVIEW_HEAD]` in the new pass's context, then loop to [review-pr-comments.md](../workflows/review-pr-comments.md) § 2.
  - Each entry is an item: `source_type: "review-body"`, `source_id` the entry's token, and the finding's text from the review at `[BODY_REVIEW_HEAD]` in the reviews read.
  - Carry that head with each entry's source identity through analysis, reporting and publication. A later head read or fix push never replaces it.
  - The pass runs that workflow's §§ 5-6: Recurrence before the cap, the fix set, verification and the cause records included. That workflow's § 6.3 posts the body replies and counts the pass once.
  - After that workflow's § 6.3, restart this route from its Copilot wait, review call, reviews read and route selection, the body check included. A pushed head's body findings take their own pass, with that head as their source.
  - Keep the handled body items with their source-reviewed heads for the skip decision and the notices.
  - Complete that workflow's § 8 before returning to the caller with the current head and whether the pass pushed.
  - Discard every route selected before the pass.
- Exit `1` with any other rule's line: rewrite the replies by gate 3 of [publication.md § Merge gates](publication.md#merge-gates).
- Exit `2` reached no verdict. Report its first stderr line and send nothing.
- Until the check exits `0`, this route sends no notice, and no step ends on an approved head.
- Under the thread lines of a `copilot-declined-unchanged` or `copilot-fallback` notice:
  - add one line per body finding, with its `path:line` and the URL of the comment that answered it;
  - add one line naming the id of each Copilot review at `[HEAD_SHA]` from the reviews read.

### Routes

1. `off` ends this route once the body check exits `0`, per [Gate-mode routing](gates.md#gate-mode-routing).
2. Under `approval`, the route ends once the body check exits `0`, where neither a thread nor a review-body item this triage handled is Copilot's.
3. A reviews line whose `commit_id` is `[HEAD_SHA]` and whose `state` is `APPROVED` ends this route after the body check's exit `0`: the head is approved.
4. Otherwise every Copilot thread is answered and resolved by now. The route turns on whether the head moved since the last head Copilot read, the `commit_id` of the last `copilot-pull-request-reviewer[bot]` line:
   - **Head unmoved.** Send the notice below with the first line `copilot-declined-unchanged PR #[PR_NUMBER] head [HEAD_SHA]`.
     - Under it, add one line per thread that `github.sh pr-threads [PR_NUMBER]` lists with `author` `copilot-pull-request-reviewer`. Each line gives the thread's `id`, its location and the reply that answered it, a decline's reason included.
     - Request no Copilot re-review. The overseer approves the head under [copilot-head-notices.md](copilot-head-notices.md).
   - **Head moved**, by a push for any reviewer's thread or body finding. Route `[REVIEW_READ]`'s `request` by [Copilot requests](gates.md#copilot-requests).
     - `requested` or `existing` takes the wait below.
     - `fallback` starts no wait, and takes that section's fallback route.
     - This route sends none of the notices the reply's `notices` names.

### The wait on a moved head

Wait on the head through [the review wait](gates.md#the-review-call). Run it so that a silent head ends `timeout`, never `proceeded`:

```bash
env PR_REVIEW_ON_TIMEOUT=block .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request "[WORKTREE_PATH]/tmp/verify-review-request-[ISSUE_ID].json"
```

On a `complete` reply, compare its `head` with `[HEAD_SHA]`.

- A different head restarts this route from its Copilot wait.
- Otherwise read the reviews again. A `copilot-pull-request-reviewer[bot]` line whose `commit_id` is `[HEAD_SHA]` is the re-review.

| Verdict | Copilot's review at `[HEAD_SHA]` | Route |
|---------|----------------------------------|-------|
| `comments` | any | **Open threads** |
| `approved` | `APPROVED` | **Re-request approved** |
| `approved` | none, or not `APPROVED` | **Other approver** |
| `copilot-error` | error answer | **Copilot error** |
| `timeout` | present, not `APPROVED` | **Fallback** |
| `timeout` | none | **Silent head** |
| any other | any | **Caller's wait** |

- **Open threads.** Update the baseline, and loop to review-pr-comments.md § 1 for each open thread this triage has not answered, as its § 6.3 does. This route then routes the head again, with one exception:
  - The call answers `comments` while any thread stands open. Where every open thread is one review-pr-comments.md § 7.1 keeps open for a human, every repeat answers `comments` until the human answers.
  - On such a `comments`, end this route and leave the head to the caller's own review wait.
- **Re-request approved.** Run the body check. On its exit `0`, send the notice `copilot-approved-on-rerequest PR #[PR_NUMBER] head [HEAD_SHA]`.
- **Other approver.** This route sends no notice. Another reviewer approved the head, and no hold of [Copilot requests](gates.md#copilot-requests) stands.
- **Copilot error.** Route as [Copilot requests](gates.md#copilot-requests) says. The caller keeps the approval gate unmet and waits for the overseer's approval.
- **Fallback.** Copilot read the head again and left no open thread. Send the notice `copilot-fallback PR #[PR_NUMBER] head [HEAD_SHA]`. It asks for the overseer's fallback approval.
- **Silent head.** This route sends no notice. The overseer's `awaiting-stale` rule decides the head.
- **Caller's wait.** This route sends no notice. The caller's own review wait routes the verdict.

### Notice

In a lane, write the notice with the harness file tool to `[WORKTREE_PATH]/tmp/copilot-head-[ISSUE_ID].md`, then send it:

```bash
.agents/skills/mailbox/scripts/lane-mail notice --item [ISSUE_ID] --file [WORKTREE_PATH]/tmp/copilot-head-[ISSUE_ID].md
```

Outside a lane no overseer reads a notice, and the caller's own review wait decides the head.
