# Copilot head notices

Read when the overseer handles a Copilot head notice: the three notices [review-pr-comments.md § 7.2](../workflows/review-pr-comments.md#72-copilot-head-route) sends as a `lane-notice`, the review call's own `copilot-fallback` ([gates.md § Copilot requests](gates.md#copilot-requests)), or a pr-watch `awaiting-stale` or `refresh-ready` line ([oversee-events.md § Event kinds](oversee-events.md#event-kinds)). The first line of a § 7.2 notice is its kind, then `PR #[N] head [SHA]`. Read the review call's notice by [gates.md § Copilot requests](gates.md#copilot-requests).

## Approve a head

Every approval on this page is one `approve-head` request on an item's record: the owning lane's item, or for a pull request no lane owns a dedicated item, made once with `.agents/skills/orch/scripts/orch-runtime state init --item [ITEM]` and reused for that pull request.

Write the approval body to `[BODY_PATH]` and the request to `[PATH]`. `head` is the SHA the notice or the pr-watch line names, as printed. `repo` is the repository the pr-watch line leads with, or for a notice the owning lane's repository:

```json
{"op":"approve-head","repo":"[OWNER/REPO]","pr":[N],"head":"[SHA]","body_file":"[BODY_PATH]","hold_copilot":true}
```

A `copilot-declined-unchanged` approval sets `hold_copilot` to `false` and adds `"comment_file":"[COMMENT_PATH]"`, the comment the approval posts first. Run the request from the trusted consumer checkout, then route `result.status` by § Answers:

```bash
.agents/skills/orch/scripts/orch-runtime op --item [ITEM] --request [PATH]
```

## What the runtime checks

The consumer supplies its own GitHub App identity: `ORCH_OVERSEER_REVIEW_TOKEN_FILE` names the file holding the app's installation token, which the consumer's own tooling writes, and `ORCH_OVERSEER_REVIEW_LOGIN` names the app's login. The runtime reads the token only from a regular file this user owns with no group or other bits, under a parent this user owns with no group or other write bit, holding one word (`watch/security.rs` `read_token`).

The runtime reads the pull request's live head with that token, approves only when the live head starts with `head`, and binds the review to the full head it read. It records the attempt on the item before the POST. Before every approval POST it runs `github.sh check-review-replies [N]` for the target repository, and posts only when the reader exits `0` with `review-replies: pass head=` equal to the bound head.

## The Copilot hold

Every fallback approval sets `hold_copilot` to `true`. A proved-render refresh approval and a `copilot-declined-unchanged` approval set it to `false`. With the hold, the call waits while Copilot's work runs on the head, up to `ORCH_COPILOT_HOLD_SECS` (`ops/approve.rs` `hold`):

- Work that ends inside the hold answers `finished`: approve nothing, write no `use1` row, and repeat the request on the same head, which then checks the review replies Copilot's review left.
- Work still running at the bound permits the approval once the runtime reads the live head again and finds it unchanged.
- A failed check-run read approves nothing.

A `review-replies` refusal approves nothing, writes no `use1` row, and directs the lane to answer what `github.sh check-review-replies [N]` names. A `suppressed-entry` there is a finding Copilot wrote only in a review body, which no thread carries.

## Answers

| `result.status` | Meaning | Action |
|---|---|---|
| `confirmed` | The POST's answer read `state` `APPROVED` at the bound head, whichever login it names, or a read-back of the reviews found an approval of that head by the `ORCH_OVERSEER_REVIEW_LOGIN` login. Where the review names another login, `result.detail` reads `login-differs configured=[LOGIN] review=[REVIEW_LOGIN]`. | Write the `use1` row. On `login-differs`, correct the setting, which every read-back matches. |
| `finished` | Copilot's work ended inside the hold. | Approve nothing; repeat the same request. |
| `refused` | Nothing approved; the attempt is cleared. `reason` is `post-failed` (GitHub refused the POST), `not-started` (the POST never started), `not-landed` (after a lost answer, a complete read of the reviews found no approval from the app at the head), or a comment reason (§ Notice rules). | Once the cause is gone, an app permission granted or a failing service back, send the same request again. |
| `unknown` | The POST's answer was lost and the reviews could not be read whole. | Repeat the same request: it reads the reviews back first and posts again only after a complete read finds no approval. |

A refusal of the request itself approves nothing:

- `head-moved` writes no `use1` row; the new head takes its own route.
- `approval-setting-unread` means the private env file sets a key the approval reads (the token file, the login, `GH_HOST`, or a reader credential such as `GH_TOKEN`) in a form only a shell reads. Write it there as a plain value.

### Refusal fields

A refusal names what it judged in `refusal.fields`:

| Refusal | Fields |
|---|---|
| `head-moved` | `given`, the head asked for; `live`, the head read |
| `head-read-failed`, `approval-read-back`, `comment-read-back` | gh's `detail` |
| `credential` | the token `file` judged and the reader's `cause`: `unset`, `not-regular`, `not-owned`, `ownership-unread`, `mode-NNN`, `too-long` or `malformed` |
| `copilot-read-failed` | the read's `reason` and gh's `detail` |
| `copilot-hold-setting` | the `value` |
| `review-replies` | the reader's `exit`, its `result` line, its stderr as `detail` beside a failed exit, and a `fix` |
| `approval-login-changed` | the `recorded` login an unsettled act on that head stands under, and the `configured` one |
| `approval-request`, `body-file`, `comment-file`, `approval-login`, `approval-record`, `approval-setting-unread` | none |

A `refused` or `unknown` result carries gh's words as `result.detail`.

## While the lane's review is pending

While the lane status file's `Review:` line reads `pending` for that pull request ([review-pr.md § 1](../workflows/review-pr.md#1-identify-changes)), every rule on this page, § Fallback approval included, approves nothing, requests no Copilot review and directs no lane: the lane's own review is still running on a pull request [start-worktree.md § 2.1](../workflows/start-worktree.md#21-open-early) opened early. The verdict line [submit-pr.md § 2](../workflows/submit-pr.md#2-push-and-submit) step 1 writes in its place, once the push carrying the review's fix round lands, ends the hold. That step routes the pushed head once by [review-pr-comments.md § 7.2](../workflows/review-pr-comments.md#72-copilot-head-route), which re-delivers what the hold held: a head Copilot read takes its notice, and any other head the review call's `request` route. A request that call sends restarts pr-watch's quiet period, so a held `awaiting-stale` line rises again.

## Notice rules

- `copilot-declined-unchanged`: when the notice lists every thread `github.sh pr-threads [N]` gives with `author` `copilot-pull-request-reviewer`, each reply holds at that head, and each body finding is listed with the comment answering it, write one comment saying why each decline holds to a file. Approve the head at once with one `approve-head` request whose `comment_file` names that file, with no Copilot re-review. `approve-head` is the comment's one writer: once the review-reply check passes, it posts the comment as the app, then records and posts the approval. An unreadable or empty file refuses `comment-file` before any GitHub call. A comment that did not land approves nothing: `refused` with `reason` `comment-failed` where GitHub refused it (gh's words in `result.detail`) or `comment-not-started` where its POST never started; `unknown` with `reason` `comment-unconfirmed` where its answer was lost. Repeat the same request: it reads the comments back and posts again only after a complete read finds none from the app with that text. Where the notice does not hold, direct the lane on what does not hold and approve nothing.
- `copilot-fallback`: approve the head with `approve-head`, `hold_copilot` `true`, when the lane's own review of it passed with no open blocker; otherwise direct the lane on what its review left open. On the review call's own notice, judge the lane's review from the lane status file the notice names, in the lane's worktree. Its `cause=off` does not say the repository's `PR_COPILOT_REQUESTS` reads `off` now. On approving a head whose notice ends in `cause=refused exit=N`, also send one notice naming the pull request, the head and that cause to the Jarvis session while one runs: a spent Copilot budget is one cause of that refusal, and a request that keeps failing for another reason then reaches a person. Its `cause=no-files` takes § Fallback approval's `no-files` route.
- `copilot-approved-on-rerequest`: Copilot approved the head; approve nothing.

## Consumer refresh approval

A pr-watch `refresh-ready` line takes this route at once, also when no lane owns the pull request, and before § Fallback approval.

1. Re-read the pull request. Require the refresh identity the consumer's base-checkout settings declare, read from the settings files [gates.md § Gate-mode routing](gates.md#gate-mode-routing) names, never from the caller's environment: head branch `REVIEW_GATE_REFRESH_BRANCH` exactly, author `REVIEW_GATE_REFRESH_AUTHOR`, author type `Bot`. A consumer that declares no identity has no refresh route.
2. Read its full head and require it to start with the line's SHA.
3. From the trusted consumer checkout, read the render proof with the command below.
4. Require the CI aggregate to pass on the same head.
5. On the proof's exit `0`, approve that head with `approve-head`, `hold_copilot` `false`; the runtime runs the review-reply check. Record a fallback Use 1 row.

```bash
env -u GH_REPO -u GITHUB_REPOSITORY .agents/skills/orch/scripts/orch-runtime ci-proof [N] [FULL_HEAD_SHA] --repo [OWNER/REPO]
```

Exit `0` prints `ci-proof: head=SHA class=render measured=true version=VERSION job=ID`: the latest trusted `Classify the diff` check on that head measured a render, its verifier's version equals the `Engine version: kendex X` the pull request body declares, and no workflow path changed except the adopted refresh caller. Exit `1` prints `ci-proof: cause=WORD`.

The proved-render branch starts no internal review, GitHub agent review or Copilot wait: the catalog already reviewed the rendered packages. `class-not-render`, `engine-mismatch` and `workflow-changed` enter § Fallback approval at once from this `refresh-ready` line, which applies the consumer's review route and requires review before approval. `ci-proof-missing`, a failed aggregate or a moved head grants no approval. The approval, stale-approval dismissal and thread-resolution rules still control merging.

## Fallback approval

An `awaiting-stale` line means no approval reached the head within the quiet period. A `refresh-ready` line enters here after § Consumer refresh approval reads a completed classifier result that cannot prove render. A pending review line takes § While the lane's review is pending first. A head a `copilot-declined-unchanged` notice names takes that notice's rule instead.

1. When the owning lane's own review of that head passed with no open blocker, approve the head with `approve-head`, `hold_copilot` `true`. The base's rules count the app's approval like Copilot's; no ruleset or setting changes. Send one notice naming the pull request and the head to the Jarvis session while one runs.
2. Otherwise, use the [Copilot request owner](gates.md#copilot-requests), with `[PR_NUMBER]` set to `[N]` and `[REVIEW_BASE_CHECKOUT]` bound per that reference. Route its answer before any review wait:
   - `fallback`: a consumer workflow can still request Copilot on that head, so step 1's approval keeps `hold_copilot` `true`.
   - `fallback cause=refresh`: review that head from the consumer checkout with the reviewer skill. When the review leaves no open blocker, approve it with `approve-head`, `hold_copilot` `true`, and record a fallback Use 1 row. Otherwise approve nothing and send one owner notice naming the pull request, the head and the open blockers.
   - `fallback cause=no-files`: send no further Copilot request. When the owning lane's review of that head passed with no open blocker, take step 1. When the head's workflow state tier is `micro`, the lane ran no internal review: approve nothing and direct the lane to take [micro.md § Escape](../workflows/micro.md#escape) through `/orch small [ISSUE_ID]`, with one internal review round before the fallback approval. The overseer reviews nothing itself on this branch.
   - Any other answer: direct the lane on what its review left open.

## Use 1 rows

Each head approved through a notice above, by the overseer or by Copilot, or through § Fallback approval or § Consumer refresh approval, is one `use1` append to the fleet log, written as [oversee-events.md § Judgement rules](oversee-events.md#judgement-rules) directs, with `text` `PR #[N] head [SHA]` and `outcome` `declined-unchanged`, `fallback`, or `approved-on-rerequest` for Copilot's approval. The owner report, `orch-runtime report render`, counts these rows in its Use 1 line.
