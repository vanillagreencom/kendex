---
name: github
description: "GitHub API CLI for PR operations: threads, comments, reviews, CI logs, merging, and cross-PR analysis."
license: MIT
user-invocable: true
metadata:
  author: vanillagreen
  source: vstack
  repository: "https://github.com/vanillagreencom/vstack"
  bugs: "https://github.com/vanillagreencom/vstack/issues"
  version: "1.0.0"
---

# GitHub Queries

CLI wrapper for GitHub API operations used in PR workflows. Provides structured JSON output, bot account support, and configurable issue ID extraction.

```bash
.agents/skills/github/scripts/github.sh <command> [options]
.agents/skills/github/scripts/github.sh -C <path> <command> [options]  # Run in different directory
```

## Commands

| Command | Purpose |
|---------|---------|
| `pr-data <N> [--actionable]` | Get PR with threads, comments, files. `--actionable`: unresolved non-outdated only. |
| `pr-view [N] [--json FIELDS]` | View PR details (wraps gh pr view with bounded auth/no-PR errors) |
| `pr-threads <N> [--unresolved]` | Get thread list/count |
| `pr-review-status <N> [--baseline-ts TS --baseline-threads N]` | Check review state, determine if action needed |
| `pr-list-ready [--all] [--format=safe\|table]` | List PRs ready for merge |
| `pr-list-failing [--all] [--format=safe\|table]` | List PRs with CI failures |
| `pr-create [--title T] [--body B \| --body-file PATH] [--draft] [--dry-run] [--force]` | Create PR as bot. Safety checks: not main, has commits, pushed. Prefer `--body-file` for Markdown with backticks/code fences; `--body` is safe only for plain strings. `--force` skips checks. |
| `pr-edit-body <N> --body-file PATH` | Update an existing PR body through the sanitized router. |
| `pr-merge <N> [--check\|--force\|--auto]` | Merge PR. `--check`: JSON readiness only. `--auto`: queue for auto-merge if blocked now. Three exit codes — see below. |
| `pr-cross-check [N...] [--quick\|--verify]` | Cross-PR analysis. `--verify`: full build+test (auto-detects build system). |
| `pr-issue <N> [--format=safe\|text]` | Extract issue ID from PR branch (configurable via `GH_ISSUE_PATTERN`) |
| `label-add <PR-or-issue> <label> [--reason TEXT] [--issue] [--required\|--optional]` | Check the live label inventory, then add a label through an authoritative REST capability boundary; direct script execution also loads current-project env. |
| `label-remove <PR-or-issue> <label> [--reason TEXT] [--issue]` | Remove a label through the sanitized router; direct script execution also loads current-project env. |
| `await-mergeable <N> [--interval S] [--max-iter N] [--quiet]` | Block until GitHub resolves a PR's merge state. Polls `state` + `mergeStateStatus`. Exit 0 + JSON on resolve, 124 on timeout. |
| `ci-logs <N> [--lines N] [--format=safe\|text]` | Get CI failure logs for PR |
| `bot-token [--format=safe\|text]` | Check if bot token is configured |
| `dismiss-review <PR> [--bot\|--user NAME] [--message M]` | Dismiss blocking review |
| `resolve-thread <PRRT_...>` | Mark thread(s) resolved |
| `unresolve-thread <PRRT_...>` | Reopen thread(s) |
| `post-reply <PRRT_...\|numeric-id> [body \| --body-file PATH] [--pr N]` | Reply to review comment. `--pr N` is REQUIRED for numeric comment IDs; thread `PRRT_...` IDs need no PR number. Prefer `--body-file` for Markdown with backticks; inline body is safe only for plain strings. |
| `post-comment <PR> [body \| --body-file PATH]` | Post PR-level comment. Same body-file preference as `post-reply`. |
| `find-comment <PR> --pattern <regex>` | Find comment by pattern/author |
| `edit-comment <id> [body \| --body-file PATH]` | Edit existing comment. Same body-file preference as `post-reply`. |
| `sticky-comment <PR> [--verdict\|--analysis\|--body]` | Get bot sticky comment. `--verdict`: quick pass/fail. `--analysis`: deep recommendation. |

