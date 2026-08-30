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

# GitHub Queries

> **Problem with this skill?** Run `kendex report` — it files to the owning repo automatically. Do not hand-file.

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

Unknown flags and extra positionals are rejected.

### Label application contract

Workflow-required QA labels use `--required` (the default), even against a
misconfigured repo; use `--optional` only where project policy marks the
label non-gating. Mode semantics, exit codes, and the error classes that are
never optional skips: `label-add --help`.

### Git HTTPS Auth Helper

`git-https-auth [-C path] <git args...>` runs `git` normally, but when the
target repo or an explicit URL uses a GitHub SSH remote and `gh` auth is valid,
it adds per-command config for `gh auth git-credential` and rewrites GitHub SSH
URLs to HTTPS. It never persists git config.

```bash
.agents/skills/github/scripts/git-https-auth -C . fetch --prune origin
.agents/skills/github/scripts/git-https-auth -C . push -u origin HEAD:refs/heads/my-branch
```

Set `KENDEX_GITHUB_GIT_HTTPS_FALLBACK=never` to disable the fallback, or
`always` to force it.

### Diff Summary Helper

`git-diff-summary [-C path] [base-branch|--staged|--head]` emits JSON with
changed-file domains, scope, insert/delete stats, and `risk_flags` for review
routing. The flag definitions — including which `test_panic_path_added`
surfaces are informational rather than risk — are in `git-diff-summary --help`.

### PR Merge Outcomes

`pr-merge` returns three distinct outcomes — branch on the exit code, not on
parsing stderr:

| Exit | Meaning | Stderr line | When |
|------|---------|-------------|------|
| `0`  | MERGED | `MERGED PR #N` | Merge completed immediately |
| `0`  | MERGED | `ALREADY MERGED PR #N <mergedAt>` | PR was merged before the call; nothing attempted |
| `75` | MERGE PENDING (volatile) | `QUEUED IN MERGE QUEUE PR #N` | A required GitHub merge queue has an active entry — launch the prepared durable lifecycle before returning |
| `75` | MERGE PENDING (volatile) | `AUTO-MERGE ENABLED PR #N` | Classic auto-merge is armed until protection clears — launch the prepared durable lifecycle before returning |
| `1`  | BLOCKED | `BLOCKED PR #N` | Nothing merged, queued, or armed |
| `1`  | BLOCKED | `CLOSED (not merged) PR #N` | PR is closed unmerged; nothing attempted |

Exit `75` is not a resting state: an ejection or a failed protection check
disarms it silently. The caller prepares and launches
`.agents/skills/orch/scripts/merge-queue-watch`, which binds the repository,
PR, expected head, and watch generation before arming. Its one-shot worker writes a durable verdict and claims one recovery action. The review-gate reducer can still report fleet attention.
Verdict routing is in README.md § Exit 75 recovery; re-arm only through
`.agents/skills/github/scripts/github.sh pr-merge <N> --auto` after that route.
`await-mergeable` is not that watcher — it returns as soon as GitHub computes a merge state.

A PR that has left `OPEN` is terminal and short-circuits every mode before any
check, auth, or mutation. `--check` reports it through its `state` field.

Merge state is mutated only against the exact resolved head, via
`--match-head-commit`. Queue membership is read with GraphQL: an `OPEN` PR
with no `autoMergeRequest` is still a successful exit `75` when its required queue
entry is active, and an `OPEN` PR with neither queue nor auto-merge proof fails
closed.

Actionable review threads — unresolved and not outdated — are a hard local
gate. They make `can_merge` false and block both immediate merge and `--auto`
before any mutation. A failed or malformed thread lookup blocks too. Two
bounds on that gate:

- **Narrower than branch protection.** GitHub's
  `required_conversation_resolution` requires *all* conversations resolved and
  draws no outdated/active distinction. `pr-merge` counts only threads that are
  unresolved *and* not outdated. Relying on `pr-merge` alone is a narrower
  guarantee than branch protection.
- **Policy, not mechanism.** `pr-merge` gates only merges routed through it. A
  raw `gh pr merge` or the GitHub UI Merge button bypasses the skill entirely.

`--force` is the only deliberate override and skips every check. It is
immediate-only, cannot be combined with `--auto` (the pair fails before any
GitHub lookup), and stays BLOCKED when its mutation fails and the exact-head
post-state is not `MERGED`.

BLOCKED is classified on stderr as **transient** (mergeable UNKNOWN,
`ci_pending`, CI fetch uncertainty — `await-mergeable` then retry) or
**permanent** (conflicts, `ci_failed`, `changes_requested` — fix and re-push).
Callers read the `transient` field from `--check`:

```json
{"can_merge": true, "issues": [], "warnings": [], "mergeable": "MERGEABLE", "review": "APPROVED", "transient": false, "state": "OPEN", "merged_at": "", "head_runs": [17234567890], "checks": [{"name": "Cargo", "state": "SUCCESS", "bucket": "pass", "workflow": "CI", "link": "https://github.com/owner/repo/actions/runs/17234567890/job/1", "startedAt": "…"}]}
```

