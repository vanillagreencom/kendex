# Reading open review threads

The read [merge-pr.md](../workflows/merge-pr.md) § 3.3 runs before its gate wait and before every merge call. `pr-merge` reads no thread, so this read is the lane's own. It runs under every gate mode and on every change class.

Bind the pull request's head as `[READ_HEAD]`, then read its open threads:

```bash
env -u GH_REPO -u GITHUB_REPOSITORY gh pr view [PR_NUMBER] --json headRefOid --jq .headRefOid
```

```bash
env -u GH_REPO -u GITHUB_REPOSITORY [MAIN_REPO_ROOT]/.agents/skills/github/scripts/github.sh -C [MAIN_REPO_ROOT] pr-threads [PR_NUMBER] --unresolved
```

A non-zero exit from either, or output with no numeric `unresolved_count`, is no answer and never zero: report it and record `review-threads-unreadable`.

Zero returns to the merge-pr step that ran this read: § 3.2, § 5 step 1, the Recovery cycle's gate wait, or Late-findings triage step 2. That is the original caller, never a re-entry of merge-pr § 3.3, and a read run again from § After the triage keeps it.

A nonzero count takes `⤵ workflows/review-pr-comments.md [PR_NUMBER] § 1-8 → thread-read.md § After the triage` with managed context, which replies to and resolves every thread. `auto-recommended` keeps triaging within `REVIEW_MAX_EXTERNAL_ROUNDS`, then records `review-threads-open`.

## After the triage

`[READ_HEAD]` is the head this read bound before the triage, and nothing here rebinds it. Read the head again by the first command above and compare:

- Still `[READ_HEAD]`: the triage pushed nothing. Run this read again from its top, for the same caller.
- A new head: the triage pushed a fix. Return to merge-pr.md § 3 at its `pr-merge --check`, so § 3.1's CI wait and § 3.2's gates run on that head before any arm. A `[MICRO_ENTRY]` run escapes by [micro.md](../workflows/micro.md) § Escape condition 9 instead: its head moved.

## What reads an open thread

Three readers check open threads:

- This read, from merge-pr § 3.2 before the `not_approved` wait, and from merge-pr § 5 step 1 before every merge call. The § 5 read covers the entries that skip § 3.2: a [micro.md](../workflows/micro.md) § 4 entry and every return from the merge cycles.
- `queue-wait`'s late-findings guard, on a thread posted after this read while the PR is armed or queued. Its `dequeued` verdict takes merge-pr § 5 step 1's Late-findings triage, which runs this read.
- GitHub, only where the base branch's ruleset requires thread resolution: `pr-merge --help` § Approvals and review threads.

The lane answers every open thread, a review bot's included. Nothing resolves a thread for the lane.