Most commands accept no PR number to auto-detect from the current branch.
Exception: `post-reply` with a numeric comment ID never auto-detects — it
requires an explicit `--pr <N>` (thread `PRRT_...` IDs need no PR number).

### Label application contract

`label-add` checks that the named label exists in the live repository inventory,
resolves the target, and then uses GitHub's shared issue/PR label REST endpoint.
The endpoint response is authoritative for the selected token's effective
`issues=write` or `pull_requests=write` grant; repository roles are not used as
a proxy because GitHub App and fine-grained token grants can differ from them.
Label names are sent as literal strings, including names beginning with `@` or
resembling booleans, integers, nulls, and repository placeholders.

- `--required` is the default. A missing label is a repository configuration
  error (exit 78); a known GitHub label-write denial is a capability error
  (exit 77). Neither failure successfully mutates the PR or issue.
- `--optional` is only for labels the calling project policy explicitly marks
  non-gating. A missing label or insufficient permission emits a structured
  `optional_unsupported` result, exits zero, and does not mutate the target.
- Authentication, repository/target lookup, rate limits, server errors, and
  unexpected API failures are operational errors in both modes; they never
  become optional skips.

Workflow-required QA labels must use `--required`. Do not downgrade a required
label to `--optional` merely because a consuming repository is misconfigured.

### Git HTTPS Auth Helper

`git-https-auth [-C path] <git args...>` runs `git` normally, but when the
target repo or explicit URL uses a GitHub SSH remote and `gh` auth is valid, it
adds per-command config for `gh auth git-credential` and rewrites GitHub SSH
URLs to HTTPS. This covers Codex and other harnesses where GitHub CLI auth is
valid but an SSH key or agent is unavailable. It never persists git config.

Use it for workflow network operations that only need `origin`, for example:

```bash
.agents/skills/github/scripts/git-https-auth -C . fetch --prune origin
.agents/skills/github/scripts/git-https-auth -C . push -u origin HEAD:refs/heads/my-branch
```

Set `VSTACK_GITHUB_GIT_HTTPS_FALLBACK=never` to disable the fallback, or
`always` to force the temporary config for a GitHub operation.

### Diff Summary Helper

`git-diff-summary [-C path] [base-branch|--staged|--head]` is a standalone
review-routing helper that emits JSON with changed-file domains, scope,
insert/delete stats, and `risk_flags`. Rust-specific flags
(`unsafe_code_added`, `repr_c_struct_changed`, `extern_c_changed`,
`atomics_modified`) scan added lines from `.rs` diffs only, so scripts,
docs, and other non-Rust files can discuss those tokens without triggering a
Rust risk route.

### PR Merge Outcomes

`pr-merge` returns three distinct outcomes — branch on the exit code, not on
parsing stderr:

| Exit | Meaning | Stderr line | When |
|------|---------|-------------|------|
| `0`  | MERGED | `MERGED PR #N` | Merge completed immediately |
| `75` | MERGE PENDING | `QUEUED IN MERGE QUEUE PR #N` | A required GitHub merge queue has an active entry |
| `75` | MERGE PENDING | `AUTO-MERGE ENABLED PR #N` | Classic auto-merge is armed until protection clears |
| `1`  | BLOCKED | `BLOCKED PR #N` | Nothing merged, queued, or armed |

Before mutating merge state, `pr-merge` resolves the exact PR head and passes
it through `--match-head-commit`. After a successful `gh` call it reads queue
membership with GraphQL because `gh pr view --json` does not expose
`mergeQueueEntry`. An `OPEN` PR with no `autoMergeRequest` is therefore still a
successful exit `75` when its required merge-queue entry is active; an `OPEN`
PR with neither queue nor auto-merge proof fails closed.