`state` is the PR's lifecycle state (`OPEN`, `MERGED`, `CLOSED`, `UNKNOWN`), and
`merged_at` carries the merge timestamp when that state is `MERGED`.
`can_merge: false` with an empty `issues` array means the PR is terminal — read
`state` before treating a refusal as a blocker to clear. `head_runs` lists the
run ids the CI classification was scoped to (the authoritative run per
workflow plus the runs custom commit statuses link to — a mixed head names
both); `--check` repeats them on stderr as `head-run: <ids>` under the
one-word verdict (`mergeable`, `blocked`, `merged`, `closed`). `checks` is the
raw rollup that classification read. To turn a refusal into a named cause —
including which failing checks are run-correlated to the authoritative run and
which runs were superseded — run `ci-classify-refusal <N>`; it scopes the
`checks` snapshot embedded in the `--check` JSON rather than refetching, so
its detail lines and the verdict describe one fetch.

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
`UNKNOWN` permanently after a merge. Use `await-mergeable` (resolution rules
and exit codes: `await-mergeable --help`). To watch MANY PRs, do not
hand-roll a poll loop keyed on state transitions — use the review-gate
skill's reducer when installed
(`.agents/skills/review-gate/scripts/pr-watch.sh`).

## Output Formats

`--format` is command-specific, not a global flag; the per-command modes, the
`--json` alias, and the reject-unknown rules are in `github.sh --help`.

## Configuration

| Variable | Purpose | Default |
|----------|---------|---------|
| `GH_TOKEN` / `GITHUB_TOKEN` | Pre-resolved GitHub token from the parent process | Falls back to `gh` auth |
| `GH_BOT_TOKEN` | Bot account GitHub token (in `.env.local` or parent env) | Falls back to `GH_TOKEN` / `GITHUB_TOKEN`, then `gh` auth |
| `GH_BOT_USERNAME` | Bot username for review/comment filtering | `review-bot[bot]` |
| `GH_ISSUE_PATTERN` | Regex for issue ID extraction from branches | `[A-Z]+-[0-9]+` |
| `GH_VERIFY_CMD` | Overrides build/test detection in `pr-cross-check --verify` | auto-detect |
| `KENDEX_GITHUB_OP_TIMEOUT` | Seconds to wait for `op read` when resolving token references | `10` |
| `KENDEX_GITHUB_AUTH_TIMEOUT` | Seconds to wait for GitHub auth preflight in `pr-view` | `10` |
| `KENDEX_GITHUB_PR_VIEW_TIMEOUT` | Seconds to wait for `gh pr view` in `pr-view` | `30` |
| `KENDEX_GITHUB_GIT_HTTPS_FALLBACK` | `auto`, `never`, or `always` for `git-https-auth` SSH→HTTPS fallback | `auto` |

Tokens may be literal (`ghp_*`, `gho_*`, `ghu_*`, `ghs_*`, `ghr_*`,
`github_pat_*`) or 1Password references (`op://vault/item/field`). Keep them in
`.env.local`; non-secret defaults belong in committed `kendex.settings.toml`
under `[env]`.

Parent-process values win over project files. `github.sh` then selects ONE
router token before resolving any `op://` reference — resolved `GH_TOKEN`, then
`GH_BOT_TOKEN`, then `GITHUB_TOKEN`, falling back to `op://` references in that
same order — and runs `op read` for that single selection only. An unresolvable
selection drops `GH_TOKEN`/`GITHUB_TOKEN` so `gh` uses keyring auth; a selected
`GH_BOT_TOKEN` keeps its bot identity instead. Auth preflight validates env
tokens with `gh api user`, and `gh auth status` is authoritative only when no
env token is selected.

## Error Handling

- Most commands emit `{"error": "message"}` on stderr and exit 1.
- `pr-view --json ...` emits structured failure JSON on stdout (the `status`
  values and shape: `pr-view --help`).
- Rate limits retry automatically (3 attempts, exponential backoff).
- An unreadable thread list, comment list, or CI log is reported as a failure,
  never as "none found".

## Troubleshooting

**`Expected VAR_SIGN, actual: UNKNOWN_CHAR`**: use a multi-line GraphQL query
with `-F` variables — `$` in a single-line query hits shell escaping.

**`bad credentials` / `HTTP 401` while `gh auth status` looks healthy**: a
stale `GH_TOKEN`/`GITHUB_TOKEN` masks keyring credentials. Check
`env | grep -E '^(GH_TOKEN|GITHUB_TOKEN)='`, then clear BOTH for the call:

```bash
env -u GH_TOKEN -u GITHUB_TOKEN gh pr list
```

`github.sh` does this automatically when the selected env token fails and
keyring auth succeeds.

## Dependencies

- `gh` CLI (authenticated)
- `jq`
- `op` CLI (optional, 1Password token references)
