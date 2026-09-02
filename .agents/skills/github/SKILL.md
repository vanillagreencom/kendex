---
name: github
description: "Load to work a GitHub pull request: threads, comments, reviews, CI logs, merges."
summary: "GitHub API CLI for pull requests: threads, comments, reviews, CI logs, merging, and cross-PR analysis."
license: MIT
user-invocable: true
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
  version: "2.0.0"
tags: [git, integration]
---

<!-- kendex:project-instructions:start -->
## Project Instructions

Problems with a kendex-owned skill go through `kendex report`; check ownership in the file first.
<!-- kendex:project-instructions:end -->

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
| `pr-list-ready [--all] [--format=safe\|table]` | List PRs ready for merge |
| `pr-list-failing [--all] [--format=safe\|table]` | List PRs with CI failures |
| `pr-create [--title T] [--body B \| --body-file PATH] [--draft] [--dry-run] [--force]` | Create PR as bot. Safety checks: not main, has commits, pushed; `--force` skips them. |
| `pr-edit-body <N> --body-file PATH` | Update an existing PR body through the sanitized router. |
| `pr-merge <N> [--check\|--force\|--auto]` | Merge PR. `--check` reports readiness as JSON on stdout plus a one-word verdict and `head-run: <ids>` (the run scope of the CI classification) on stderr; `--auto` queues a currently-blocked PR. Three exit codes, the review-thread gate, and `--force` — see *PR Merge Outcomes*. |
| `ci-classify-refusal <N>` | Name the cause of a pr-merge refusal on one `cause:` line (`fetch_error`, `merge_conflict`, `changes_requested`, `threads`, `ci_failed`, `ci_pending`, `computing`, `merged`, `closed`, `none`; an issue prefix outside that vocabulary becomes the cause word itself, and `none` means the checks pass now); `ci_failed` adds `fail:` lines run-correlated to the authoritative run and `superseded:` lines naming runs whose checks were not counted. `--help` |
| `pr-cross-check [N...] [--quick\|--verify]` | Cross-PR analysis. `--verify`: full build+test (auto-detects build system). |
| `pr-issue <N> [--format=safe\|text]` | Extract issue ID from PR branch (configurable via `GH_ISSUE_PATTERN`) |
| `label-add <PR-or-issue> <label> [--issue] [--required\|--optional]` | Add a label after checking the live inventory. Mode semantics and exit codes: *Label application contract*. |
| `label-remove <PR-or-issue> <label> [--issue]` | Remove a label through the sanitized router. |
| `await-mergeable <N> [--interval S] [--max-iter N] [--quiet]` | Block until GitHub resolves a PR's merge state. Polls `state` + `mergeStateStatus`. Exit 0 + JSON on resolve, 124 on timeout. |
| `ci-logs <N> [--lines N] [--format=safe\|text]` | Get CI failure logs for PR |
| `bot-token [--format=safe\|text]` | Check if bot token is configured |
| `dismiss-review <PR> [--bot\|--user NAME] [--message M]` | Dismiss blocking review |
| `resolve-thread <PRRT_...>` | Mark thread(s) resolved. Works on threads the UI cannot render. See *PR blocked with no visible conversations*. |
| `unresolve-thread <PRRT_...>` | Reopen thread(s) |
| `post-reply <PRRT_...\|numeric-id> [body \| --body-file PATH] [--pr N]` | Reply to review comment. `--pr N` is REQUIRED for numeric comment IDs; thread `PRRT_...` IDs need no PR number. |
| `post-comment <PR> [body \| --body-file PATH]` | Post PR-level comment. |
| `find-comment <PR> --pattern <regex>` | Find comment by pattern/author |
| `edit-comment <id> [body \| --body-file PATH]` | Edit existing comment. |
| `sticky-comment <PR> [--verdict\|--analysis\|--body]` | Get bot sticky comment. `--verdict`: quick pass/fail. `--analysis`: deep recommendation. |

CI waiting belongs to `.agents/skills/orch/scripts/ci-wait`; `await-mergeable`
waits for merge-state resolution.

### Label application contract

Label modes and failures: `label-add --help`.

### Git HTTPS Auth Helper

Contract: `git-https-auth --help`.

### Diff Summary Helper

Contract: `git-diff-summary --help`.

### PR Merge Outcomes

Full contract: `pr-merge --help`.
Exit `75` is volatile, so keep a watcher running until `MERGED`.
If `can_merge` is false with no `issues`, read `state`.
The thread gate is **Policy, not mechanism.** `--force` is its only override.

### PR blocked with no visible conversations

Under `required_conversation_resolution`, an outdated thread can become
unreachable in the UI while still blocking the merge: after a rebase or
force-push the commented commits are gone, clicking the unresolved conversation
404s, and the PR shows zero visible conversations yet refuses to merge. GraphQL
`resolveReviewThread` still acts on threads the UI cannot render, so this skill
is the escape hatch:

```bash
github.sh pr-threads 42                  # complete list, outdated included
github.sh resolve-thread PRRT_kwDO...    # resolve by thread id
```

`pr-threads` follows every page and fails rather than returning a partial list,
so a thread id absent from its output is genuinely absent. Repeat
`resolve-thread` per blocking id until the merge clears.

### Waiting for merge state

**Never gate termination on `gh pr view --json mergeable`.** That field stays
`UNKNOWN` permanently after a merge. Use `await-mergeable` (resolution rules
and exit codes: `await-mergeable --help`). To watch MANY PRs, do not
hand-roll a poll loop keyed on state transitions — use the review-gate
skill's reducer when installed
(`.agents/skills/review-gate/scripts/pr-watch.sh`).

## Output Formats

Formats and flag rules: `github.sh --help`.

## Configuration

Keep secrets in `.env.local`; commit non-secret defaults to
`kendex.settings.toml` under `[env]`. Other contracts: `github.sh --help`.

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
