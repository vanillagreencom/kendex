# Admin-Credential Merge Offer

[merge-pr.md](merge-pr.md) § 4.2 enters here. The lane offers a gate-met pull request to the overseer, which holds the owner credential this host does not, and waits for its answer. The offer preempts `ORCH_MERGE_BYPASS=fast-path`: the route exists because a fast-path attempt enqueues a gate-met PR the bot cannot merge, and the owner credential merges it at once instead. [README.md](../README.md) § Settings states that precedence.

**Skip if** any of these holds; then `merge-pr.md` § 5 runs unchanged from step 1:

- `[ALREADY_MERGED]` is true, `merge_mode: admin`, or a `merge-pr.md` § 3.2 `Force merge` was answered.
- `[MICRO_REVIEW_STATE]` is set. A [micro.md](micro.md) entry reaches § 4 without running § 3, so the premise below does not hold for it.
- The route is off:

  ```bash
  .agents/skills/orch/scripts/orch-env ORCH_ADMIN_MERGE_GH_CONFIG_DIR ""
  ```

  An empty value is the route off. A non-empty value names the control host's gh config directory holding the owner credential, which no lane ever holds.

- This session is not a launched lane, so no overseer reads its mailbox to answer the offer:

  ```bash
  test -f "$(git rev-parse --path-format=absolute --git-common-dir)/lane-mail/$(printf '%s' [STATE_KEY] | tr 'A-Z' 'a-z')"
  ```

  A non-zero exit is a primary `merge-pr` run, or a lane whose launch left no marker: skip the offer.

For a standard entry, `merge-pr.md` § 3 established every gate on this pull request, so the merge is one overseer command instead of a second CI pass behind the queue. The lane offers the merge and waits; it never runs the merge verb and never reaches for the credential.

Read the head the offer names, as `[PREPARED_HEAD]`:

```bash
env -u GH_REPO -u GITHUB_REPOSITORY gh pr view [PR_NUMBER] --json headRefOid --jq .headRefOid
```

Write `[MAIN_REPO_ROOT]/tmp/merge-ready-[STATE_KEY].md` with the harness file-write tool. Its first line is exactly `merge-ready [PR_NUMBER] [PREPARED_HEAD]` and the rest is the `merge-pr.md` § 3 gate results. Ask with that file through the ask gate [skill-rules.md § Coordination](../references/skill-rules.md#coordination) owns, then block on the printed `[MSGID]`:

```bash
.agents/skills/orch/scripts/lane-mail ask --item [STATE_KEY] --file [MAIN_REPO_ROOT]/tmp/merge-ready-[STATE_KEY].md --options MERGED,QUEUE
```

Run the wait under [waiter-launch.md](../references/waiter-launch.md), the way merge-pr.md's other waits run. `lane-mail wait` defaults to no timeout, so pass an explicit budget; exit 124 at the budget is `QUEUE`:

```bash
.agents/skills/orch/scripts/lane-mail wait --item [STATE_KEY] --id [MSGID] --timeout 1800
```

The answer's first word routes it. The rest of the line is the `admin-merge` record the overseer's verb printed, which names the pull request, the head and each precondition's verdict.

- `MERGED` — the record's first field is `merged` (the overseer merged this exact head, `head-match=ok`) or `already-merged` (the PR was already merged; the record's `head-match` field says whether this head was the one, and is `-` where nothing compared it). Set `[ALREADY_MERGED]=true`, put that record line under `## Merge decision` with `merge-pr.md` § 5 step 1's **Recording it** block, then enter `merge-pr.md` § 5 step 1, which skips the mutation and the wait and continues at step 2.
- `QUEUE` — nothing was merged, and the record names the condition that refused. Set `[ADMIN_OFFER_QUEUE]=true`, append that record line under `## Merge decision` with `merge-pr.md` § 5 step 1's **Recording it** block, then run `merge-pr.md` § 5 from step 1. `[ADMIN_OFFER_QUEUE]` forces § 5's Queue-first branch, so the fast path never merges past the restriction the admin route refused (a disallowed class, an unmet review, a stale base).

Exit 124 from the wait, and any other first word, is `QUEUE`: set `[ADMIN_OFFER_QUEUE]=true` and take the same Queue-first path. A missing or unrecognized answer merges nothing.
