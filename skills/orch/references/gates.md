# Review gate and waiter reference

Load where a workflow reads the review gate, requests Copilot or waits on one pull request. The orch runtime's `verify-review` operation is the review gate. Its `verify-pr` operation judges CI on one pull request, and its `queue-watch` verb watches the merge queue.

## Gate-mode routing

Bind `[REVIEW_BASE_CHECKOUT]` to a checkout of the target pull request's consumer base, never the catalog checkout or the pull request's updated tree. If that checkout is unavailable, stop.

The gate mode is the `mode` of [the review call](#the-review-call)'s reply. The runtime resolves it on the first call to a base and records it as `pr_review.mode` with that base. Every later call to the same base reads that record. After a retarget, the call reads the new base's rules before its verdict and records their mode.

The first call to a base reads the consumer's `REVIEW_GATE_MODE` from the base checkout's `kendex.settings.toml`, `.kendex/settings.toml` and private env file, never from the caller's environment.

- `off` is the mode; `enforce`, or no value, reads GitHub's approval requirement on the base, as the table below says.
- A failed read is an `unreadable` reply with no mode, never `off`. Repeat the call; on a second failure, report it and pick no mode.

| `mode` | Meaning | Route |
|--------|---------|-------|
| `approval` | Consumer policy is `enforce`, and the base's rulesets require an approval or classic protection requires reviews | The review wait |
| `off` | Consumer policy is `off`, or the base's rulesets require no approval and classic protection requires no reviews | No review wait |

Under `off`, the call answers one of:

- `complete` with verdict `off`, and records it;
- `pending copilot-pending` ([§ Copilot requests](#copilot-requests));
- `blocked` while a regression blocker stands ([§ Which waiter answers which state](#which-waiter-answers-which-state)).

Record the gate not applicable only on `off`.

- Under the `off` gate mode, open review threads still stop the merge. Gate 3 of [publication.md § Merge gates](publication.md#merge-gates) applies, and so do the readers [thread-read.md § What reads an open thread](thread-read.md#what-reads-an-open-thread) lists.
- Required CI checks, commit guards, exact-head checks and conflict refusal hold in both modes.
- The merge path still refuses a `CHANGES_REQUESTED` review at its readiness check.
- Under `approval`, an unresolved thread holds the call at `comments` even beside an approval, as gate 3 of [publication.md § Merge gates](publication.md#merge-gates) and merge-pr's thread read ([thread-read.md](thread-read.md)) refuse an open thread.
- A base rule that requires thread resolution also refuses one.

The call reads its settings at its start, in the order of [settings.md § Where a setting is set](settings.md#where-a-setting-is-set). `PR_REVIEW_ON_TIMEOUT` and `ORCH_COPILOT_HOLD_SECS` are in [settings.md](settings.md). The two settings below belong to this gate alone; their defaults are in [settings.md § Review and CI](settings.md#review-and-ci):

| Setting | Meaning |
|---------|---------|
| `PR_REVIEW_WAIT_SECS` | Seconds of one review period, counted from the head's record, or from the head's last `timeout` |
| `PR_COPILOT_REQUESTS` | Whether the review call may request Copilot |

`PR_COPILOT_REQUESTS` takes two values:

- `on` lets the review call request Copilot: on a head under the `approval` gate mode, and under `off` once on a head the call's own ready mark made ready.
- `off` sends no request.

What the call records and owes under each value is [§ Copilot requests](#copilot-requests).

## The review call

`[ROOT]` is the caller's checkout, the lane's worktree. `[REQUEST_DIR]` is `[ROOT]/tmp`. Merge-pr runs from the main checkout and writes its request into `[ITEM_DIR]`, the item's folder: the parent of the `result.path` that `.agents/skills/orch/scripts/orch-runtime state path --item [STATE_KEY]` prints.

- `[OWNER/REPO]` is what `gh repo view --json nameWithOwner --jq .nameWithOwner` answers in `[ROOT]`.
- `[STATE_KEY]` is the caller's workflow-state key, `[ISSUE_ID]` in a lane.
- `[MARK_READY]` is `true` where the step says so, and `false` everywhere else. With `true`, the call marks an open draft ready under either gate mode.

Run the call from `[ROOT]`:

```bash
jq -cn --arg repo "[OWNER/REPO]" --argjson pr [PR_NUMBER] --arg base "[REVIEW_BASE_CHECKOUT]" --argjson ready [MARK_READY] \
  '{op: "verify-review", repo: $repo, pr: $pr, base_checkout: $base, mark_ready: $ready}' \
  > "[REQUEST_DIR]/verify-review-request-[STATE_KEY].json"
.agents/skills/orch/scripts/orch-runtime op --item [STATE_KEY] --request "[REQUEST_DIR]/verify-review-request-[STATE_KEY].json"
```

The call reads the pull request and reads or records the gate mode.

- Under the `off` gate mode, it answers as [§ Gate-mode routing](#gate-mode-routing) says.
- Under `approval`, it counts the head's open threads, reads its reviews, then settles the head's Copilot request ([§ Copilot requests](#copilot-requests)). A head with no verdict after those reads takes its review period.
- A step that needs only the mode or the request runs the call once and reads that field.

The reply, under `.result`:

| Field | Meaning |
|-------|---------|
| `status` | Whether the head is judged, by the values below |
| `mode` | The gate mode, once read |
| `head` | The head this call read |
| `request` | The head's Copilot request record ([§ Copilot requests](#copilot-requests)) |
| `notices` | The head's `copilot-fallback` notices and how each stands; the call sends them, no step does |
| `copilot` | Copilot's work on the head against the hold; its `state` reads `expired` past the bound ([§ Copilot requests](#copilot-requests)) |
| `unresolved_count` | The open threads counted on the head |
| `verdict` | With `complete`, the word the calling step's table routes |

`status` takes three values:

- `complete`: `verdict` is recorded on the item.
- `pending`: the head is not judged yet, and `reason` says why.
- `unreadable`: a read or the ready mark failed, and `reason` names the cause.

Two `pending` reasons change the next step:

- `copilot-pending` means Copilot's work in flight holds the answer ([§ Copilot requests](#copilot-requests)).
- `ready-head-moved head=[SHA]` or `head-moved head=[SHA]` means the head moved; the next call reads it as the new head.

A refusal exits nonzero with its keyed line; each step's table routes the keys it reacts to.

**The review wait.** A step that waits on the verdict runs the call through [Waiter launch](waiter-launch.md).

- It repeats the call while `result.status` is `pending`, no more often than every 30 seconds.
- An `unreadable` reply takes the step's `unreadable` row, which repeats the call within that row's bound.
- The runtime owns the period, so the workflow keeps no budget of its own. The call answers `complete` with `timeout` or `proceeded` once `PR_REVIEW_WAIT_SECS` has passed and no hold of [§ Copilot requests](#copilot-requests) stands. A `timeout` starts the head's next period.
- A step that names a shorter wait runs the call as `env PR_REVIEW_WAIT_SECS=[SECS] .agents/skills/orch/scripts/orch-runtime op ...`.
- A step that must never proceed on a silent reviewer runs it as `env PR_REVIEW_ON_TIMEOUT=block ...`.

**A new head.** The record belongs to the head: a push starts a new record and a new period. A reply whose `head` differs from the head the step bound takes that step's moved-head route.

## Copilot requests

Under the `approval` gate mode, the review call settles the head's Copilot request before it answers the head's verdict, whatever the verdict.

- Every `approval` reply that passed the request carries `request`, `approved` included.
- A refusal, an `unreadable` reply, and a `pending ready-head-moved` or `head-moved` reply can lack it.

Under the `off` gate mode:

- A head the call's own ready mark made ready takes one Copilot request where `PR_COPILOT_REQUESTS` is `on` and no request is recorded yet. That reply carries `request` and still answers `off`, `blocked` or `pending copilot-pending`.
- A head the gate did not mark ready takes no request.

Route the `request` before the verdict word:

- `requested`: the call sent the request. Go on to the verdict.
- `existing`: Copilot's work or review already stands on the head, so no request was needed. Go on to the verdict.
- `fallback`: no request went out, and `cause` says why. The fallback stands on every later call for that head, except a `draft` fallback, which lapses as `draft` says.
  - `off`: the call recorded the fallback while `PR_COPILOT_REQUESTS` was `off`.
  - `draft`: the head is a draft the call was not asked to mark ready. Keep the draft. This fallback lapses once the gate's ready mark lands, or once the view and `pulls/N` both read the head ready. That call answers the head's request as on a head with no request recorded, and starts the head's hold and review period.
  - `refresh`: the consumer's base-checkout `REVIEW_GATE_REFRESH_REVIEW=overseer` declares this pull request its refresh head. The head takes [copilot-head-notices.md § Fallback approval](copilot-head-notices.md#fallback-approval).
  - `no-files`: Copilot's current-head answer says it could review no files. The head takes the same Fallback approval with no further request.
  - `refused` with `exit`: GitHub answered the request with a 4xx refusal.
  - `unconfirmed`: the request and its resend drew neither Copilot's work in flight nor a Copilot review of the head.

A fallback grants no approval:

- Without a standing approval, the wait follows the review period. At expiry, a silent head can return `proceeded` under the configured timeout policy.
- With an approval standing, the call that records the fallback answers that approval's verdict in the same reply. The head can then merge with no Copilot review, while the gate sends the `copilot-fallback` notice in a lane (**The fallback notice** below).
- Outside a lane, report the unavailable Copilot review and route the verdict by the same rule.

**The fallback notice.** Under the `approval` gate mode, the review call sends the `copilot-fallback` notice itself where the item runs in a lane with its launch marker standing. No step sends it. These owe no notice:

- a `draft` or `refresh` fallback;
- any fallback under the `off` gate mode, a refused request's included;
- an item with no launch marker;
- a `claude-cloud` session lane, which has none.

The notice:

- Its first line is `copilot-fallback PR #[PR_NUMBER] head [HEAD_SHA] cause=[CAUSE]`, with ` exit=[N]` after `refused`.
- Its second line is the lane's status path, for the overseer to read.
- Nothing holds the notice: not Copilot's work, an open review thread or a standing change request.
- The overseer's approval follows [copilot-head-notices.md § Fallback approval](copilot-head-notices.md#fallback-approval), and the merge path's own thread and change-request checks still hold the merge.

**Copilot's error answer.**

- With `PR_COPILOT_REQUESTS` `on`, a Copilot review on the head that is its error sentence takes one retry, which the call sends itself.
- With `PR_COPILOT_REQUESTS=off`, the call takes no retry and goes on to the review period.

Where the retry cannot stand, the verdict is `copilot-error`, its `reason` `copilot-error cause=[CAUSE]`.

- The call sends the `copilot-fallback` notice for it as for a fallback, its first line ending with that cause.
- Cause `refresh` owes no notice: its route is the overseer's [Fallback approval](copilot-head-notices.md#fallback-approval) through pr-watch's `refresh-ready`.
- On `copilot-error`, keep the review wait running for the overseer's approval. Every wait restart still takes its caller's head-budget route.
- Outside a lane, report the unavailable Copilot review and keep the approval gate unmet.

**Copilot's work in flight.** While a Copilot check or request runs on the head, within `ORCH_COPILOT_HOLD_SECS` of the head's record, the call answers `pending copilot-pending` in place of a verdict that permits a merge (`approved`, `proceeded` or `off`).

- The call's own request or error retry counts as that work.
- Past the bound, `copilot.state` reads `expired` and the verdict stands as read: the expiry grants no approval.
- A step that merges runs the call before every merge call, and repeats it while it answers `pending copilot-pending` ([merge-pr.md § 5](../workflows/merge-pr.md#5-execute-the-merge) step 1).
- The triage waits on the same work through `orch-runtime copilot-wait` before it reads threads ([review-pr-comments.md § 1](../workflows/review-pr-comments.md#1-fetch-and-parse)), never through this call.

## Which waiter answers which state

| Waiting on | Tool |
|------------|------|
| Reviewer verdict on one pull request | `verify-review` (`orch-runtime op`), [§ The review call](#the-review-call) |
| CI on one pull request | `verify-pr` (`orch-runtime op`) |
| Copilot's work on one pull request's head, before a triage read | `orch-runtime copilot-wait --repo [OWNER/REPO] --pr [PR_NUMBER]` |
| Merge-queue or auto-merge outcome | `orch-runtime queue-watch --item [STATE_KEY] --repo [OWNER/REPO] --pr [PR_NUMBER] --poll [SECS] --max-wait [SECS]` |
| Many pull requests, long horizon | `pr-watch.sh`, [§ Multi-PR watching](#multi-pr-watching) |

How each tool's replies route:

- `verify-review`: `pending` repeated; `complete` and `unreadable` routed by each step.
- `verify-pr`:
  - `pending` or `unreadable` repeated through [Waiter launch](waiter-launch.md); `complete` routed by `submit-pr.md` § 5's result table.
  - A `fail` verdict takes [publication.md § One rerun per head](publication.md#one-rerun-per-head) before ci-fix.
  - The merge state is read through `pr-merge --check` before the first call, and `CONFLICTING` takes the workflow's `conflict` route, never the wait.
- `copilot-wait`: its bound and its reply's routes are [review-pr-comments.md § 1](../workflows/review-pr-comments.md#1-fetch-and-parse)'s.
- `queue-watch`: one wait bounded by `--max-wait`, its reply's `status`, `verdict` and `cause` routed by the table of [merge-contracts.md § Queue wait](merge-contracts.md#queue-wait).

Per-verdict routing lives in the workflows, `submit-pr.md` § 4 and § 5 and `merge-pr.md` § 5, and in [merge-attempt.md](merge-attempt.md) and [merge-contracts.md](merge-contracts.md).

`blocked` is an approval, a `proceeded` or an `off` that the runtime refuses to publish, under either mode, while a `regression-against-main` entry stands open in `escalated_items[]`.

- Its `reason` reads `regression-open location=[LOCATION]`.
- It is never a met gate.
- [review-cycle.md § Escalation](review-cycle.md#escalation) and the [review-pr.md § 7 Converged](../workflows/review-pr.md#converged) exit write the entry.
- The entry stands until its outcome reads `skipped` or it leaves `escalated_items`.

A `queue-watch` answer of `armed_awaiting_checks` or `armed_blocked` at its deadline is the wait's last check reading before the deadline, never a check verdict.

A wait is a running waiter, never a session sitting at its prompt.

## Stacked pull requests

Under the `approval` gate mode, the review call settles a stacked pull request's Copilot request as any other head's ([§ Copilot requests](#copilot-requests)). It does so whatever base the repository's automatic-review rulesets target. The github skill's [automatic-review.md](../../github/references/automatic-review.md) says which bases they target.

Merging the bottom of a stack retargets the next pull request onto the new base without moving its head:

- Its head record stands, and its next review call reads the new base's gate mode ([§ Gate-mode routing](#gate-mode-routing)).
- Where the new base's diff needs Copilot's review, push a new head. [§ Copilot requests](#copilot-requests) settles its request.

## GitHub authentication

`verify-review`, `verify-pr`, `queue-watch` and `copilot-wait` run `gh` as the calling process is authenticated. They select no token of their own, beyond the github router's own order on `queue-watch`'s guard calls. A failed read is an `unreadable` reply, or `queue-watch`'s `status: error`, never a verdict.

## Multi-PR watching

The waits above watch one pull request each. For many pull requests across a long horizon, the github skill ships `scripts/pr-watch.sh`, a needs-attention reducer. Its contract is `pr-watch.sh --help`. The fleet watch, `orch-runtime watch run`, runs it once per repository per long pass.

Without the reducer, the fallback is per-PR `verify-review` and `queue-watch`:

- `queue-watch` watches only the one pull request it is given, and only while it runs.
- The fallback therefore gives no standing view across pull requests and no `awaiting-stale` report.
- A pull request that no wait watches needs a manual read of `gh pr view [N] --json reviewDecision,autoMergeRequest` and its queue entry.
