# Review gate and waiter reference

Cross-script routing behind the gate-mode summary and the `approval-wait` / `ci-wait` / `queue-wait` rows in [../SKILL.md](../SKILL.md). Each script's `--help` is its authoritative contract — arguments, modes, settings, JSON fields, exit codes; nothing here restates one.

## Gate-mode routing

Bind `[REVIEW_BASE_CHECKOUT]` to a checkout of the target pull request's consumer base, never the catalog checkout or the pull request's updated tree. If that checkout is unavailable, stop. Read its effective mode only through `approval-wait <PR#> --resolve-mode --base-checkout [REVIEW_BASE_CHECKOUT]`. The caller's trusted `approval-wait` owns the mode and runs from that consumer directory. It reads committed `REVIEW_GATE_MODE` through its trusted review-gate settings reader. It never executes the base checkout's installed resolver. `off` disables requests and waits even beside a native approval requirement. Otherwise GitHub's approval requirement decides: the owner reads the base and the pull request's `reviewDecision` in one `gh pr view` call, then every ruleset rule GitHub applies to that branch through `rules/branches`, organization rulesets included. That rules read does not show classic branch protection; the `reviewDecision` does, since GitHub sets it only where the base requires a review. A non-zero exit is no mode: report it and stop rather than pick one. It prints:

| `GATE_MODE` | Meaning | Route |
|-------------|---------|-------|
| `approval` | consumer policy is `enforce`, and the base's `pull_request` rules require at least one approval or the pull request's `reviewDecision` is non-empty | `approval-wait` |
| `off` | committed consumer policy is `off`, or the base's rulesets require no approval and the pull request's `reviewDecision` is empty | skip the wait; record the gate not-applicable |

Under `off`, open review threads still stop the merge: submit-pr's gate 3 applies, and so do the readers [thread-read.md § What reads an open thread](thread-read.md#what-reads-an-open-thread) lists. Required CI checks, commit guards, exact-head checks and conflict refusal are untouched in both modes, and the merge path still refuses a `CHANGES_REQUESTED` review at its readiness check. In `approval` mode an unresolved thread holds the wait at `comments` even beside an approval, because orch's own merge gates refuse an open thread: submit-pr's gate 3 and merge-pr's thread read ([thread-read.md](thread-read.md)). A base rule refuses one too where it requires thread resolution.

The reviewer-gate settings, `PR_REVIEW_ON_TIMEOUT`, `PR_REVIEW_WAIT_SECS` and `PR_COPILOT_REQUESTS`, live in `kendex.settings.toml` `[env]`; semantics and defaults are in `approval-wait --help`.

## Copilot requests

Every first or repeated Copilot request uses the mode owner:

```bash
env -u GH_REPO -u GITHUB_REPOSITORY .agents/skills/orch/scripts/approval-wait [PR_NUMBER] --request-review --base-checkout [REVIEW_BASE_CHECKOUT]
```

