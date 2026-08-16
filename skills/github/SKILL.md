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
  version: "2.0.0"
---

# GitHub Queries

> **Problem with this skill?** Run `vstack report` — it files to the owning repo automatically. Do not hand-file.

CLI wrapper for GitHub API operations used in PR workflows. Structured JSON
output, bot account support, configurable issue ID extraction.

```bash
.agents/skills/github/scripts/github.sh <command> [options]
.agents/skills/github/scripts/github.sh -C <path> <command> [options]  # Run in different directory
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
| `pr-merge <N> [--check\|--force\|--auto]` | Merge PR. `--check` reports readiness as JSON without merging; `--auto` queues a currently-blocked PR. Three exit codes, the review-thread gate, and `--force` — see *PR Merge Outcomes*. |
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

Wherever a body is accepted, prefer `--body-file`: an inline `--body` is safe
only for plain strings, and Markdown carrying backticks or code fences needs
the file. `label-add`/`label-remove` also load current-project env when their
command scripts are executed directly rather than through `github.sh`.

Most commands accept no PR number to auto-detect from the current branch.
Exception: `post-reply` with a numeric comment ID never auto-detects — it
requires an explicit `--pr <N>` (thread `PRRT_...` IDs need no PR number).

There is no CI wait command here. Blocking until CI completes is the orch
skill's `.agents/skills/orch/scripts/ci-wait <PR_NUMBER> [interval] [max_wait]
[--json]`. `ci-logs` only fetches failure logs, and `await-mergeable` waits for
merge-state resolution, not check completion.

Unknown flags and extra positionals are rejected rather than absorbed as a PR
reference, so a typo fails naming itself instead of as a missing PR.

### Label application contract

`label-add` verifies the label exists in the live repository inventory, then
writes through GitHub's shared issue/PR label REST endpoint. That endpoint's
response is authoritative for the token's effective `issues=write` /
`pull_requests=write` grant — repository role is not a proxy for it, because App
and fine-grained grants diverge. Label names are sent literally, including names
starting with `@` or resembling booleans, integers, nulls, and placeholders.

- `--required` (default): a missing label is a configuration error (exit 78); a
  label-write denial is a capability error (exit 77). Neither mutates anything.
  Workflow-required QA labels use this, even against a misconfigured repo.
- `--optional`: a missing label or denied permission emits a structured
  `optional_unsupported` result and exits zero without mutating. Use only where
  project policy marks the label non-gating.
- Auth, lookup, rate-limit, and server errors are operational errors in both
  modes — never optional skips.

### Git HTTPS Auth Helper

`git-https-auth [-C path] <git args...>` runs `git` normally, but when the
target repo or an explicit URL uses a GitHub SSH remote and `gh` auth is valid,
it adds per-command config for `gh auth git-credential` and rewrites GitHub SSH
URLs to HTTPS. This covers harnesses where GitHub CLI auth works but no SSH key
or agent is available. It never persists git config.

```bash
.agents/skills/github/scripts/git-https-auth -C . fetch --prune origin
.agents/skills/github/scripts/git-https-auth -C . push -u origin HEAD:refs/heads/my-branch
```

Set `VSTACK_GITHUB_GIT_HTTPS_FALLBACK=never` to disable the fallback, or
`always` to force it.

### Diff Summary Helper

`git-diff-summary [-C path] [base-branch|--staged|--head]` emits JSON with
changed-file domains, scope, insert/delete stats, and `risk_flags` for review
routing. The Rust-specific flags (`unsafe_code_added`, `repr_c_struct_changed`,
`extern_c_changed`, `atomics_modified`) scan added lines in `.rs` diffs only,
so scripts and docs can discuss those tokens without triggering a Rust route.

Panic patterns (`panic!`/`unwrap()`) added to production source emit
`panic_path_added`. The same patterns in a test surface — `#[cfg(test)]`
modules, `tests/` dirs, `*_tests.rs`, or files reachable only through a
`#[cfg(test)]`-gated `mod` declaration in their declaring module, `#[path]`
siblings included — emit the distinct informational `test_panic_path_added`
instead. That flag marks a test assertion rather than a production panic path,
so downstream re-review scoping treats it as non-risk.

### PR Merge Outcomes

`pr-merge` returns three distinct outcomes — branch on the exit code, not on
parsing stderr:

