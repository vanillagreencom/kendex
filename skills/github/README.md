# GitHub Queries

A CLI for GitHub pull requests, reviews and CI results. Coding agents can read PR state, reply to findings and submit permitted changes from the shell.

## Install

```bash
kendex add vanillagreencom/kendex --skill github
```

Requires authenticated `gh` and `jq`. The `op` CLI is required only for credentials stored as 1Password references.

## Features

- Read PR files, comments and review threads.
- Post replies and resolve review threads.
- Manage labels and inspect failed CI jobs.
- Check merge requirements and merge eligible PRs.
- Compare PR branches for conflicts and dependencies.
- Run Git over HTTPS with the caller's GitHub authentication.

## How it works

You run a command through `scripts/github.sh`. The CLI reads your project settings and selects the configured GitHub credentials. It calls GitHub and returns the requested result. Write commands report the outcome of the requested action.

## Settings

Set non-secret defaults in `kendex.settings.toml` under `[env]`; keep tokens in `.env.local`. A value set in the parent process wins over project files.

| Variable | Purpose | Default |
|----------|---------|---------|
| `GH_TOKEN` / `GITHUB_TOKEN` | Pre-resolved token from the parent process | `gh` auth |
| `GH_BOT_TOKEN` | Bot account token, literal or `op://vault/item/field` | `GH_TOKEN` / `GITHUB_TOKEN`, then `gh` auth |
| `GH_BOT_USERNAME` | Bot login used when filtering reviews and comments | `review-bot[bot]` |
| `GH_ISSUE_PATTERN` | Regex extracting an issue id from a branch name | `[A-Z]+-[0-9]+` |
| `GH_VERIFY_CMD` | Build and test command for `pr-cross-check --verify` | `verify.sh` in the project root, else auto-detect |
| `KENDEX_GITHUB_OP_TIMEOUT` | Seconds allowed for `op read` | `10` |
| `KENDEX_GITHUB_AUTH_TIMEOUT` | Seconds allowed for the `pr-view` auth preflight | `10` |
| `KENDEX_GITHUB_PR_VIEW_TIMEOUT` | Seconds allowed for `gh pr view` | `30` |
| `KENDEX_GITHUB_GIT_HTTPS_FALLBACK` | `auto`, `never` or `always` for `git-https-auth` | `auto` |

The three timeouts are read to one decimal place; `0` means no bound, and a finer figure is refused rather than rounded.