`off` ends the request path without a request or a wait. `approval` confirms that the request succeeded. A line whose first word is `fallback` means no request went out, and its `cause=` field says why: `cause=refresh-identity` for the exact lanes-app consumer refresh identity, `cause=off` when `PR_COPILOT_REQUESTS` is `off`, `cause=refused exit=N` when the request exited nonzero, whether GitHub refused it or the call failed. Start no wait for a Copilot review; the caller's own approval wait still runs and ends on the overseer's approval. Under `cause=refresh-identity`, apply [copilot-head-notices.md § Consumer refresh approval](copilot-head-notices.md#consumer-refresh-approval), including its second-opinion route for a non-render result. Send no Copilot request or ordinary fallback notice for this cause. Under `cause=off` send nothing: in a lane, that approval wait sends the `copilot-fallback` notice itself, once per head. Under `cause=refused`, in a lane, send the `copilot-fallback` notice for the current head at once, as [review-pr-comments.md](../workflows/review-pr-comments.md) § 7.2 sends it, with `cause=refused exit=N` at the end of its first line and the first `copilot-request-refused` line the owner wrote to stderr as its second line, so the overseer approves the head and knows why. A nonzero exit is no mode: report it and stop. `approval-wait --help` owns the action contract and the wait's notice.

A wait receives `--base-checkout [REVIEW_BASE_CHECKOUT]` for the error-review retry owned by `approval-wait --help`. On `copilot-error`, read `head_sha` and `copilot_fallback_cause` from its result. A `refresh-identity` cause takes [Consumer refresh approval](copilot-head-notices.md#consumer-refresh-approval). For other causes, in a lane, run the body check and send the `copilot-fallback` notice through [review-pr-comments.md § 7.2](../workflows/review-pr-comments.md#72-copilot-head-route). End its first line with `cause=[COPILOT_FALLBACK_CAUSE]`. Under `cause=refused exit=N`, include the request owner's first `copilot-request-refused` stderr line. Under `cause=error`, include the lane status path for the overseer to read. Then keep the approval wait running for the overseer's approval. The error-answer record keeps later waits from repeating `copilot-error` while that approval is pending. Every wait restart still uses its caller's existing head-budget route. Send no further Copilot request for that error answer. Outside a lane, report the unavailable Copilot review and keep the approval gate unmet.

## Which waiter answers which state

| Waiting on | Tool |
|------------|------|
| Reviewer verdict on one PR | `approval-wait` — statuses `approved`/`changes_requested`/`comments`/`timeout`/`proceeded`/`unreviewable`/`copilot-error`/`error` |
| CI on one PR | `ci-wait` — verdicts `pass`/`fail`/`pending`/`none` |
| Merge-queue / auto-merge outcome | `queue-wait` — the growing verdict set documented in its § Verdicts table |
| Many PRs, long horizon | `pr-watch.sh` — § Multi-PR watching |

Per-verdict routing lives in the workflows (`submit-pr.md` § 4, `merge-pr.md` § 5); each verdict's semantics live in that script's `--help`.

`queue-wait` names three states on an armed head. `queued` has a merge-queue entry, and progress is read from the entry's merge-group head; `cause: progress_unobservable` means that head could not be read. `queued` has one other shape, which is no armed head at all: `cause: exit_unconfirmed` is a PR the last poll saw out of the queue and unarmed, its ejection or disarm short of its confirmation count, so nothing is armed to fire on its own. `armed_awaiting_checks` is armed, not enqueued, with no failed check in the PR's own check rollup: `merge-pr.md` § 5 step 1 waits again on the same head, spending no recovery cycle, until `QUEUE_WAIT_ARMED_MINUTES` (default 90) of wall clock hands it back. `armed_blocked` is armed and never to be enqueued: a failed check takes the recovery cycle, which `CI_FIX_MAX_CYCLES` bounds; every check passed with no entry returns to a fresh readiness check instead, since ci-fix has no failure to work.

A wait is a running waiter, never a session sitting at its prompt.

## Stacked pull requests

`approval-wait` returns `unreviewable` (exit 1) when the deadline passes with no reviewer evidence and the PR's base sits outside the target set of the repo's automatic-review rulesets. Nothing was going to arrive on its own. Which bases draw an automatic review is per-repo configuration, read from the repo's rulesets: the review-gate skill's `.agents/skills/review-gate/references/automatic-review.md`.

Work the chain in this order:

1. Request the review by hand on the stacked PR. This is the remedy, not a workaround:

   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY .agents/skills/orch/scripts/approval-wait [PR_NUMBER] --request-review --base-checkout [REVIEW_BASE_CHECKOUT]
   ```

   On `approval`, re-run the wait. On `fallback`, route as [Copilot requests](#copilot-requests) says, then re-run the wait. The request works on a base the automatic-review ruleset does not target.

2. Merge the bottom of the stack. GitHub retargets the next PR onto the new base, but a retarget is not a documented review trigger: request the review by hand as in step 1, or push a new head where the rule's `review_on_push` is on, then re-run the wait.
3. Fallback, only when the manual request draws nothing: close the PR and open a fresh one against the default branch. Close-and-open, never reopen — reopening re-arms the reviewer only on a PR it has already reviewed once, and does nothing for one it never reviewed.

## Waiter auth ladder

All three waiters share `scripts/lib/gh-auth.sh`, wrapping the GitHub skill's helpers: env-first, each candidate source probed at most once (an env token check killed at its bound is asked again once), exit `3` on hard auth failure. Summary in each `--help`; full ladder in [DEVELOPMENT.md § GitHub auth ladder](https://github.com/vanillagreencom/kendex/blob/main/skills/orch/DEVELOPMENT.md#github-auth-ladder).

## Multi-PR watching

The waiters above are single-PR blocking waits. For many PRs across a long horizon, the review-gate skill (optional dependency) ships `scripts/pr-watch.sh`, a needs-attention reducer — contract in `pr-watch.sh --help`. Orch consumes it through `oversee-watch` when the script is installed. Each pass reads GitHub's review state for every open PR, its unresolved threads, `reviewDecision`, auto-merge arm and merge-queue entry, and writes nothing. The fallback without it is per-PR `approval-wait`/`queue-wait`. `queue-wait` watches only the one PR it is given and only while it runs, so the fallback gives no standing view across PRs and no `awaiting-stale` report. A PR that no waiter watches warrants a manual read of `gh pr view [N] --json reviewDecision,autoMergeRequest` and its queue entry.
