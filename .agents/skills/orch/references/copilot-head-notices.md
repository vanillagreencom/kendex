# Copilot head notices

Read when the overseer handles a Copilot head notice: the three notices [copilot-head-route.md § Copilot head route](copilot-head-route.md#copilot-head-route) sends as a `lane-notice`, the review call's own `copilot-fallback`, or a pr-watch `awaiting-stale` or `refresh-ready` line ([oversee-events.md § Event kinds](oversee-events.md#event-kinds)). The first line of a notice copilot-head-route.md sends is its kind, then `PR #[N] head [SHA]`. Read the review call's notice by [gates.md § Copilot requests](gates.md#copilot-requests).

## Approve a head

Every approval on this page is one `approve-head` request on an item's record in the overseer's checkout.

- The item is the owning lane's item.
- A hosted lane's record is on its host, so that checkout can hold none for the item: the request then needs no setup, and the approval creates the record, as `state init` writes it, for its `head_approvals` ledger.
- A pull request no lane owns takes a dedicated item, reused for that pull request.

Write the approval body to `[BODY_PATH]` and the request to `[PATH]`.

- `head` is the SHA the notice or the pr-watch line names, as printed.
- `repo` is the repository the pr-watch line leads with; for a notice, it is the owning lane's repository:

```json
{"op":"approve-head","repo":"[OWNER/REPO]","pr":[N],"head":"[SHA]","body_file":"[BODY_PATH]","hold_copilot":true}
```

A `copilot-declined-unchanged` approval sets `hold_copilot` to `false` and adds `"comment_file":"[COMMENT_PATH]"`, the comment the approval posts first.

For a `copilot-fallback` notice with `cause=quick`, add `"quick_notice":"[FIRST_LINE]"` with the notice's first line exactly as delivered. The line carries `head [SHA] cause=quick base=[BASE_SHA]`. Include the first line even when an older notice lacks the base.

Run the request from the trusted consumer checkout, then route `result.status` by § Answers:

```bash
.agents/skills/orch/scripts/orch-runtime op --item [ITEM] --request [PATH]
```

## What the runtime checks

The consumer supplies its own GitHub App identity.

- `ORCH_OVERSEER_REVIEW_TOKEN_FILE` names the file holding the app's installation token, which the consumer's own tooling writes.
- `ORCH_OVERSEER_REVIEW_LOGIN` names the app's login.
- `approve-head` reads the token file only when it is a regular file this user owns, with no group or other bits, under a parent this user owns with no group or other write bit, holding one word ([security.rs](../runtime/src/watch/security.rs) `read_token`).

The runtime approves only a live head that starts with `head`, and posts only after `github.sh check-review-replies [N]` passes on that head.

## The Copilot hold

With the hold, the call waits while Copilot's work runs on the head, up to [`ORCH_COPILOT_HOLD_SECS`](settings.md#review-and-ci) (`ops/approve.rs` `hold`).

Work that ends inside the hold answers `finished`: approve nothing, write no `use1` row, and repeat the request on the same head. The repeat checks the review replies Copilot's review left.

A `review-replies` refusal approves nothing and writes no `use1` row.

- Direct the lane to answer what `github.sh check-review-replies [N]` names.
- A `suppressed-entry` there is a finding Copilot wrote only in a review body, which no thread carries.

## Answers

| `result.status` | Meaning | Action |
|---|---|---|
| `confirmed` | The head stands approved. | Write the `use1` row. |
| `finished` | Copilot's work ended inside the hold. | Approve nothing; repeat the same request. |
| `refused` | Nothing approved; `reason` names why. | Once the cause is gone, such as an app permission granted or a failing service back, send the same request again. |
| `unknown` | The POST's answer was lost and the reviews could not be read whole. | Repeat the same request. |

- `confirmed`: where the review names another login than `ORCH_OVERSEER_REVIEW_LOGIN`, `result.detail` reads `login-differs configured=[LOGIN] review=[REVIEW_LOGIN]`. On `login-differs`, correct the setting: every read-back matches it.
- `refused` with `reason` `approval-dismissed` means GitHub dismissed the approval this request confirmed earlier, and nothing posts again. A repeat of `approval-dismissed` answers the same.
- `unknown`: the repeat reads the reviews back first, and posts again only after a complete read finds no approval.

A refusal of the request itself approves nothing and names what it judged in `refusal.fields`:

- `head-moved` writes no `use1` row; the new head takes its own route.
- `quick-proof-stale` writes no `use1` row. Run the owning lane's [review call](gates.md#the-review-call) and route its request. A new `fallback cause=quick` takes the current range's notice.
- `approval-setting-unread` means the private env file sets a key the approval reads (the token file, the login, `GH_HOST`, or a reader credential such as `GH_TOKEN`) in a form only a shell reads. Write it there as a plain value.

## While the lane's review is pending

While the lane status file's `Review:` line reads `pending` for that pull request ([review-pr.md § 1](../workflows/review-pr.md#1-identify-changes)), no rule on this page acts, § Fallback approval included: approve nothing, request no Copilot review and direct no lane.

- Once the push carrying the review's fix round lands, [submit-pr.md § 2](../workflows/submit-pr.md#2-push-and-submit) step 1 writes a verdict line in its place, which ends the hold.
- That step routes the pushed head once by [copilot-head-route.md § Copilot head route](copilot-head-route.md#copilot-head-route), which re-delivers what the hold held. A head Copilot read takes its notice; any other head takes the review call's `request` route.
- A request that call sends restarts pr-watch's quiet period, so a held `awaiting-stale` line rises again.

## Notice rules

- `copilot-declined-unchanged`: the notice holds when it lists every thread `github.sh pr-threads [N]` gives with `author` `copilot-pull-request-reviewer`, each reply holds at that head, and it lists each body finding with the comment answering it. Where the notice does not hold, approve nothing and direct the lane on what does not hold.
  1. Where it holds, write one comment to a file saying why each decline holds.
  2. Approve the head at once with one `approve-head` request whose `comment_file` names that file, with no Copilot re-review. `approve-head` is the comment's one writer: once the review-reply check passes, it posts the comment as the app, then records and posts the approval.
  3. A comment that did not land approves nothing. Repeat the same request: it reads the comments back, and posts again only after a complete read finds none from the app with that text.
- `copilot-fallback`: approve the head with `approve-head`, `hold_copilot` `true`, when the lane's own review of it passed with no open blocker. Otherwise direct the lane on what its review left open.
  - On the review call's own notice, judge the lane's review from the lane status file the notice names, in the lane's worktree.
  - The notice's `cause=off` does not say the repository's `PR_COPILOT_REQUESTS` reads `off` now.
  - On approving a head whose notice ends in `cause=refused exit=N`, also send the Jarvis session, while one runs, one notice naming the pull request, the head and that cause.
  - The notice's `cause=no-files` takes § Fallback approval's `no-files` route.
- `copilot-approved-on-rerequest`: Copilot approved the head; approve nothing.

## Consumer refresh approval

A pr-watch `refresh-ready` line takes this route at once, also when no lane owns the pull request, and before § Fallback approval.

1. Re-read the pull request. Require the refresh identity the consumer's base-checkout settings declare: head branch `REVIEW_GATE_REFRESH_BRANCH` exactly, author `REVIEW_GATE_REFRESH_AUTHOR`, author type `Bot`. Read it from the settings files [gates.md § Gate-mode routing](gates.md#gate-mode-routing) names, never from the caller's environment. A consumer that declares no identity has no refresh route.
2. Read its full head and require it to start with the line's SHA.
3. From the trusted consumer checkout, read the render proof with the command below.
4. Require the CI aggregate to pass on the same head.
5. On the proof's exit `0`, approve that head with `approve-head`, `hold_copilot` `false`, and record a fallback Use 1 row. The runtime runs the review-reply check.

```bash
env -u GH_REPO -u GITHUB_REPOSITORY .agents/skills/orch/scripts/orch-runtime ci-proof [N] [FULL_HEAD_SHA] --repo [OWNER/REPO]
```

`orch-runtime ci-proof --help` states the line each exit prints; exit `1` names its `cause`.

The proved-render branch starts no internal review, GitHub agent review or Copilot wait.

- `class-not-render`, `engine-mismatch` and `workflow-changed` enter § Fallback approval at once from this `refresh-ready` line. There the consumer's review route applies, and approval requires review.
- `ci-proof-missing`, a failed aggregate or a moved head grants no approval.
- The approval, stale-approval dismissal and thread-resolution rules still control merging.

## Fallback approval

For a proved quick change whose pull request the overseer app authors, skip `approve-head` and follow the Copilot approval route in [micro.md § 4](../workflows/micro.md#4-arm-and-wait).

An `awaiting-stale` line means no approval reached the head within the quiet period. A `refresh-ready` line enters here after § Consumer refresh approval reads a completed classifier result that cannot prove render.

- A pending review line takes § While the lane's review is pending first.
- A head a `copilot-declined-unchanged` notice names takes that notice's rule instead.

1. When the owning lane's own review of that head passed with no open blocker, approve the head with `approve-head`, `hold_copilot` `true`.
   - The base's rules count the app's approval like Copilot's, and no ruleset or setting changes.
   - Send the Jarvis session, while one runs, one notice naming the pull request and the head.
2. Otherwise, use the [Copilot request owner](gates.md#copilot-requests), with `[PR_NUMBER]` set to `[N]` and `[REVIEW_BASE_CHECKOUT]` bound per that reference. Route its answer before any review wait:
   - `fallback`: a consumer workflow can still request Copilot on that head, so step 1's approval keeps `hold_copilot` `true`.
   - `fallback cause=quick`: follow § Notice rules with the current range's `copilot-fallback` notice.
   - `fallback cause=refresh`: review that head from the consumer checkout with the reviewer skill.
     - When the review leaves no open blocker, approve it with `approve-head`, `hold_copilot` `true`, and record a fallback Use 1 row.
     - Otherwise approve nothing, and send one owner notice naming the pull request, the head and the open blockers.
   - `fallback cause=no-files`: send no further Copilot request.
     - When the owning lane's review of that head passed with no open blocker, take step 1.
     - When the head's workflow state tier is `micro`, the lane ran no internal review. Approve nothing, and direct the lane to take [micro.md § Escape](../workflows/micro.md#escape) through `/orch small [ISSUE_ID]`, with one internal review round before the fallback approval.
     - The overseer reviews nothing itself on this branch.
   - Any other answer: direct the lane on what its review left open.

## Use 1 rows

Each head approved through a notice above (by the overseer or by Copilot), through § Fallback approval or through § Consumer refresh approval is one `use1` append to the fleet log. Write it as [oversee-events.md § Judgement rules](oversee-events.md#judgement-rules) directs, with `text` `PR #[N] head [SHA]`. Its `outcome` is `declined-unchanged`, `fallback`, or `approved-on-rerequest` for Copilot's approval. The owner report, `orch-runtime report render`, counts these rows in its Use 1 line.
