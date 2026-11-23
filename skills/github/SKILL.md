---
name: github
description: "Load to work or watch GitHub pull requests: threads, comments, reviews, CI logs, merges."
summary: "GitHub API CLI for pull requests: threads, comments, reviews, CI logs, merging, cross-PR analysis and an attention watcher."
license: MIT
user-invocable: true
dependencies:
  optional: [harness-ci]
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
tags: [git, integration]
---

# GitHub pull requests

```bash
.agents/skills/github/scripts/github.sh [-C <path>] <command> [options]
```

## Commands

| Command | Purpose |
|---------|---------|
| `pr-data <N> [--actionable]` | Get a PR with its threads, comments and files. |
| `pr-view [N] [--json FIELDS]` | View PR details through `gh pr view`. |
| `pr-threads <N> [--unresolved\|--resolved] [--format=safe\|raw]` | List or count a PR's review threads. |
| `pr-timeline <N> [--repo OWNER/REPO] [--gate-context NAME]` | One PR's phase stamps, push and bot review times, CI spans, and review and fix rounds as one JSON object. |
| `pr-list-ready [--all] [--format=safe\|table]` | List PRs ready for merge. |
| `pr-list-failing [--all] [--format=safe\|table]` | List PRs with CI failures. |
| `pr-create [--title T] [--body B \| --body-file PATH] [--base B] [--draft] [--dry-run] [--force]` | Create a PR as the bot. |
| `pr-edit-body <N> --body-file PATH` | Update an existing PR body through the sanitized router. |
| `pr-merge <N> [--check\|--auto]` | Merge a PR, or report its readiness. |
| `merge-queue-mutation <disablePullRequestAutoMerge\|dequeuePullRequest> <PR_NODE_ID>` | Run one merge-queue mutation. |
| `ci-classify-refusal <N>` | Name the cause of a pr-merge refusal. |
| `check-review-replies <N>` | Judge what the PR's review replies say. |
| `pr-cross-check [N...] [--quick\|--verify]` | Cross-PR analysis. |
| `pr-issue <N> [--format=safe\|text]` | Extract the issue ID from the PR branch. |
| `label-add <PR-or-issue> <label> [--issue] [--required\|--optional]` | Add a label after checking the live inventory. |
| `label-remove <PR-or-issue> <label> [--issue]` | Remove a label through the sanitized router. |
| `ci-logs <N> [--lines N] [--format=safe\|text]` | Get a PR's CI failure logs. |
| `ci-rerun <N> [--required-only] [--repo OWNER/REPO]` | Rerun the PR's current failed run once. |
| `bot-token [--format=safe\|text]` | Check whether a bot token is configured. |
| `dismiss-review <PR> [--bot\|--user NAME] [--message M]` | Dismiss a blocking review. |
| `resolve-thread <PRRT_...>` | Mark threads resolved. |
| `unresolve-thread <PRRT_...>` | Reopen threads. |
| `post-reply <PRRT_...\|numeric-id> [body \| --body-file PATH] [--pr N]` | Reply to a review comment. |
| `post-comment <PR> [body \| --body-file PATH]` | Post a PR-level comment. |
| `find-comment <PR> --pattern <regex>` | Find a comment by pattern or author. |
| `edit-comment <id> [body \| --body-file PATH]` | Edit an existing comment, PR-level (`#issuecomment-<id>`) or inside a review thread (`#discussion_r<id>`). |
| `sticky-comment <PR> [--verdict\|--analysis\|--body]` | Get the bot's sticky comment. |

- `pr-data --actionable` returns only unresolved threads that are not outdated.
- `pr-threads` returns the complete paginated list or count, outdated threads included. Both filters apply in both formats. See § PR blocked with no visible conversations.
- In `pr-timeline`, bot reviews exclude reply-only reviews, and CI figures exclude Copilot review checks. `pr-timeline --help` defines the clean span over each workflow run's latest attempt and the read limits.
- `pr-create` targets `--base`, else the repository's default branch: `WORKTREE_DEFAULT_BRANCH` when set, else GitHub's.
- `pr-create` first checks that the head is not the base, has commits and is pushed. `--force` skips these checks.
- `pr-merge`: § PR Merge Outcomes.
- A `merge-queue-mutation` is done only where the answer's body carries its payload and no errors. Exit 1 prints the reason.
- Disarm before dequeuing: an armed PR re-enters the queue once its requirements pass.
- `ci-classify-refusal --help` gives its output and retry contract.
- `check-review-replies`: § Review reply check.
- `pr-cross-check --verify` runs a full build and test, detecting the build system.
- `pr-issue` reads its issue pattern from `GH_ISSUE_PATTERN`.
- `label-add --help` gives its mode semantics and exit codes.
- `ci-rerun` reruns only when the failed log names a transient runner failure.
- `ci-rerun` prints `rerun run=ID pattern=P` or `no-rerun cause=...`.
- The caller keeps the once-per-head rule: `ci-rerun --help`.
- `bot-token` names the selected variable as `source`.
- The exit status of `dismiss-review`, `resolve-thread` and `unresolve-thread` reports whether their mutations landed: each command's `--help`.
- `resolve-thread` works on threads the UI cannot render. See § PR blocked with no visible conversations.
- `post-reply` requires `--pr N` for a numeric comment ID. A `PRRT_...` thread ID needs no PR number.
- `edit-comment --help` gives the endpoint order and the unknown-id refusal.
- `sticky-comment --verdict` gives a quick pass or fail. `--analysis` gives the deep recommendation.

