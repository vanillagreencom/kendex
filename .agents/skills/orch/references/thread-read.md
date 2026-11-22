# Reading open review threads

Read when [merge-pr.md](../workflows/merge-pr.md) § 3.3 runs the thread read: before its gate wait and before every merge call. The read runs under every gate mode and on every change class.

## The read

Bind the pull request's head as `[READ_HEAD]` with the first command below, then read its open threads. No Copilot wait runs here ([gates.md § Copilot requests](gates.md#copilot-requests)).

```bash
env -u GH_REPO -u GITHUB_REPOSITORY gh pr view [PR_NUMBER] --json headRefOid --jq .headRefOid
```

```bash
env -u GH_REPO -u GITHUB_REPOSITORY [MAIN_REPO_ROOT]/.agents/skills/github/scripts/github.sh -C [MAIN_REPO_ROOT] pr-threads [PR_NUMBER] --unresolved
```

Route the answer:

- A non-zero exit from either, or output with no numeric `unresolved_count`, is no answer, never zero. Report it and record `review-threads-unreadable` through merge-pr.md § 1's stop routes.
- A count of zero returns to the merge-pr step that ran this read: § 3.2, § 5 step 1, the Recovery cycle's gate wait, or Late-findings triage step 2.
  - That step is the original caller, never a fresh entry to merge-pr's § 3.3.
  - A read run again from § After the triage keeps the same caller.
- A nonzero count takes `⤵ workflows/review-pr-comments.md [PR_NUMBER] § 1-8 → thread-read.md § After the triage` with managed context. Under `ORCH_DECISION_MODE=auto-recommended` the triage repeats within `REVIEW_MAX_EXTERNAL_ROUNDS`, then records `review-threads-open`.

## After the triage

`[READ_HEAD]` is the head this read bound before the triage; nothing here binds it again. Read the head again with the first command above and compare:

- Still `[READ_HEAD]`: the triage pushed nothing. Run this read again from its top, for the same caller.
- A new head: the triage pushed a fix. Return to merge-pr.md § 3 at its `pr-merge --check`, so § 3.1's CI wait and § 3.2's gates run on that head before any arm.
  - A `[MICRO_ENTRY]` run instead returns to [micro.md](../workflows/micro.md) § 4 on the new head, where a fix inside the admitted paths keeps the tier while the range stays within the `micro` ceiling, and the tier check escapes it otherwise.
  - A head another push moved escapes by micro.md § Escape condition 8.

## What reads an open thread

Four readers check open threads:

- This read: from merge-pr § 3.2 before the `not_approved` wait, and from merge-pr § 5 step 1 before every merge call.
  - Under the `off` gate mode, § 5 step 1 runs it once more after its review call.
  - The § 5 read covers the entries that skip § 3.2: a [micro.md](../workflows/micro.md) § 4 entry and every return from the merge cycles.
- `orch-runtime queue-watch`'s late-findings guard, on a thread posted after this read while the pull request is armed or queued. Its `dequeued` verdict takes merge-pr § 5 step 1's Late-findings triage, which runs this read.
- `ci-classify-refusal`, before a same-head retry. `ci-classify-refusal --help` states its thread and retry contract, and [merge-attempt.md § Exit routing](merge-attempt.md#exit-routing) routes its result.
- GitHub, only where the base branch's ruleset requires thread resolution: `pr-merge --help` § Approvals and review threads.

The lane answers every open thread, a review bot's included. Nothing resolves a thread for the lane.
