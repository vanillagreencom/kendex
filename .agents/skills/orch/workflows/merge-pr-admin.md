# Admin-Credential Merge Offer

[merge-pr.md](merge-pr.md) § 4.2 enters here. The lane offers a gate-met pull request to the overseer, which holds the owner credential this host does not, and waits for its answer.

**Skip if** `[ALREADY_MERGED]` is true, `merge_mode: admin`, a `merge-pr.md` § 3.2 `Force merge` was answered, or the route is off:

```bash
.agents/skills/orch/scripts/orch-env ORCH_ADMIN_MERGE_GH_CONFIG_DIR ""
```

An empty value is the route off, and `merge-pr.md` § 5 runs unchanged. A non-empty value names the control host's gh config directory holding the owner credential, which no lane ever holds. `merge-pr.md` § 3 established every gate on this pull request, so the merge is one overseer command instead of a second CI pass behind the queue. The lane offers the merge and waits; it never runs the merge verb and never reaches for the credential.

Read the head the offer names, as `[PREPARED_HEAD]`:

```bash
env -u GH_REPO -u GITHUB_REPOSITORY gh pr view [PR_NUMBER] --json headRefOid --jq .headRefOid
```

Write `[MAIN_REPO_ROOT]/tmp/merge-ready-[STATE_KEY].md` with the harness file-write tool. Its first line is exactly `merge-ready [PR_NUMBER] [PREPARED_HEAD]` and the rest is the `merge-pr.md` § 3 gate results. Ask with that file, then block on the answer through the ask gate [skill-rules.md § Coordination](../references/skill-rules.md#coordination) owns:

```bash
.agents/skills/orch/scripts/lane-mail ask --item [STATE_KEY] --file [MAIN_REPO_ROOT]/tmp/merge-ready-[STATE_KEY].md --options MERGED,QUEUE
```

The answer's first word routes it. The rest of the line is the `admin-merge` record the overseer's verb printed, which names the pull request, the head and each precondition's verdict.

- `MERGED` — the overseer merged this exact head. Set `[ALREADY_MERGED]=true`, put that record line under `## Merge decision` with `merge-pr.md` § 5 step 1's **Recording it** block, then enter `merge-pr.md` § 5 step 1, which skips the mutation and the wait and continues at step 2.
- `QUEUE` — nothing was merged, and the record names the condition that refused. Run `merge-pr.md` § 5 unchanged, from step 1.

Exit 124 from the wait, and any other first word, is `QUEUE`. A missing or unrecognized answer merges nothing.
