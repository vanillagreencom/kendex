---
name: github
description: "GitHub API CLI for PR operations: threads, comments, reviews, CI logs, merging, and cross-PR analysis."
license: MIT
user-invocable: true
metadata:
  author: vanillagreen
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
| `pr-merge <N> [--check\|--force\|--auto]` | Merge PR. `--check`: JSON readiness only. `--auto`: queue for auto-merge if blocked now. Three exit codes — see below. |
| `pr-cross-check [N...] [--quick\|--verify]` | Cross-PR analysis. `--verify`: full build+test (auto-detects build system). |
| `pr-issue <N> [--format=safe\|text]` | Extract issue ID from PR branch (configurable via `GH_ISSUE_PATTERN`) |
| `await-mergeable <N> [--interval S] [--max-iter N] [--quiet]` | Block until GitHub resolves a PR's merge state. Polls `state` + `mergeStateStatus`. Exit 0 + JSON on resolve, 124 on timeout. |
| `ci-logs <N> [--lines N] [--format=safe\|text]` | Get CI failure logs for PR |
| `bot-token [--format=safe\|text]` | Check if bot token is configured |
| `dismiss-review <PR> [--bot\|--user NAME] [--message M]` | Dismiss blocking review |
| `resolve-thread <PRRT_...>` | Mark thread(s) resolved |
| `unresolve-thread <PRRT_...>` | Reopen thread(s) |
| `post-reply <id> [body \| --body-file PATH]` | Reply to review comment. Prefer `--body-file` for Markdown with backticks; inline body is safe only for plain strings. |
| `post-comment <PR> [body \| --body-file PATH]` | Post PR-level comment. Same body-file preference as `post-reply`. |
| `find-comment <PR> --pattern <regex>` | Find comment by pattern/author |
| `edit-comment <id> [body \| --body-file PATH]` | Edit existing comment. Same body-file preference as `post-reply`. |
| `sticky-comment <PR> [--verdict\|--analysis\|--body]` | Get bot sticky comment. `--verdict`: quick pass/fail. `--analysis`: deep recommendation. |

Most commands accept no PR number to auto-detect from the current branch.

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
| `0`  | MERGED                | `MERGED PR #N`               | Merge completed immediately |
| `75` | QUEUED FOR AUTO-MERGE | `QUEUED FOR AUTO-MERGE PR #N`| `--auto` enabled GitHub auto-merge; fires when CI + branch protection clear |
| `1`  | BLOCKED               | `BLOCKED PR #N`              | Checks failed; nothing merged, nothing queued |

A BLOCKED outcome is further classified on stderr as **transient** (mergeable
UNKNOWN, CI pending — caller should `await-mergeable` and retry) or
**permanent** (conflicts, ci_failed, changes_requested — caller must fix and
re-push). Programmatic callers can check the `transient` field in the
`--check` JSON output before deciding to retry.

### PR Merge Check Output

```json
{"can_merge": true, "issues": [], "warnings": [], "mergeable": "MERGEABLE", "review": "APPROVED", "transient": false}
```

`transient: true` means every blocking issue is recoverable by waiting
(prefixes `unknown:`, `ci_unconfigured:`, `ci_fetch_failed:`).

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

| Format | Description | Commands |
|--------|-------------|----------|
| `safe` | DEFAULT. Flat, normalized JSON | All |
| `raw` | Original API structure | pr-data, pr-threads |
| `text` | Plain text extraction | pr-issue, ci-logs, bot-token |
| `table` | Human-readable table | pr-list-ready, pr-list-failing |

`--json` is accepted as alias for `--format=safe`.

## Configuration

| Variable | Purpose | Default |
|----------|---------|---------|
| `GH_TOKEN` / `GITHUB_TOKEN` | Pre-resolved GitHub token from the parent process | Falls back to `gh` auth |
| `GH_BOT_TOKEN` | Bot account GitHub token (in `.env.local` or parent env) | Falls back to `GH_TOKEN` / `GITHUB_TOKEN` for helper auth, then `gh` auth |
| `GH_BOT_USERNAME` | Bot username for review/comment filtering | `review-bot[bot]` |
| `GH_ISSUE_PATTERN` | Regex for issue ID extraction from branches | `[A-Z]+-[0-9]+` |
| `VSTACK_GITHUB_OP_TIMEOUT` | Seconds to wait for `op read` when resolving `GH_BOT_TOKEN` | `10` |
| `VSTACK_GITHUB_AUTH_TIMEOUT` | Seconds to wait for `gh auth status` in `pr-view` | `10` |
| `VSTACK_GITHUB_PR_VIEW_TIMEOUT` | Seconds to wait for `gh pr view` in `pr-view` | `30` |

Bot token supports direct tokens (`ghp_*`, `gho_*`, `ghs_*`, `ghr_*`, `github_pat_*`) and 1Password references (`op://vault/item/field`).

Non-secret GitHub defaults can live in committed `vstack.settings.toml` under `[env]`. Keep tokens in `.env.local` unless the parent process injects already-resolved values. GitHub helpers are env-first: resolved `GH_TOKEN`, `GITHUB_TOKEN`, or `GH_BOT_TOKEN` values are used before project files are read, and `op read` runs only when the final selected value is still an `op://` reference. Bot-token operations still prefer an explicit `GH_BOT_TOKEN` over user-token variables.

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

For the rest of the shell: `unset GH_TOKEN GITHUB_TOKEN`. The `pr-create` wrapper above intentionally sets `GH_TOKEN="$token"` only for its one subprocess; it does not export it into the parent shell.

## Dependencies

- `gh` CLI (authenticated)
- `jq`
- `op` CLI (optional, 1Password token references)
