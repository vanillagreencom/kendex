---
name: github
description: "Load to work a GitHub pull request: threads, comments, reviews, CI logs, merges."
summary: "GitHub API CLI for pull requests: threads, comments, reviews, CI logs, merging, and cross-PR analysis."
license: MIT
user-invocable: true
dependencies:
  optional: [harness-ci, orch, review-gate]
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
  version: "2.0.0"
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
| `pr-list-ready [--all] [--format=safe\|table]` | List PRs ready for merge |
| `pr-list-failing [--all] [--format=safe\|table]` | List PRs with CI failures |
| `pr-create [--title T] [--body B \| --body-file PATH] [--draft] [--dry-run] [--force]` | Create PR as bot. Safety checks: not main, has commits, pushed; `--force` skips them. |
| `pr-edit-body <N> --body-file PATH` | Update an existing PR body through the sanitized router. |
| `pr-merge <N> [--check\|--force\|--admin\|--admin-credential\|--auto]` | Merge PR. `--check` reports readiness as JSON on stdout plus a one-word verdict and `head-run: <ids>` (the run scope of the CI classification) on stderr; `--auto` queues a currently-blocked PR; `--admin-credential` is the overseer's gated merge under the control host's owner credential, and prints one `admin-merge` record line. Three exit codes, the review-thread gate, and `--force`/`--admin`. See *PR Merge Outcomes*. |
| `ci-classify-refusal <N>` | Name the cause of a pr-merge refusal on one `cause:` line (`fetch_error`, `merge_conflict`, `changes_requested`, `threads`, `ci_failed`, `ci_pending`, `computing`, `merged`, `closed`, `none`; an issue prefix outside that vocabulary becomes the cause word itself, and `none` means the checks pass now); `ci_failed` adds `fail:` lines run-correlated to the authoritative run and `superseded:` lines naming runs whose checks were not counted; every non-terminal cause adds a `ci_optional_failed:` line for red checks the base branch does not require. `--help` |
| `pr-cross-check [N...] [--quick\|--verify]` | Cross-PR analysis. `--verify`: full build+test (auto-detects build system). |
| `pr-issue <N> [--format=safe\|text]` | Extract issue ID from PR branch (configurable via `GH_ISSUE_PATTERN`) |
| `label-add <PR-or-issue> <label> [--issue] [--required\|--optional]` | Add a label after checking the live inventory. Mode semantics and exit codes: `label-add --help`. |
| `label-remove <PR-or-issue> <label> [--issue]` | Remove a label through the sanitized router. |
| `await-mergeable <N> [--interval S] [--max-iter N] [--quiet]` | Block until GitHub resolves a PR's merge state. Polls `state` + `mergeStateStatus`. Exit 0 + JSON on resolve, 124 on timeout. |
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

CI waiting belongs to `.agents/skills/orch/scripts/ci-wait`; `await-mergeable` waits for merge-state resolution.

Contracts: `label-add --help`, `edit-comment --help`, `git-https-auth --help`, `git-diff-summary --help`.

### PR Merge Outcomes

The `pr-merge` readiness check blocks only on contexts the base branch requires, read from its rulesets and classic protection. A red check outside that set is a `ci_optional_failed:` warning, matching what GitHub itself merges over. A required context that has registered no check on the head is `ci_pending: <context> (missing)`. A base that requires nothing, whose protection cannot be read, or whose ruleset carries a rule gating the merge on a check it does not name, counts every check. Every mode but `--force` and `--admin` runs that readiness check, `--check`, the immediate merge and `--auto` alike, and `ci-classify-refusal` reads the same required set. The orch `ci-wait` waiter counts every red check instead.

Full contract: `pr-merge --help`. Exit `75` is volatile: the caller arms one exact head and waits on that head with the orch skill's `queue-wait`, whose `--help` § Verdicts maps each verdict to a route; an unrecognized verdict is never re-armed. With the review-gate skill installed, its watcher output contract is `pr-watch.sh --help`. If `can_merge` is false with no `issues`, read `state`. The thread gate is **Policy, not mechanism.** `--force` and the explicit-user-only `--admin` are its overrides. `--admin-credential` re-checks every condition on the exact head itself — the review gate and every required context among them — dequeues a queued PR, re-runs those gates where a dequeue or disarm actually ran, then merges with the control host's owner credential whose `--admin` bypasses branch protection for that merge alone. GitHub's own review decision is a review gate in every mode, so a base requiring approvals or a code-owner review still refuses until that decision is approved. The reviewer-gate mode of the CHECKOUT it runs in, resolved through the orch skill's `approval-wait --resolve-mode`, decides only what else it reads: `approval` accepts an empty decision only beside a standing approval, `review` also reads the review-gate commit status on that head under the context `REVIEW_GATE_CONTEXT` names, `off` reads nothing else, and a mode it cannot resolve refuses rather than pick one. A ruleset or branch-protection read that does not answer refuses there rather than falling back to an empty required set. The route reads the base's gates under both spellings GitHub enforces, its ruleset rules and its classic branch protection, and refuses on a gate it cannot account for under either, on one that forbids the merge method the route would pass, and on an unresolved thread, outdated included, where the base requires every conversation resolved. The ruleset types it accounts for are `pull_request`, `required_status_checks`, `required_linear_history`, `non_fast_forward`, `creation`, `deletion`, `copilot_code_review` and `merge_queue`; any other type refuses. It also refuses where `ORCH_ADMIN_MERGE_GH_CONFIG_DIR` names no directory.

### PR blocked with no visible conversations

Under `required_conversation_resolution`, an outdated thread can block a merge while the UI shows none; `resolve-thread` reaches it by id.

```bash
github.sh pr-threads 42                  # complete list, outdated included
github.sh resolve-thread PRRT_kwDO...    # resolve by thread id
```

`pr-threads` follows every page and fails rather than returning a partial list, so a thread id absent from its output is genuinely absent. Repeat `resolve-thread` per blocking id until the merge clears.

### Waiting for merge state

**Never gate termination on `gh pr view --json mergeable`.** That field stays `UNKNOWN` permanently after a merge. Use `await-mergeable` (resolution rules and exit codes: `await-mergeable --help`). To watch MANY PRs, do not hand-roll a poll loop keyed on state transitions. Use the review-gate skill's reducer when installed (`.agents/skills/review-gate/scripts/pr-watch.sh`).

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