| Exit | Meaning | Stderr line | When |
|------|---------|-------------|------|
| `0`  | MERGED | `MERGED PR #N` | Merge completed immediately |
| `0`  | MERGED | `ALREADY MERGED PR #N <mergedAt>` | PR was merged before the call; nothing attempted |
| `75` | MERGE PENDING | `QUEUED IN MERGE QUEUE PR #N` | A required GitHub merge queue has an active entry |
| `75` | MERGE PENDING | `AUTO-MERGE ENABLED PR #N` | Classic auto-merge is armed until protection clears |
| `1`  | BLOCKED | `BLOCKED PR #N` | Nothing merged, queued, or armed |
| `1`  | BLOCKED | `CLOSED (not merged) PR #N` | PR is closed unmerged; nothing attempted |

A PR that has left `OPEN` is terminal and short-circuits every mode before any
check, auth, or mutation: `mergeable` is permanently `UNKNOWN` after a merge,
and post-merge CI runs and bot comments are not merge blockers. `--check`
reports the same through its `state` field rather than inventing issues.

Merge state is mutated only against the exact resolved head, via
`--match-head-commit`. Queue membership is then read with GraphQL, because
`gh pr view --json` does not expose `mergeQueueEntry`: an `OPEN` PR with no
`autoMergeRequest` is still a successful exit `75` when its required queue
entry is active, and an `OPEN` PR with neither queue nor auto-merge proof fails
closed.

Actionable review threads — unresolved and not outdated — are a hard local
gate. They make `can_merge` false and block both immediate merge and `--auto`
before any mutation. A failed or malformed thread lookup blocks too, since an
unknown review state cannot be treated as clean. Two bounds on that gate:

- **Narrower than branch protection.** GitHub's
  `required_conversation_resolution` requires *all* conversations resolved and
  draws no outdated/active distinction. `pr-merge` counts only threads that are
  unresolved *and* not outdated, because a thread pinned to a diff that no
  longer exists cannot be acted on. Relying on `pr-merge` alone is therefore a
  narrower guarantee than branch protection.
- **Policy, not mechanism.** `pr-merge` gates only merges routed through it. A
  raw `gh pr merge` or the GitHub UI Merge button bypasses the skill entirely.

`--force` is the only deliberate override and skips every check. It is
immediate-only, cannot be combined with `--auto` (the pair fails before any
GitHub lookup), and stays BLOCKED when its mutation fails and the exact-head
post-state is not `MERGED` — deferred state predating the call is not proof
that a forced immediate attempt succeeded.

BLOCKED is classified on stderr as **transient** (mergeable UNKNOWN,
`ci_pending`, CI fetch uncertainty — `await-mergeable` then retry) or
**permanent** (conflicts, `ci_failed`, `changes_requested` — fix and re-push).
Callers read the `transient` field from `--check`:

```json
{"can_merge": true, "issues": [], "warnings": [], "mergeable": "MERGEABLE", "review": "APPROVED", "transient": false, "state": "OPEN"}
```

`state` is the PR's lifecycle state (`OPEN`, `MERGED`, `CLOSED`, `UNKNOWN`).
`can_merge: false` with an empty `issues` array means the PR is terminal — read
`state` before treating a refusal as a blocker to clear.

`transient: true` means every blocking issue is recoverable by waiting
(prefixes `unknown:`, `ci_pending:`, `ci_unconfigured:`, `ci_fetch_failed:`).
Still-running checks report as `ci_pending:`; terminal failing or cancelled
checks remain `ci_failed:`.

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
`UNKNOWN` permanently after a merge — it is meaningful only while the PR is
open. An inline `until [ "$(...mergeable...)" != "UNKNOWN" ]` loop never
terminates post-merge. Use `await-mergeable`, which polls `state` and
`mergeStateStatus`:

```bash
github.sh await-mergeable 42                    # block until resolved
STATE=$(github.sh await-mergeable 42 | jq -r '.state')   # capture for branching
```

It resolves when `state` is `MERGED`/`CLOSED`, or `mergeStateStatus` is
anything but `UNKNOWN`.

To watch MANY PRs, do not hand-roll a poll loop keyed on state transitions —
steady states transition nothing and the watcher sleeps through them. Use the
review-gate skill's reducer when installed
(`.agents/skills/review-gate/scripts/pr-watch.sh`); its contract is documented
there. Without it, per-PR polling cannot detect a stale gate.

## Output Formats

`--format` is command-specific, not a global flag. Commands not listed below
(e.g. `pr-view`, which takes only `--json FIELDS`) reject it. An unrecognized
format value is an error rather than a silent fallback to `safe`.

| Format | Description | Commands |
|--------|-------------|----------|
| `safe` | DEFAULT. Flat, normalized JSON | pr-data, pr-threads, pr-list-ready, pr-list-failing, pr-issue, ci-logs, bot-token |
| `raw` | Original API structure | pr-data, pr-threads |
| `text` | Plain text extraction | pr-issue, ci-logs, bot-token |
| `table` | Human-readable table | pr-list-ready, pr-list-failing |