CI waiting is the orch skill's:

- Its workflows repeat the orch runtime's `verify-pr` operation on one pull request's current head.
- Its runtime's `queue-watch` reads that verdict on an armed pull request before the merge queue takes it, then the queue entry's progress.

Contracts: `git-https-auth --help`, `git-diff-summary --help`.

### PR Merge Outcomes

`pr-merge --check` reports readiness as JSON on stdout. On stderr it prints a one-word verdict and `head-run: <ids>`, the run scope of the CI classification.

The readiness check:

- It blocks only on contexts the base branch requires, read from its rulesets and classic protection.
- Required workflows contribute check identities from their current completed runs on the head, executed in the consumer repository.
- Workflow file metadata must prove the source repository, path and configured revision.
- Distinct source definitions cannot share an execution.
- Classic required contexts remain name-based.
- A red check outside that set is a `ci_optional_failed:` warning, matching what GitHub itself merges over.
- A required context that has registered no check on the head is `ci_pending: <context> (missing)`.
- Optional pending or queued checks hold neither the merge nor the required-only CI wait.
- A pending required workflow or unregistered workflow jobs hold as ci_pending.
- Unreadable workflow evidence refuses as ci_fetch_failed, even when every visible job passes.
- A failed required workflow holds as ci_failed.
- Other unreadable protection, unnameable rule types and a base that requires nothing count every check.
- `--check`, the immediate merge and `--auto` run that readiness check.
- `ci-classify-refusal` and `ci-rerun --required-only` read the same required set.
- The orch runtime's `verify-pr` judges a head under `required_only` on that set, and otherwise counts every check.

Outcomes and routes:

- Full contract: `pr-merge --help`.
- Exit `75` is volatile:
  - The caller arms one exact head and waits on that head with the orch runtime's `queue-watch`.
  - Orch's `references/merge-contracts.md` § Queue wait maps its verdicts to routes.
  - An unrecognized verdict is never re-armed.
- If `can_merge` is false with no `issues`, read `state`.
- `pr-merge` resolves no review thread.
- The readiness check each call runs (`--check`, the merge and the `--auto` arm) runs the reply check below. That check holds at that moment and no later:
  - `--auto` arms nothing while the check fails.
  - A PR armed before its replies existed stays unread: `pr-merge` does not check it again while it stays armed or queued.
- `--auto` queues a currently-blocked PR. It arms only where the base branch's rulesets require at least 1 approval and thread resolution and dismiss stale approvals on push.
- Otherwise `--auto` refuses with `arm: no-merge-gate=required_approval`, `required_thread_resolution` or `dismiss_stale_reviews`. The rule is `pr-merge --help` § Approvals and review threads.
- On a base that requires a merge queue, `--auto` enrolls the PR and exits `75`, except on an admin route without `--queue`, where it arms nothing and exits `1` with `merge-route: admin cause=queue-bypass-safe` as its first stderr line.
- `--queue` explicitly requests a queue arm.
- On a base whose rules hold a merge queue, the immediate merge first reads its route under the merge's own token, and names it on a `merge-route:` line.
- On that base, it merges with `--admin`, bound to the verified head, and exits `0` only where both of these hold, among the conditions `pr-merge --help` § Merge route lists:
  - The merge queue is all `--admin` would skip.
  - The harness-ci skill's `change-class` reads the PR not queue-only at the base branch's tip, the PR's recorded base being that tip.
- On any other answer it passes `--auto`, which enrolls the PR, and exits `75`.
- GitHub refuses a merge on a queue base that passes neither `--auto` nor `--admin`.
- Each condition of the admin route and each queue `cause=`: `pr-merge --help` § Merge route.
- The merge method is the one the base branch allows, read from GitHub.
- The admin route merges past the queue, so it takes a method a direct merge allows.
- Where a direct merge allows none of the accepted methods, the merge takes the queue.
- `--delete-branch` deletes the head only where the repository's `delete_branch_on_merge` is off and the head is not a fork's: `pr-merge --help` § Merge method and § Branch deletion.

### Review reply check

