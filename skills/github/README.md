# GitHub Queries

A CLI wrapper over the GitHub API for pull-request work: reading PR data,
threads and reviews; posting comments and replies; adding and removing labels;
fetching CI failure logs; gating and performing merges; and comparing several
PRs before a batch merge.

Every command prints JSON by default, so output can be piped straight into
`jq`. `SKILL.md` is the full command reference; `DEVELOPMENT.md` covers
internals.

## Setup

1. Authenticate: `gh auth login`
2. For bot-account operations, set `GH_BOT_TOKEN` in `.env.local`
3. For shared non-secret defaults, use `vstack.settings.toml` under `[env]`

Requires `gh` and `jq`. `op` is only needed if a token is a 1Password
reference.

## Usage

```bash
./scripts/github.sh pr-view 123 --json number,title,state
./scripts/github.sh pr-threads 123 --unresolved
./scripts/github.sh pr-merge 123 --check
./scripts/github.sh label-add 123 needs-review --required
./scripts/git-https-auth -C . fetch --prune origin
```

Run `./scripts/github.sh --help` for the command list, or
`./scripts/github.sh <command> --help` for one command's options.

## Configuration

| Variable | Purpose | Default |
|----------|---------|---------|
| `GH_TOKEN` / `GITHUB_TOKEN` | Pre-resolved token from the parent process | `gh` auth |
| `GH_BOT_TOKEN` | Bot account token | `GH_TOKEN` / `GITHUB_TOKEN`, then `gh` auth |
| `GH_BOT_USERNAME` | Bot login used when filtering reviews and comments | `review-bot[bot]` |
| `GH_ISSUE_PATTERN` | Regex extracting an issue id from a branch name | `[A-Z]+-[0-9]+` |
| `GH_VERIFY_CMD` | Overrides build/test detection in `pr-cross-check --verify` | auto-detect |
| `VSTACK_GITHUB_OP_TIMEOUT` | Seconds allowed for `op read` | `10` |
| `VSTACK_GITHUB_AUTH_TIMEOUT` | Seconds allowed for the `pr-view` auth preflight | `10` |
| `VSTACK_GITHUB_PR_VIEW_TIMEOUT` | Seconds allowed for `gh pr view` | `30` |
| `VSTACK_GITHUB_GIT_HTTPS_FALLBACK` | `auto`, `never`, or `always` for `git-https-auth` | `auto` |

Values already set in the parent process win over project files. Tokens may be
literal (`ghp_*`, `github_pat_*`, …) or `op://vault/item/field` references;
keep them in `.env.local` rather than committed settings.

`pr-cross-check --verify` picks its build and test commands in this order:
`GH_VERIFY_CMD`, then a `verify.sh` in the project root, then auto-detection
from `Cargo.toml`, `package.json`, `go.mod`, `pyproject.toml`, or `Makefile`.

## The merge gate

`pr-merge` refuses to merge while a PR has review threads that are unresolved
and not outdated, and equally when thread state cannot be read at all. This is
deliberately narrower than GitHub's `required_conversation_resolution`, which
requires *all* conversations resolved: an outdated thread no longer points at
the current diff and cannot be acted on.

It is also policy, not mechanism — the gate binds only merges routed through
`pr-merge`, so a raw `gh pr merge` or the GitHub UI still bypasses it.

Where branch protection *is* enabled, the opposite problem appears: after a
rebase or force-push an outdated thread can become unreachable in the UI —
the link 404s and the PR shows no conversations while still refusing to merge.
List threads with `pr-threads` and clear them by id with `resolve-thread`,
which reaches threads the UI cannot render.
