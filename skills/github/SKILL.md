---
name: github
description: "Load to work a GitHub pull request: threads, comments, reviews, CI logs, merges."
summary: "GitHub API CLI for pull requests: threads, comments, reviews, CI logs, merging, and cross-PR analysis."
license: MIT
user-invocable: true
dependencies:
  optional: [review-gate, harness-ci]
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
tags: [git, integration]
---

# GitHub Queries

```bash
.agents/skills/github/scripts/github.sh [-C <path>] <command> [options]
```

## Commands

| Command | Purpose |
|---------|---------|
| `pr-data <N> [--actionable]` | Get PR with threads, comments, files. `--actionable`: unresolved non-outdated only. |
| `pr-view [N] [--json FIELDS]` | View PR details (wraps gh pr view with bounded auth/no-PR errors) |
| `pr-threads <N> [--unresolved\|--resolved] [--format=safe\|raw]` | Complete paginated thread list/count, outdated included. Both filters apply in both formats. See *PR blocked with no visible conversations*. |
| `pr-timeline <N> [--repo OWNER/REPO] [--gate-context NAME]` | One PR's phase stamps (first commit, opened, last push, first bot review, the first approval on any head, a since-dismissed one included, or else the first historical review-status pass, the final head's first approval or its historical review-status pass, CI green, armed, queued, merged), the time of every push to its head branch and of every bot review, its CI wall time on the final head and in the merge group, and its review and fix rounds (a head's push to its first review, that review to the next push), as one JSON object. A bot review is one a Bot account other than the PR's author submitted. Reads check suites and their check runs through every page up to the cap its `--help` states; refuses a connection longer than the page it read, or still open at that cap, rather than stamping from part of the history. |
| `pr-list-ready [--all] [--format=safe\|table]` | List PRs ready for merge |
| `pr-list-failing [--all] [--format=safe\|table]` | List PRs with CI failures |
| `pr-create [--title T] [--body B \| --body-file PATH] [--base B] [--draft] [--dry-run] [--force]` | Create PR as bot against `--base`, else the repository's default branch: `WORKTREE_DEFAULT_BRANCH` when set, else GitHub's. Safety checks: the head is not the base, has commits, pushed; `--force` skips them. |
| `pr-edit-body <N> --body-file PATH` | Update an existing PR body through the sanitized router. |
| `pr-merge <N> [--check\|--auto]` | Merge PR. `--check` reports readiness as JSON on stdout plus a one-word verdict and `head-run: <ids>` (the run scope of the CI classification) on stderr; `--auto` queues a currently-blocked PR, and arms only where the base branch's rulesets require at least 1 approval and thread resolution and dismiss stale approvals on push, and refuses the admin route unless `--queue` explicitly requests a queue arm; the immediate merge passes `--admin` to GitHub only where the queue is all its token would bypass and the PR is not queue-only. Three exit codes. See *PR Merge Outcomes*. |
| `ci-classify-refusal <N>` | Name the cause of a pr-merge refusal on one `cause:` line (`fetch_error`, which a reply check with no verdict also is, `merge_conflict`, `changes_requested`, `review_replies`, `ci_failed`, `ci_pending`, `computing`, `merged`, `closed`, `none`; an issue prefix outside that vocabulary becomes the cause word itself, and `none` means the checks pass now); `computing` adds `retry: same-head`, a refusal to retry on the unchanged head, and so does `none` on a PR with its approval and no unresolved review thread; `ci_failed` adds `fail:` lines run-correlated to the authoritative run and `superseded:` lines naming runs whose checks were not counted; every non-terminal cause adds a `ci_optional_failed:` line for red checks the base branch does not require. `--help` |
| `check-review-replies <N>` | Judge what the PR's review replies say, read live and read-only. See *Review reply check*. |
| `pr-cross-check [N...] [--quick\|--verify]` | Cross-PR analysis. `--verify`: full build+test (auto-detects build system). |
| `pr-issue <N> [--format=safe\|text]` | Extract issue ID from PR branch (configurable via `GH_ISSUE_PATTERN`) |
| `label-add <PR-or-issue> <label> [--issue] [--required\|--optional]` | Add a label after checking the live inventory. Mode semantics and exit codes: `label-add --help`. |
| `label-remove <PR-or-issue> <label> [--issue]` | Remove a label through the sanitized router. |
| `ci-logs <N> [--lines N] [--format=safe\|text]` | Get CI failure logs for PR |
| `bot-token [--format=safe\|text]` | Check if bot token is configured, naming the selected variable as `source` |
| `dismiss-review <PR> [--bot\|--user NAME] [--message M]` | Dismiss blocking review. The exit status reports whether the dismissals landed: `dismiss-review --help`. |
| `resolve-thread <PRRT_...>` | Mark thread(s) resolved. Works on threads the UI cannot render. The exit status reports whether the mutations landed: `resolve-thread --help`. See *PR blocked with no visible conversations*. |
| `unresolve-thread <PRRT_...>` | Reopen thread(s). The exit status reports whether the mutations landed: `unresolve-thread --help`. |
| `post-reply <PRRT_...\|numeric-id> [body \| --body-file PATH] [--pr N]` | Reply to review comment. `--pr N` is REQUIRED for numeric comment IDs; thread `PRRT_...` IDs need no PR number. |
| `post-comment <PR> [body \| --body-file PATH]` | Post PR-level comment. |
| `find-comment <PR> --pattern <regex>` | Find comment by pattern/author |
| `edit-comment <id> [body \| --body-file PATH]` | Edit an existing comment, PR-level (`#issuecomment-<id>`) or inside a review thread (`#discussion_r<id>`). Endpoint order and the unknown-id refusal: `edit-comment --help`. |
| `sticky-comment <PR> [--verdict\|--analysis\|--body]` | Get bot sticky comment. `--verdict`: quick pass/fail. `--analysis`: deep recommendation. |

CI waiting belongs to `.agents/skills/orch/scripts/ci-wait`.

Contracts: `label-add --help`, `edit-comment --help`, `git-https-auth --help`, `git-diff-summary --help`.

### PR Merge Outcomes

The `pr-merge` readiness check blocks only on contexts the base branch requires, read from its rulesets and classic protection. Readable required workflows contribute their job check names from completed runs on the head. A red check outside that set is a `ci_optional_failed:` warning, matching what GitHub itself merges over. A required context that has registered no check on the head is `ci_pending: <context> (missing)`. A base that requires nothing or whose whole required set cannot be resolved counts every check. Unfinished required workflows and unreadable workflow evidence keep this fallback. `--check`, the immediate merge and `--auto` run that readiness check; `ci-classify-refusal` reads the same required set. The orch `ci-wait` waiter counts every red check by default; `ci-wait --required-only`, which orch `queue-wait` runs, applies the same required set.

Full contract: `pr-merge --help`. Exit `75` is volatile: the caller arms one exact head and waits on that head with the orch skill's `queue-wait`, whose `--help` § Verdicts maps each verdict to a route; an unrecognized verdict is never re-armed. With the review-gate skill installed, its watcher output contract is `pr-watch.sh --help`. If `can_merge` is false with no `issues`, read `state`. `pr-merge` resolves no review thread. The readiness check each call runs (`--check`, the merge and the `--auto` arm) runs the reply check below, which holds at that moment and no later: `--auto` arms nothing while the check fails, and `pr-merge` does not read again a PR armed before its replies existed while it stays armed or queued. `--auto` refuses with `arm: no-merge-gate=required_approval`, `required_thread_resolution` or `dismiss_stale_reviews` where the base's rulesets do not require an approval, thread resolution and stale-approval dismissal, because GitHub would merge that armed PR before any review, past an open thread, or on an approval of an earlier head; the rule is `pr-merge --help` § Approvals and review threads. On a base that requires a merge queue, `--auto` enrolls the PR and exits `75`, except on an admin route without `--queue`: where the route below reads admin, it arms nothing and exits `1` with `merge-route: admin cause=queue-bypass-safe` as its first stderr line. The immediate merge first reads its route under the merge's own token and names it on a `merge-route:` line: where the merge queue is all `--admin` would skip and the harness-ci skill's `change-class` reads the PR not queue-only, it merges with `--admin` bound to the verified head and exits `0`; any other answer passes `--auto`, which enrolls the PR, and exits `75`, since GitHub refuses a merge on a queue base that passes neither `--auto` nor `--admin`. GitHub still holds an admin merge to every other ruleset. Each condition of the admin route and each queue `cause=`: `pr-merge --help` § Merge route. The merge method is the one the base branch allows, read from GitHub; the admin route merges past the queue, so it takes a method a direct merge allows, and takes the queue where there is none. `--delete-branch` deletes the head only where the repository's `delete_branch_on_merge` is off and the head is not a fork's: `pr-merge --help` § Merge method and § Branch deletion.

### Review reply check

```bash
.agents/skills/github/scripts/github.sh check-review-replies <N>
```

GitHub's approval and thread resolution prove that a reply exists, never what it says, and an author can edit a reply without a push. This read-only command reads the pull request's replies live, through the same PR API readers, project env and token selection as the commands above. It fails on four rules: a tracking reply that names no issue (`untracked-claim`), a decline that names no mechanism (`unreasoned-decline`), a thread holding more comments than one read returns (`thread-replies`), and findings a review lists only in its body at the current head with no head-bound answer (`suppressed-findings`). A review body counts only from a bot or an `OWNER`, `MEMBER` or `COLLABORATOR` who is not the PR author; a reply counts only from the PR author, an app author included, the identity the check runs as, or such a member. A thread's first comment is the finding it opens, never a reply. It needs no review-gate installation and writes nothing. `pr-merge`'s readiness check runs it, orch's submit-pr workflow runs it in its final live gate, orch's Copilot head route runs it before a `copilot-declined-unchanged` or `copilot-fallback` notice, and the overseer runs it before each app approval. Exit `0` passes; `1` fails, printing a `review-replies: fail head=<sha>` line, a line per failing rule and a `suppressed-entry` line per unanswered body finding; `2` reached no verdict. The grammar of a body-finding answer, a `Dispositions at <sha>` comment, and the output lines: `check-review-replies --help`. What a decline must say is reviewer conduct: `.agents/skills/orch/references/finding-disposition.md` § Decision flow.

### PR blocked with no visible conversations

Under `required_conversation_resolution`, an outdated thread can block a merge while the UI shows none; `resolve-thread` reaches it by id.

```bash
github.sh pr-threads 42                  # complete list, outdated included
github.sh resolve-thread PRRT_kwDO...    # resolve by thread id
```

`pr-threads` follows every page and fails rather than returning a partial list, so a thread id absent from its output is genuinely absent. Repeat `resolve-thread` per blocking id until the merge clears.

### Waiting for merge state

**Never gate termination on `gh pr view --json mergeable`.** That field stays `UNKNOWN` permanently after a merge: read `state`, which `pr-merge --check` carries. For a PR whose merge state GitHub is still computing, follow the orch skill's `merge-pr.md` § 5 step 1 explicit arm path. The route contract is `pr-merge --help` § Merge route. To watch MANY PRs, do not hand-roll a poll loop keyed on state transitions. Use the review-gate skill's reducer when installed (`.agents/skills/review-gate/scripts/pr-watch.sh`).

## Output Formats

Formats and flag rules: `github.sh --help`.

## Configuration

Keep secrets in `.env.local`; commit non-secret defaults to `kendex.settings.toml` under `[env]`. Other contracts: `github.sh --help`.

## Troubleshooting

**`VAR_SIGN`**: use a multi-line GraphQL query with `-F` variables.

**Stale-token `HTTP 401`**: clear both environment tokens:

```bash
env -u GH_TOKEN -u GITHUB_TOKEN gh pr list
```

`github.sh` falls back when keyring auth succeeds.

## Dependencies

- `gh` CLI (authenticated)
- `jq`
- `op` CLI (optional, 1Password token references)