```bash
.agents/skills/github/scripts/github.sh check-review-replies <N>
```

- The command is read-only.
- It reads the pull request's replies live, through the same PR API readers, project env and token selection as the commands above.
- It fails on four rules:
  - `untracked-claim`: a tracking reply that names no issue.
  - `unreasoned-decline`: a decline that names no mechanism.
  - `thread-replies`: a thread holding more comments than one read returns.
  - `suppressed-findings`: findings a review lists only in its body at the current head, with no head-bound answer.
- A review body counts only from a bot or an `OWNER`, `MEMBER` or `COLLABORATOR`, and never from the PR author.
- A reply counts only from the PR author (an app author included), the identity the check runs as, an `OWNER`, `MEMBER` or `COLLABORATOR`, or a declared automation account (below).
- A thread's first comment is the finding it opens, never a reply.
- Exit `0` passes.
- Exit `1` fails. It prints a `review-replies: fail head=<sha>` line, a line per failing rule and a `suppressed-entry` line per unanswered body finding.
- Exit `2` reached no verdict.
- `check-review-replies --help` gives the grammar of a body-finding answer, of a `Dispositions at <sha>` comment, and of the output lines.
- What a decline must say is reviewer conduct: `.agents/skills/reviewer/references/finding-disposition.md` § Decision flow.

Automation accounts that answer reviews:

- Declare them in the consumer's `kendex.settings.toml` `[env]` setting `GH_REVIEW_REPLY_ACCOUNT_IDS`: whitespace-separated positive numeric account ids, empty by default.
- Their thread replies and head-bound `Dispositions at <sha>` comments count under every checking identity.
- Logins and a commit's author or committer grant no standing.
- A malformed setting reaches no verdict.

### PR blocked with no visible conversations

Under `required_conversation_resolution`, an outdated thread can block a merge while the UI shows none. `resolve-thread` reaches it by id.

```bash
github.sh pr-threads 42                  # complete list, outdated included
github.sh resolve-thread PRRT_kwDO...    # resolve by thread id
```

`pr-threads` follows every page and fails rather than returning a partial list, so a thread id absent from its output is genuinely absent. Repeat `resolve-thread` per blocking id until the merge clears.

### Waiting for merge state

- Read a pull request's merge time from `mergedAt`. An approval or a "merging" notice does not establish that time.
- Read its queue entry through a GraphQL query for `pullRequest { mergeQueueEntry { position } }`. `gh pr view --json` exposes no `mergeQueueEntry` field.
- **Never gate termination on `gh pr view --json mergeable`.** That field stays `UNKNOWN` permanently after a merge. Read `state`, which `pr-merge --check` carries.
- For a PR whose merge state GitHub is still computing, follow the orch skill's `merge-pr.md` § 5 step 1 explicit arm path.

### Watching pull requests

```bash
GH_REPO=OWNER/REPO .agents/skills/github/scripts/pr-watch.sh [PR# ...]
```

- Run it through the harness's wake-up mechanism.
- It reduces every open pull request, or the named ones, to attention lines read from GitHub's review state. It prints nothing for a healthy one.
- Read its attention lines rather than watching review-state transitions.
- Attention kinds, output format, exit codes and settings: `pr-watch.sh --help`.
- Which pull requests draw an automatic review, and what to do when none arrives: [references/automatic-review.md](references/automatic-review.md).

## Configuration

Keep secrets in `.env.local`. Commit non-secret defaults to `kendex.settings.toml` under `[env]`. Other contracts: `github.sh --help`.

## Troubleshooting

A [new required-workflow rule](https://docs.github.com/en/enterprise-cloud@latest/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/troubleshooting-rules#ruleset-workflows-for-open-pull-requests) does not automatically start its workflow for an open pull request. A new commit, a branch update or closing and reopening the pull request triggers it. Read the workflow run against the current rule before reporting that its requirement is met.

If a GraphQL call fails with **`VAR_SIGN`**, use a multi-line GraphQL query with `-F` variables.

On a **stale-token `HTTP 401`**, clear both environment tokens:

```bash
env -u GH_TOKEN -u GITHUB_TOKEN gh pr list
```

- When `GH_TOKEN` or `GITHUB_TOKEN` fails `gh` auth, `github.sh` unsets both and uses `gh` keyring auth, where keyring auth succeeds. It keeps the token in these cases:
  - The selected token source is `GH_BOT_TOKEN`.
  - The auth check times out.
  - `KENDEX_GITHUB_AUTH_TIMEOUT` is not a number of seconds, so the token goes unchecked, with a warning.
- A long-running reader selects its credential once, before it starts, through `.agents/skills/github/scripts/gh-auth-ladder --project ROOT`.
- That script runs the same ladder and prints the `GH_TOKEN` and `GITHUB_TOKEN` it leaves (`gh-auth-ladder --help`).