`--json` is accepted as an alias for `--format=safe` on pr-list-ready, pr-list-failing, pr-issue, ci-logs, and bot-token; pr-data and pr-threads take `--format=safe|raw` only and reject unknown flags.

## Configuration

| Variable | Purpose | Default |
|----------|---------|---------|
| `GH_TOKEN` / `GITHUB_TOKEN` | Pre-resolved GitHub token from the parent process | Falls back to `gh` auth |
| `GH_BOT_TOKEN` | Bot account GitHub token (in `.env.local` or parent env) | Falls back to `GH_TOKEN` / `GITHUB_TOKEN`, then `gh` auth |
| `GH_BOT_USERNAME` | Bot username for review/comment filtering | `review-bot[bot]` |
| `GH_ISSUE_PATTERN` | Regex for issue ID extraction from branches | `[A-Z]+-[0-9]+` |
| `GH_VERIFY_CMD` | Overrides build/test detection in `pr-cross-check --verify` | auto-detect |
| `VSTACK_GITHUB_OP_TIMEOUT` | Seconds to wait for `op read` when resolving token references | `10` |
| `VSTACK_GITHUB_AUTH_TIMEOUT` | Seconds to wait for GitHub auth preflight in `pr-view` | `10` |
| `VSTACK_GITHUB_PR_VIEW_TIMEOUT` | Seconds to wait for `gh pr view` in `pr-view` | `30` |
| `VSTACK_GITHUB_GIT_HTTPS_FALLBACK` | `auto`, `never`, or `always` for `git-https-auth` SSH→HTTPS fallback | `auto` |

Tokens may be literal (`ghp_*`, `gho_*`, `ghu_*`, `ghs_*`, `ghr_*`,
`github_pat_*`) or 1Password references (`op://vault/item/field`). Keep them in
`.env.local`; non-secret defaults belong in committed `vstack.settings.toml`
under `[env]`.

Parent-process values win over project files. `github.sh` then selects ONE
router token before resolving any `op://` reference — resolved `GH_TOKEN`, then
`GH_BOT_TOKEN`, then `GITHUB_TOKEN`, falling back to `op://` references in that
same order — and runs `op read` for that single selection only. An unresolvable
selection drops `GH_TOKEN`/`GITHUB_TOKEN` so `gh` uses keyring auth; a selected
`GH_BOT_TOKEN` keeps its bot identity instead. Auth preflight validates env
tokens with `gh api user`, and `gh auth status` is authoritative only when no
env token is selected.

### `pr-view` failure contract

`pr-view --json ...` returns normal `gh pr view` JSON on success. On failure it
prints structured JSON to stdout and exits nonzero:

```json
{"status":"no_pr","error":"No pull request found for the current branch","detail":"...","exit_code":1,"number":null}
```

`status` is one of `no_pr`, `auth_error`, `token_resolution_failed`,
`token_resolution_timeout`, `token_resolution_unavailable`, `auth_timeout`,
`gh_timeout`, `gh_error`. Raw `gh`/`op` detail also goes to stderr, so callers
can separate no-PR, auth, token-resolution, and timeout cases without hanging.

## Error Handling

- Most commands emit `{"error": "message"}` on stderr and exit 1.
- `pr-view --json ...` emits structured failure JSON on stdout so callers can
  branch on `status` without losing raw stderr detail.
- Rate limits retry automatically (3 attempts, exponential backoff).
- A dependency failure never degrades into an empty-but-successful result: an
  unreadable thread list, comment list, or CI log is reported as a failure, not
  as "none found".

## Troubleshooting

**`Expected VAR_SIGN, actual: UNKNOWN_CHAR`**: use a multi-line GraphQL query
with `-F` variables — `$` in a single-line query hits shell escaping.

**`bad credentials` / `HTTP 401` while `gh auth status` looks healthy**: a
stale `GH_TOKEN`/`GITHUB_TOKEN` masks keyring credentials, since `gh` prefers
the env var. Check `env | grep -E '^(GH_TOKEN|GITHUB_TOKEN)='`, then clear
BOTH for the call — clearing one is not enough:

```bash
env -u GH_TOKEN -u GITHUB_TOKEN gh pr list
```

`github.sh` does this automatically when the selected env token fails and
keyring auth succeeds.

## Dependencies

- `gh` CLI (authenticated)
- `jq`
- `op` CLI (optional, 1Password token references)