A BLOCKED outcome is further classified on stderr as **transient** (mergeable
UNKNOWN, `ci_pending`, CI fetch uncertainty — caller should
`await-mergeable` and retry) or **permanent** (conflicts, `ci_failed`,
`changes_requested` — caller must fix and re-push). Programmatic callers can
check the `transient` field in the `--check` JSON output before deciding to
retry.

### PR Merge Check Output

```json
{"can_merge": true, "issues": [], "warnings": [], "mergeable": "MERGEABLE", "review": "APPROVED", "transient": false}
```

`transient: true` means every blocking issue is recoverable by waiting
(prefixes `unknown:`, `ci_pending:`, `ci_unconfigured:`,
`ci_fetch_failed:`). Still-running checks are reported as `ci_pending: ...`;
terminal failing or cancelled checks remain `ci_failed: ...`.

### Waiting for merge state (gotcha)

**Never gate termination on `gh pr view --json mergeable`.** That field stays
`UNKNOWN` permanently after a PR is merged — it is only meaningful while the
PR is open, where it transitions through `MERGEABLE` / `CONFLICTING` /
`UNKNOWN`. An inline `until [ "$(...mergeable...)" != "UNKNOWN" ]` loop will
never terminate post-merge.

To wait for resolution, use `await-mergeable`, which polls `state` and
`mergeStateStatus` correctly:

```bash
github.sh await-mergeable 42                    # block until resolved
STATE=$(github.sh await-mergeable 42 | jq -r '.state')   # capture for branching
```

Resolution rules:
- `state in {MERGED, CLOSED}` → resolved.
- `mergeStateStatus != UNKNOWN` (any of `CLEAN`, `BLOCKED`, `BEHIND`, `DIRTY`,
  `UNSTABLE`, `HAS_HOOKS`) → resolved.
- `mergeable` alone is never used for termination.

## Output Formats

`--format` is command-specific, not a global flag. Only the commands listed
below accept it; others (e.g. `pr-view`, which takes only `--json FIELDS`) do not.

| Format | Description | Commands |
|--------|-------------|----------|
| `safe` | DEFAULT. Flat, normalized JSON | pr-data, pr-threads, pr-list-ready, pr-list-failing, pr-issue, ci-logs, bot-token |
| `raw` | Original API structure | pr-data, pr-threads |
| `text` | Plain text extraction | pr-issue, ci-logs, bot-token |
| `table` | Human-readable table | pr-list-ready, pr-list-failing |

`--json` is accepted as alias for `--format=safe` on the commands above.

## Configuration

| Variable | Purpose | Default |
|----------|---------|---------|
| `GH_TOKEN` / `GITHUB_TOKEN` | Pre-resolved GitHub token from the parent process | Falls back to `gh` auth |
| `GH_BOT_TOKEN` | Bot account GitHub token (in `.env.local` or parent env) | Falls back to `GH_TOKEN` / `GITHUB_TOKEN` for helper auth, then `gh` auth |
| `GH_BOT_USERNAME` | Bot username for review/comment filtering | `review-bot[bot]` |
| `GH_ISSUE_PATTERN` | Regex for issue ID extraction from branches | `[A-Z]+-[0-9]+` |
| `VSTACK_GITHUB_OP_TIMEOUT` | Seconds to wait for `op read` when resolving GitHub token references | `10` |
| `VSTACK_GITHUB_AUTH_TIMEOUT` | Seconds to wait for GitHub auth preflight in `pr-view` | `10` |
| `VSTACK_GITHUB_PR_VIEW_TIMEOUT` | Seconds to wait for `gh pr view` in `pr-view` | `30` |
| `VSTACK_GITHUB_GIT_HTTPS_FALLBACK` | `auto`, `never`, or `always` for `git-https-auth` SSH→HTTPS fallback | `auto` |

