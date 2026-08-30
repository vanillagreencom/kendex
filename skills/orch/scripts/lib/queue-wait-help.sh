# shellcheck shell=bash
# queue-wait's CLI and verdict contract, kept separate from its poll state.
print_usage() {
  cat <<'USAGE'
Usage: queue-wait <PR#> [poll_interval] [max_wait] [--json] [--no-check-probe]
                  [--no-guard]

Wait for a merge-queue / auto-merge outcome on a PR. Every exit path emits a
final result on stdout — a "Merge queue: ..." line, or a JSON object with
--json — so callers can route merged vs ejected vs disarmed vs still-queued
deterministically (kendex#819). This is the merge-pr queue watch as one command (accepted
by the Codex approval=never classifier where a sleep-poll loop is rejected)
and the only place WAS_QUEUED lives: whether ANY earlier poll observed the PR
queued or armed. Separate tool calls carry no memory, so an orchestrator
re-entering per poll cannot tell "ejected from the queue" from "never entered
it"; this script can. It is NOT a CI waiter: ci-wait owns check state and
approval-wait owns the review gate.

  <PR#>          pull request number (required)
  poll_interval  seconds between polls (default 30)
  max_wait       total budget in seconds, an upper bound (default 2400 —
                 40 min, sized to measured merge-group suites up to
                 ~25 min); poll_interval must be <= max_wait
  --json         emit the machine-readable result object on stdout
  --no-check-probe  skip the failed-required-check ci-wait delegation
  --no-guard     skip the late-findings guard (no dequeue on unresolved
                 review threads while queued)
Each poll reads both signals the merge-pr routing table consumes:
`gh pr view <PR> --json state,mergedAt` plus the GraphQL isInMergeQueue /
mergeQueueEntry { state position headCommit { oid } } / autoMergeRequest
fields (gh pr view exposes no queue-membership field), and — when the
entry exposes its head commit — one paginated REST check-runs read on that
commit for the progress signal. `gh pr view --json mergeable` is never
polled: it stays UNKNOWN after a merge and would loop forever.

Verdicts (the merge-pr § 5 step 1 routing table):
  merged      state == "MERGED". The only exit-0 verdict.
  ejected     an earlier poll saw the PR IN the merge queue, and it is now
              out (isInMergeQueue false, mergeQueueEntry null) while still
              OPEN: the merge-group run failed and GitHub removed it.
  disarmed    the PR was armed (autoMergeRequest) but never entered the
              queue, and the arming is gone — or, while armed and not
              enqueued, a required check has failed (see the probe below).
  dequeued    the late-findings guard saw an unresolved review thread while
              the PR was queued or armed and pulled the arming (cause
              late_findings). A failed pull instead reports cause
              late_findings_dequeue_failed with the PR still queued.
  closed      the PR was closed without merging.
  queued      poll bound reached with the PR still queued/armed. Reported
              as status "timeout": the merge stays armed and fires on its
              own, so this is NOT a failure of the merge — and never a
              success either. Carries cause still_progressing or stalled.
              Never re-arm a still_progressing merge.
  not_queued  no poll ever observed the PR queued or armed, and the arming
              grace expired. The merge was never armed; nothing will fire.

Progress signal (VST-249): across polls the script tracks the entry tuple
(mergeQueueEntry.state, position, headCommit.oid) and the completed
check-run count on that head commit. progressing is true when the tuple or
the completed count changed within the last 3 polls, OR the last
successful check-run read still shows a not-completed run
(in_progress/queued/waiting/requested/pending) — a 15-minute shard
completes nothing for many polls and is still running. Stalled means
measurable, unchanged in the window, and nothing running. null means
progress was never observable: no head commit exposed, or every check-run
read failed — a failed read is unknown, never zero (absorbed, warned after
3 consecutive failures, never compared), so a read failure can neither
fabricate nor erase movement.

Ejection/disarm verdicts are confirmed across QUEUE_WAIT_CONFIRM_POLLS
consecutive polls (default 2) before they terminate the wait, so a single
eventually-consistent blip in the GraphQL view cannot trigger a spurious
recovery cycle. A candidate observed at least once still wins at the
deadline — a real ejection is never downgraded to "still queued".

Failed-required-check probe (--no-check-probe to disable): detection of
the failed-required-check disarm cause is delegated to
`ci-wait <PR> 15 30 --json` (verdict "fail") rather than reimplemented —
ci-wait owns superseded-run correlation and check-state semantics. The
probe runs ONLY on the armed-but-not-enqueued shape (a merge-queue repo
gets ejection detection from membership for free), at most once every
QUEUE_WAIT_PROBE_INTERVAL seconds so a queue poll never inherits a full CI
wait. ci-wait may re-run a transiently failed workflow once as part of its
own contract; --no-check-probe suppresses that side effect too.

Late-findings guard (--no-guard to disable): reviewers post findings
asynchronously, and the merge queue never re-checks thread resolution once
a PR is queued (kendex#1289) — a finding landing after enqueue merges
unless something dequeues. approval-wait gates unresolved threads to zero
before enqueue, so ANY unresolved review thread observed while the PR is
queued or armed is late by construction — pre-existing or new, no
baseline; a thread resolved while queued is fine. Each guard probe reads
the same reviewThreads surface approval-wait uses, rate-limited by
QUEUE_WAIT_PROBE_INTERVAL on its own clock, and one final probe runs
before a still-queued deadline return so the timeout can never skip the
last chance. On trigger the guard disarms auto-merge FIRST (an armed PR
re-enqueues itself when requirements go green, racing a bare dequeue) and
then dequeues via GraphQL dequeuePullRequest — whose input field is named
`id` but takes the PULL REQUEST node id, unlike enqueue's `pullRequestId`.
Each mutation response is verified: an `errors` key in the body, or a
missing mutation payload, is a failure even on HTTP success. Full success
exits 1 with verdict "dequeued", cause "late_findings" — the caller
triages the threads (resolving or replying to every one) before any
re-enqueue. Any failed half is loud, never swallowed: cause
"late_findings_dequeue_failed", exit 1, the failed mutation(s) named and
the PR stated still queued. Thread reads fail closed: a query failure, a
null or malformed reviewThreads, a non-boolean isResolved, a hasNextPage
with a missing or non-advancing cursor, or a walk needing more than 20
pages is "no evidence", never "no threads" — the guard keeps waiting,
retries at the next probe, and warns after 3 consecutive failures without
ever fabricating a dequeue or a quiet.

JSON output (always when --json):
  {
    "status": "complete" | "timeout" | "error",
    "pr_number": <int>,
    "verdict": "merged" | "ejected" | "disarmed" | "dequeued" | "closed"
               | "queued" | "not_queued" | "unknown",
    "elapsed_seconds": <int>,
    "polls": <int>,
    "pr_state": <string>,          # OPEN | MERGED | CLOSED | "" (never read)
    "merged_at": <string>,
    "in_merge_queue": <bool>,      # last poll
    "merge_queue_state": <string>, # mergeQueueEntry.state, "" when no entry
    "auto_merge_enabled": <bool>,  # last poll
    "was_queued": <bool>,          # ANY poll saw queued OR armed
    "was_in_merge_queue": <bool>,  # ANY poll saw actual queue membership
    "progressing": <bool|null>,    # see Progress signal above
    "cause": <string>,             # only when known: merge_group_failed |
                                   # check_failed | auto_merge_cleared |
                                   # never_armed | closed_without_merge |
                                   # late_findings |
                                   # late_findings_dequeue_failed |
                                   # still_progressing | stalled (queued)
    "unresolved_count": <int>,     # only once the guard has read threads
    "last_poll_age_seconds": <int>, # only once a poll has completed
    "transient_api_errors": <int>, # only when > 0
    "error": <string>              # only when status == "error"
  }

Auth: resolved through lib/gh-auth.sh, shared with approval-wait and
ci-wait (kendex#19) — env-first: already-resolved GH_TOKEN/GITHUB_TOKEN/
GH_BOT_TOKEN parent-process values win before local files are read, `op
read` runs only for the final selected op:// reference, each candidate
source is probed at most once, and a selected env token is validated with
`gh api user`. Full ladder: orch DEVELOPMENT.md.

Environment (orch-env ladder: parent env > .env.local > .kendex/settings.toml /
  kendex.settings.toml [env] > default):
  QUEUE_WAIT_ARM_GRACE      seconds to keep polling before reporting
                "not_queued" when no poll has yet seen the PR queued or
                armed (default 120). Enqueue registration lags the merge
                call; past the window the explicit never-armed diagnostic
                fires instead of burning the budget on a never-armed merge.
  QUEUE_WAIT_CONFIRM_POLLS  consecutive polls that must agree before an
                ejection/disarm terminates the wait (default 2).
  QUEUE_WAIT_PROBE_INTERVAL minimum seconds between delegated ci-wait
                probes and between late-findings guard probes, each on its
                own clock (default 120).

Exit codes:
  0  merged
  1  ejected, disarmed, dequeued, closed, still-queued at the deadline,
     never armed, or a non-auth error
  2  usage error: missing PR#, unknown flag, or non-integer argument
     (matches ci-wait)
  3  GitHub auth/CLI error (matches ci-wait and approval-wait)
USAGE
}