Bot token supports direct tokens (`ghp_*`, `gho_*`, `ghu_*`, `ghs_*`, `ghr_*`, `github_pat_*`) and 1Password references (`op://vault/item/field`).

Non-secret GitHub defaults can live in committed `vstack.settings.toml` under `[env]`. Keep tokens in `.env.local` unless the parent process injects already-resolved values. GitHub helpers preserve parent-process values over project files for the same variable. `github.sh` then selects one effective router token before resolving 1Password references: first resolved `GH_TOKEN`, then resolved `GH_BOT_TOKEN`, then resolved `GITHUB_TOKEN`; only if no resolved token exists does it consider unresolved `op://` references in that same order. `op read` runs only for that final selected reference. If the selected `op://` reference cannot resolve, `github.sh` drops `GH_TOKEN`/`GITHUB_TOKEN` so `gh` can use keyring auth. Once a resolved `GH_BOT_TOKEN` is selected, helpers preserve that bot identity instead of replacing it with ambient keyring auth. Auth preflight validates selected env tokens with `gh api user`; `gh auth status` is only authoritative for keyring auth when no env token is selected. Bot-token operations still prefer an explicit `GH_BOT_TOKEN` over user-token variables.

### `pr-view` failure contract

`pr-view --json ...` returns normal `gh pr view` JSON on success. On failure it
prints structured JSON to stdout and exits nonzero:

```json
{"status":"no_pr","error":"No pull request found for the current branch","detail":"...","exit_code":1,"number":null}
```

Known `status` values are `no_pr`, `auth_error`, `token_resolution_failed`,
`token_resolution_timeout`, `token_resolution_unavailable`, `auth_timeout`,
`gh_timeout`, and `gh_error`. Raw `gh`/`op` detail is also echoed to stderr so
callers can distinguish no-PR, authentication, token resolution, and timeout
cases without hanging.

## Error Handling

- Most commands return `{"error": "message"}` on stderr with exit code 1
- `pr-view --json ...` returns structured failure JSON on stdout so callers can
  branch on `status` without losing raw stderr detail
- Automatic retry on rate limiting (3 attempts with backoff)
- NOT_FOUND errors return clean `{"error": "Not found"}`

## Troubleshooting

**`Expected VAR_SIGN, actual: UNKNOWN_CHAR`**: Use multi-line GraphQL + `-F` for variables (shell escaping issue with `$` in single-line queries).

**`gh` says `bad credentials` / `HTTP 401` even though `gh auth status` is healthy**: A stale or wrong-account `GH_TOKEN` / `GITHUB_TOKEN` in the environment masks the keyring/`gh auth login` credentials — `gh` prefers the env var. This happens often when a bot token was exported for one command in a parent shell and is still active. Verify:

```bash
# Are env tokens leaking into this shell?
env | grep -E '^(GH_TOKEN|GITHUB_TOKEN)='

# Inspect what gh resolves:
gh auth status
```

If an unwanted token is set, prefer scoping both variables down for a single call (`gh` honours `GH_TOKEN` then `GITHUB_TOKEN` in order, so clearing only one is not enough):

```bash
# Single-call scoping — clears both for this one invocation only.
env -u GH_TOKEN -u GITHUB_TOKEN gh pr list
# Or, equivalently:
GH_TOKEN= GITHUB_TOKEN= gh pr list
```

For the rest of the shell: `unset GH_TOKEN GITHUB_TOKEN`. `github.sh` performs this fallback automatically when the selected env token fails but keyring auth succeeds, and it also drops unresolved `op://` env tokens after a failed bounded `op read`. The `pr-create` wrapper above intentionally sets `GH_TOKEN="$token"` only for its one subprocess; it does not export it into the parent shell.

## Dependencies

- `gh` CLI (authenticated)
- `jq`
- `op` CLI (optional, 1Password token references)
